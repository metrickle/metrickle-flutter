import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import 'config.dart';
import 'event.dart';
import 'feedback.dart';
import 'platform/device.dart';
import 'storage.dart';
import 'surveys.dart';
import 'uturn.dart';

/// SDK version, sent in `context.library` and the User-Agent.
const sdkVersion = '0.2.0';

/// Accessibility flags in `A11Y_FLAGS` order (`packages/schema/src/constants.ts`).
const a11yFlags = [
  'screen_reader',
  'keyboard',
  'reduced_motion',
  'reduced_transparency',
  'high_contrast',
  'forced_colors',
  'inverted_colors',
  'grayscale',
  'bold_text',
  'large_text',
  'zoomed',
];

/// Telemetry reported on its own schedule: never starts or extends a session.
const _passive = {r'$web_vital', r'$app_background'};
const _kAnon = 'mk_aid', _kUser = 'mk_uid', _kSession = 'mk_sid', _kOptOut = 'mk_optout';
const _kConsent = 'mk_consent', _kQueue = 'mk_queue';
const _maxQueue = 1000;
const _maxBatch = 100;
const _flushAt = 20;
const _maxAgeMs = 7 * 86400000;
const _configMaxAgeMs = 5 * 60000;

/// Options for [Metrickle.init].
class MetrickleOptions {
  const MetrickleOptions({
    this.host = 'https://in.metrickle.com',
    this.cookieless = false,
    this.flushInterval = const Duration(seconds: 5),
    this.sessionTimeout = const Duration(minutes: 30),
    this.rageTaps = true,
    this.debug = false,
    this.beforeSend,
    this.appVersion,
    this.appBuild,
    this.deviceModel,
    this.osVersion,
    this.timezone,
    this.httpClient,
    this.storage,
    this.clock,
    this.openUrl,
  });

  /// Ingest origin. A trailing slash is ignored.
  final String host;

  /// Persist nothing: no anonymous or session id (the server derives a daily-rotating hash) and
  /// surveys stay off.
  final bool cookieless;
  final Duration flushInterval;

  /// Inactivity after which a new session starts.
  final Duration sessionTimeout;

  /// Report `$rage_click` for 3 taps within 1s inside 30 logical px (needs [MetrickleScope]).
  final bool rageTaps;

  /// Log every queued event and each send result.
  final bool debug;

  /// Called before each event is queued; return null to drop it (e.g. PII scrubbing).
  final MetrickleEvent? Function(MetrickleEvent event)? beforeSend;

  /// Your app's version and build, for `context.app`, release detection and survey targeting. Read
  /// from the app's package info (`package_info_plus`) when not set; set them to override it.
  final String? appVersion;
  final String? appBuild;

  /// Device model (e.g. "iPhone15,2") and OS version, which Flutter can't read without a plugin.
  final String? deviceModel;
  final String? osVersion;

  /// IANA time zone. Read from the platform where possible (web, macOS, Linux, iOS); pass it on
  /// Android (e.g. from `flutter_timezone`).
  final String? timezone;

  /// HTTP client, e.g. a `MockClient` in tests.
  final http.Client? httpClient;

  /// Persistence. Defaults to SharedPreferences.
  final MetrickleStorage? storage;

  /// Epoch ms clock, for tests.
  final int Function()? clock;

  /// Opens a study invite link from the built-in survey sheet. Defaults to the system browser
  /// (`url_launcher`, external application). Inject it in tests.
  final Future<bool> Function(Uri url)? openUrl;
}

/// Metrickle client: events, screens, identity, sessions and a persisted offline queue. Port of
/// `core.ts`; see `docs/NATIVE_SDKS.md` for the shared contract.
///
/// ```dart
/// await Metrickle.init(writeKey: 'mk_live_…');
/// Metrickle.instance.track('checkout_started');
/// ```
class Metrickle {
  Metrickle._(this.writeKey, this.options)
      : storage = options.cookieless ? null : (options.storage ?? SharedPreferencesStorage()),
        _http = options.httpClient ?? http.Client();

  static Metrickle? _instance;

  /// The client created by [init]. Throws if [init] has not completed.
  static Metrickle get instance =>
      _instance ?? (throw StateError('Metrickle.init() must complete before Metrickle.instance is used'));

  /// The client, or null before [init].
  static Metrickle? get maybeInstance => _instance;

  /// Creates the client, restores ids and the offline queue, sends `$app_open` and fetches the
  /// survey config. Calling it again disposes the previous client.
  static Future<Metrickle> init({required String writeKey, MetrickleOptions options = const MetrickleOptions()}) async {
    WidgetsFlutterBinding.ensureInitialized();
    _instance?.dispose();
    final client = Metrickle._(writeKey, options);
    // Published once ids are restored, so no event is sent without them.
    await client._start();
    _instance = client;
    return client;
  }

  final String writeKey;
  final MetrickleOptions options;

  /// Persistence, or null in cookieless mode.
  final MetrickleStorage? storage;
  final http.Client _http;
  final _random = math.Random.secure();

  List<MetrickleEvent> _queue = [];
  List<MetrickleEvent> _inflight = [];
  String? _anonymousId;
  String? _userId;
  ({String id, int last})? _session;
  bool _optedOut = false;
  final Set<String> _consents = {};
  final Properties _superProps = {};
  final Map<String, Object?> _context = {};
  final _listeners = <void Function(MetrickleEvent)>[];
  Timer? _timer;
  bool _flushing = false;
  int _retryDelay = 0;
  int _retryAt = 0;
  bool _saveScheduled = false;
  bool _disposed = false;
  AppLifecycleListener? _lifecycle;
  bool _backgrounded = false;
  int _lastConfig = 0;
  String? _screen;
  final _uTurn = uTurnDetector();
  final Map<String, int> _formErrors = {};
  Set<String> _platformA11y = {};
  Set<String> _scopeA11y = {};
  bool _hasScope = false;
  final _config = ValueNotifier<SdkConfig?>(null);

  late final SurveyEngine _engine = SurveyEngine(this, platform: 'flutter', appVersion: () => appVersion, a11y: () => a11y);

  /// Surveys: headless rendering via [MetrickleSurveys.onShow], or the built-in sheet.
  late final MetrickleSurveys surveys = MetrickleSurveys._(this);

  /// "Report a problem" submissions.
  late final MetrickleFeedback feedback = MetrickleFeedback(this);

  /// Ingest origin, without a trailing slash.
  String get host => options.host.endsWith('/') ? options.host.substring(0, options.host.length - 1) : options.host;

  bool get isOptedOut => _optedOut;

  /// The HTTP client used for every request.
  http.Client get httpClient => _http;

  /// The current screen name, attached to events that don't set their own path.
  String? get currentScreen => _screen;

  /// The last `/v1/config` response.
  SdkConfig? get config => _config.value;

  /// Notifies when a new config arrives, e.g. to show or hide a feedback button with
  /// `feedback.isEnabled` (use a `ValueListenableBuilder`).
  ValueListenable<SdkConfig?> get configListenable => _config;

  /// The app version sent in `context.app` (from [MetrickleOptions.appVersion] or the package info).
  String? get appVersion => (_context['app'] as Map<String, Object?>?)?['version'] as String?;

  /// Current accessibility flags (`context.a11y`).
  List<String> get a11y => (_context['a11y'] as List<String>?) ?? const [];

  /// Batch context sent with every request (without `library`).
  Map<String, Object?> get context => Map.unmodifiable(_context);

  /// Current ids. The session is not extended by reading it.
  ({String? anonymousId, String? userId, String? sessionId}) identity() =>
      (anonymousId: _anonymousId, userId: _userId, sessionId: _session?.id);

  /// Epoch ms (the injected clock in tests).
  int now() => options.clock?.call() ?? DateTime.now().millisecondsSinceEpoch;

  /// A random UUID v4.
  String uuid() {
    final b = List<int>.generate(16, (_) => _random.nextInt(256));
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;
    final h = b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
    return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20)}';
  }

  Future<void> _start() async {
    _context.addAll(_readContext());
    _platformA11y = _readPlatformA11y();
    _applyA11y();
    await Future.wait([_readAppInfo(), _restore()]);
    await _engine.ready;
    _timer = Timer.periodic(options.flushInterval, (_) => flush());
    _lifecycle = AppLifecycleListener(onShow: _onForeground, onHide: _onBackground);
    capture('track', r'$app_open');
    unawaited(refreshConfig());
  }

  Future<void> _restore() async {
    final s = storage;
    if (s == null) return;
    try {
      _optedOut = await s.get(_kOptOut) == '1';
      for (final k in (await s.get(_kConsent) ?? '').split(',')) {
        if (k == 'replay') _consents.add(k);
      }
      // Opted out: never create an anonymous id, and don't use one left from before.
      if (!_optedOut) {
        _anonymousId = await s.get(_kAnon);
        if (_anonymousId == null) {
          _anonymousId = uuid();
          await s.set(_kAnon, _anonymousId!);
        }
      }
      _userId = await s.get(_kUser);
      final raw = _optedOut ? null : await s.get(_kSession);
      if (raw != null) {
        final j = jsonDecode(raw) as Map<String, dynamic>;
        _session = (id: j['id'] as String, last: (j['last'] as num).toInt());
      }
    } catch (e) {
      _log('restore failed', e);
    }
    try {
      final raw = await s.get(_kQueue);
      if (raw != null && !_optedOut) {
        final cutoff = now() - _maxAgeMs;
        _queue = [
          for (final j in jsonDecode(raw) as List) MetrickleEvent.fromJson(j as Map<String, dynamic>),
        ].where((e) => e.ts >= cutoff).toList();
      }
    } catch (e) {
      _log('queue restore failed', e);
    }
  }

  /// Fills `context.app` from the package info for whatever the options don't set.
  Future<void> _readAppInfo() async {
    var version = options.appVersion, build = options.appBuild;
    if (version == null || build == null) {
      try {
        final info = await PackageInfo.fromPlatform().timeout(const Duration(seconds: 3));
        version ??= info.version.isEmpty ? null : info.version;
        build ??= info.buildNumber.isEmpty ? null : info.buildNumber;
      } catch (e) {
        _log('package info unavailable', e);
      }
    }
    if (version != null || build != null) _context['app'] = {'version': ?version, 'build': ?build};
  }

  Map<String, Object?> _readContext() {
    final view = ui.PlatformDispatcher.instance.implicitView;
    final display = view?.display;
    final size = display != null ? display.size / display.devicePixelRatio : null;
    final shortest = size?.shortestSide ?? 0;
    final p = defaultTargetPlatform;
    final desktop = p == TargetPlatform.macOS || p == TargetPlatform.windows || p == TargetPlatform.linux;
    final type = desktop
        ? 'desktop'
        : kIsWeb && shortest >= 1100
            ? 'desktop'
            : shortest >= 600
                ? 'tablet'
                : 'mobile';
    final os = switch (p) {
      TargetPlatform.iOS => type == 'tablet' ? 'iPadOS' : 'iOS',
      TargetPlatform.android => 'Android',
      TargetPlatform.macOS => 'macOS',
      TargetPlatform.windows => 'Windows',
      TargetPlatform.linux => 'Linux',
      TargetPlatform.fuchsia => 'Fuchsia',
    };
    return {
      'platform': 'flutter',
      'device': {'type': type, 'model': ?options.deviceModel, 'os': os, 'osVersion': ?(options.osVersion ?? platformOsVersion())},
      if (size != null) 'screen': {'width': size.width.round(), 'height': size.height.round()},
      'locale': ui.PlatformDispatcher.instance.locale.toLanguageTag(),
      'timezone': ?(options.timezone ?? platformTimeZone()),
    };
  }

  /// `metrickle-flutter/0.2.0 (iOS 17.2; iPhone15,2)`.
  String get userAgent {
    final d = _context['device'] as Map<String, Object?>;
    final os = [d['os'], d['osVersion']].whereType<String>().join(' ');
    return 'metrickle-flutter/$sdkVersion ($os; ${d['model'] ?? defaultTargetPlatform.name})';
  }

  Set<String> _readPlatformA11y() {
    final d = ui.PlatformDispatcher.instance;
    final f = d.accessibilityFeatures;
    return {
      if (f.accessibleNavigation) 'screen_reader',
      if (f.disableAnimations) 'reduced_motion',
      if (f.highContrast) 'high_contrast',
      if (f.invertColors) 'inverted_colors',
      if (f.boldText) 'bold_text',
      if (d.textScaleFactor > 1.15) 'large_text',
    };
  }

  /// Called by [MetrickleScope] with flags read from `MediaQuery` and the keyboard.
  void updateA11y(Set<String> flags) {
    _hasScope = true;
    _scopeA11y = flags;
    _applyA11y();
  }

  void _applyA11y() {
    final flags = _hasScope ? _scopeA11y : _platformA11y;
    final list = [for (final f in a11yFlags) if (flags.contains(f)) f];
    if (list.isEmpty) {
      _context.remove('a11y');
    } else {
      _context['a11y'] = list;
    }
  }

  /// Updates the context sent with later batches.
  void setContext(Map<String, Object?> patch) => _context.addAll(patch);

  void _log(String msg, [Object? detail]) {
    if (options.debug) debugPrint('[metrickle] $msg${detail == null ? '' : ' $detail'}');
  }

  /// Called for every event after it is queued (survey triggers, research features).
  VoidCallback onEvent(void Function(MetrickleEvent e) fn) {
    _listeners.add(fn);
    return () => _listeners.remove(fn);
  }

  /// Records the user's consent for research features, e.g. from your consent banner. Native
  /// replay does not exist yet; the choice is kept for parity with the web SDK.
  void consent({required bool replay}) {
    if (replay) {
      _consents.add('replay');
    } else {
      _consents.remove('replay');
    }
    storage?.set(_kConsent, _consents.join(','));
  }

  bool hasConsent(String kind) => _consents.contains(kind);

  /// Session id with inactivity timeout. Null in cookieless mode (the server derives one).
  String? _touchSession(int now, bool passive) {
    final s = storage;
    if (s == null) return null;
    final cur = _session;
    if (passive && cur != null) return cur.id;
    final session = cur == null || now - cur.last > options.sessionTimeout.inMilliseconds
        ? (id: uuid(), last: now)
        : (id: cur.id, last: now);
    _session = session;
    s.set(_kSession, jsonEncode({'id': session.id, 'last': session.last}));
    return session.id;
  }

  /// Properties merged into every later event (under each event's own properties).
  void register(Properties props) => _superProps.addAll(props);

  /// Low-level: queues an event. Prefer [track], [screen] and [identify].
  void capture(
    String type,
    String name, {
    String? path,
    String? title,
    String? referrer,
    Properties? properties,
    Properties? traits,
  }) {
    if (_optedOut || _disposed) return;
    final ts = now();
    final props = sanitizeProperties({..._superProps, ...?properties});
    MetrickleEvent? event = MetrickleEvent(
      id: uuid(),
      type: type,
      name: name,
      ts: ts,
      anonymousId: _anonymousId,
      userId: _userId,
      sessionId: _touchSession(ts, _passive.contains(name)),
      path: path ?? _screen,
      title: title,
      referrer: referrer,
      properties: props == null || props.isEmpty ? null : props,
      traits: sanitizeProperties(traits),
    );
    final hook = options.beforeSend;
    if (hook != null) event = hook(event);
    if (event == null) return;
    if (_queue.length >= _maxQueue) _queue.removeAt(0);
    _queue.add(event);
    _persistQueue();
    _log('queued', event);
    for (final l in List.of(_listeners)) {
      try {
        l(event);
      } catch (e) {
        _log('listener failed', e);
      }
    }
    if (_queue.length >= _flushAt) flush();
  }

  /// Tracks a custom event. Names starting with `$` are reserved and throw.
  void track(String name, [Properties? properties]) {
    if (name.startsWith(r'$')) throw ArgumentError.value(name, 'name', r'event names starting with $ are reserved');
    capture('track', name, properties: properties);
  }

  /// Records a screen view (done for you by [MetrickleNavigatorObserver]). Sends `$u_turn` first
  /// when the user bounced straight back from the previous screen.
  void screen(String name, [Properties? properties]) {
    final turn = _uTurn(name, now());
    if (turn != null) {
      capture('track', r'$u_turn', path: turn.from, properties: {'back_to': turn.to, 'dwell_ms': turn.dwellMs});
    }
    capture('screen', r'$screen', path: name, title: name, referrer: _screen, properties: properties);
    _screen = name;
  }

  /// Reports a validation error shown to the user. Identical errors within 1.5s are collapsed.
  void formError({required String form, required String field, required String reason}) {
    final key = '$form\u0000$field\u0000$reason';
    final t = now();
    final last = _formErrors[key];
    _formErrors.removeWhere((_, v) => t - v >= 1500);
    if (last != null && t - last < 1500) return;
    _formErrors[key] = t;
    capture('track', r'$form_error', properties: {'form': form, 'field': field, 'reason': reason});
  }

  /// Links later events to [userId] and sends `$identify` with [traits].
  void identify(String userId, [Properties? traits]) {
    _userId = userId;
    storage?.set(_kUser, userId);
    capture('identify', r'$identify', traits: traits);
  }

  /// Call on logout: forgets the user and session and starts a new anonymous identity (none while
  /// opted out).
  void reset() {
    _userId = null;
    _session = null;
    final s = storage;
    _anonymousId = s != null && !_optedOut ? uuid() : null;
    if (s != null) {
      s.remove(_kUser);
      s.remove(_kSession);
      if (_anonymousId != null) s.set(_kAnon, _anonymousId!);
    }
  }

  /// Stops all collection and network calls, clears the queue, removes the anonymous and session
  /// ids from the device, and remembers the choice. Your own user id (from [identify]) and consent
  /// are kept.
  void optOut() {
    _optedOut = true;
    _queue = [];
    _anonymousId = null;
    _session = null;
    final s = storage;
    if (s != null) {
      s.set(_kOptOut, '1');
      s.remove(_kQueue);
      s.remove(_kAnon);
      s.remove(_kSession);
    }
  }

  /// Reverses [optOut]: starts a new anonymous identity and fetches surveys and settings again.
  void optIn() {
    _optedOut = false;
    final s = storage;
    if (s != null) {
      s.remove(_kOptOut);
      if (_anonymousId == null) {
        _anonymousId = uuid();
        s.set(_kAnon, _anonymousId!);
      }
    }
    unawaited(refreshConfig());
  }

  void _persistQueue() {
    if (storage == null || _saveScheduled) return;
    _saveScheduled = true;
    scheduleMicrotask(() {
      _saveScheduled = false;
      if (_optedOut) return;
      final all = [..._inflight, ..._queue];
      storage?.set(_kQueue, jsonEncode([for (final e in all.skip(math.max(0, all.length - _maxQueue))) e.toJson()]));
    });
  }

  Map<String, String> get _headers => {
        'content-type': 'application/json',
        'x-metrickle-key': writeKey,
        if (canSetUserAgent) 'user-agent': userAgent,
      };

  Future<bool> _send(List<MetrickleEvent> events) async {
    final batch = {
      'writeKey': writeKey,
      'sentAt': now(),
      'context': {..._context, 'library': {'name': 'metrickle-flutter', 'version': sdkVersion}},
      'events': [for (final e in events) e.toJson()],
    };
    try {
      final res = await _http
          .post(Uri.parse('$host/v1/batch'), headers: _headers, body: jsonEncode(batch))
          .timeout(const Duration(seconds: 30));
      _log('sent ${events.length} events', res.statusCode);
      // 4xx other than 429 will never succeed; drop instead of retrying forever.
      final c = res.statusCode;
      return (c >= 200 && c < 300) || (c >= 400 && c < 500 && c != 429);
    } catch (e) {
      _log('send failed', e);
      return false;
    }
  }

  /// Sends queued events, 100 per request, until the queue is empty or a send fails (then backs
  /// off 1s, doubling to 60s). [force] ignores the backoff (used when the app goes to background).
  Future<void> flush({bool force = false}) async {
    if (_optedOut || _disposed) return;
    if (_flushing && !force) return;
    final cutoff = now() - _maxAgeMs;
    _queue.removeWhere((e) => e.ts < cutoff);
    if (!force && now() < _retryAt) return;
    final wasFlushing = _flushing;
    _flushing = true;
    try {
      while (_queue.isNotEmpty && !_optedOut) {
        final events = _queue.sublist(0, math.min(_maxBatch, _queue.length));
        _queue.removeRange(0, events.length);
        _inflight = [..._inflight, ...events];
        final ok = await _send(events);
        _inflight = _inflight.where((e) => !events.contains(e)).toList();
        if (ok) {
          _retryDelay = 0;
          _retryAt = 0;
        } else {
          if (!_optedOut) _queue.insertAll(0, events);
          _retryDelay = math.min(60000, _retryDelay == 0 ? 1000 : _retryDelay * 2);
          _retryAt = now() + _retryDelay;
          break;
        }
      }
    } finally {
      if (!wasFlushing) _flushing = false;
      _persistQueue();
    }
  }

  /// Re-fetches campaigns and settings (done on launch and when the app returns to the
  /// foreground after 5 minutes).
  Future<void> refreshConfig() async {
    if (_optedOut || _disposed) return;
    _lastConfig = now();
    try {
      final uri = Uri.parse('$host/v1/config').replace(queryParameters: {'key': writeKey});
      final res = await _http.get(uri, headers: {if (canSetUserAgent) 'user-agent': userAgent});
      if (res.statusCode < 200 || res.statusCode >= 300) return;
      final cfg = SdkConfig.tryParse(jsonDecode(res.body));
      if (cfg == null || _disposed) return;
      _config.value = cfg;
      _engine.setConfig(cfg);
    } catch (e) {
      _log('config failed', e);
    }
  }

  void _onForeground() {
    if (!_backgrounded) return;
    _backgrounded = false;
    // Settings can change while the app is in the background.
    _platformA11y = _readPlatformA11y();
    _applyA11y();
    capture('track', r'$app_open');
    if (now() - _lastConfig > _configMaxAgeMs) refreshConfig();
  }

  void _onBackground() {
    if (_backgrounded) return;
    _backgrounded = true;
    capture('track', r'$app_background');
    flush(force: true);
  }

  /// Stops timers and listeners. [init] calls this on the previous client.
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _lifecycle?.dispose();
    _engine.dispose();
    if (identical(_instance, this)) _instance = null;
  }

  /// Opens [url] with [MetrickleOptions.openUrl], or in the system browser. False when it couldn't.
  Future<bool> openUrl(Uri url) async {
    try {
      final open = options.openUrl;
      return open != null ? await open(url) : await launchUrl(url, mode: LaunchMode.externalApplication);
    } catch (e) {
      _log('could not open link', e);
      return false;
    }
  }

  // Wiring for MetrickleScope.
  bool Function(ActiveSurvey s)? _builtIn;
  bool Function(ActiveSurvey s)? _custom;
  void _updateRenderer() {
    _engine.renderer = _custom ?? _builtIn;
    _engine.recheck();
  }
}

/// Internal hooks for [MetrickleScope].
extension MetrickleScopeHooks on Metrickle {
  /// Registers the built-in survey sheet presenter (null to remove it).
  set builtInSurveyPresenter(bool Function(ActiveSurvey s)? present) {
    _builtIn = present;
    _updateRenderer();
  }

  /// Whether `options.rageTaps` is on and the client is collecting.
  bool get collectsRageTaps => options.rageTaps && !_optedOut && !_disposed;
}

/// Surveys API (`Metrickle.instance.surveys`).
class MetrickleSurveys {
  MetrickleSurveys._(this._client);
  final Metrickle _client;

  /// Render surveys with your own widgets instead of the built-in sheet. Called when a campaign's
  /// trigger and targeting match; call `survey.shown()` once it's on screen, `answer()` per
  /// question, then `complete()` or `dismiss()`. Returns a function that unregisters [render].
  VoidCallback onShow(void Function(ActiveSurvey survey) render) {
    bool wrapped(ActiveSurvey s) {
      render(s);
      return true;
    }

    _client._custom = wrapped;
    _client._updateRenderer();
    return () {
      if (_client._custom == wrapped) {
        _client._custom = null;
        _client._updateRenderer();
      }
    };
  }

  /// Shows an active campaign now, ignoring targeting and caps (QA and previews).
  void show(String campaignId) => _client._engine.show(campaignId);

  /// Campaigns from the last config fetch.
  List<CampaignConfig> get campaigns => _client._engine.campaigns;
}
