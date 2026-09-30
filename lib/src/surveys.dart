import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'client.dart';
import 'config.dart';
import 'event.dart';

/// Headless survey engine, a port of `surveys.ts`. It decides *whether and when* to show a campaign
/// (trigger, targeting, sampling, frequency caps) and turns answers into `$survey_*` events.
/// Rendering is done by [MetrickleScope]'s built-in sheet or your own `surveys.onShow` renderer.

/// An answer to one question.
class SurveyAnswer {
  const SurveyAnswer({this.score, this.values, this.text});
  final int? score;

  /// Choice answers.
  final List<String>? values;
  final String? text;
}

/// A campaign that should be on screen now.
abstract interface class ActiveSurvey {
  CampaignConfig get campaign;

  /// Call once the survey is actually on screen.
  void shown();
  void answer(Question question, SurveyAnswer answer);

  /// Call after the last answer.
  void complete();

  /// The user closed it; [atIndex] is the question they were on.
  void dismiss(int atIndex);
}

class CampaignState {
  CampaignState({this.shown, this.answered, this.dismissed});
  factory CampaignState.fromJson(Map<String, dynamic> j) => CampaignState(
        shown: (j['shown'] as num?)?.toInt(),
        answered: (j['answered'] as num?)?.toInt(),
        dismissed: (j['dismissed'] as num?)?.toInt(),
      );
  int? shown;
  int? answered;
  int? dismissed;
  Map<String, Object?> toJson() => {'shown': ?shown, 'answered': ?answered, 'dismissed': ?dismissed};
}

/// Persisted as `mk_surveys`, same shape as JS: `{ last?, c: { [campaignId]: { shown?, answered?, dismissed? } } }`.
class SurveyState {
  SurveyState({this.last, Map<String, CampaignState>? c}) : c = c ?? {};
  factory SurveyState.fromJson(Map<String, dynamic> j) => SurveyState(
        last: (j['last'] as num?)?.toInt(),
        c: {
          for (final MapEntry(:key, :value) in ((j['c'] as Map?) ?? const {}).entries)
            key as String: CampaignState.fromJson(value as Map<String, dynamic>),
        },
      );

  /// Last time any survey was shown (global cooldown).
  int? last;
  final Map<String, CampaignState> c;
  Map<String, Object?> toJson() => {'last': ?last, 'c': c.map((k, v) => MapEntry(k, v.toJson()))};
}

const _stateKey = 'mk_surveys';
const _day = 86400000;

/// Never show two surveys within this window, whatever their own caps say.
const globalCooldownMs = _day;
const _maxText = 1000;

/// `Math.imul` followed by `>>> 0`, exact on the VM and on the web (where ints are doubles).
int _imul32(int a, int b) {
  final aHi = (a >> 16) & 0xffff, aLo = a & 0xffff;
  final bHi = (b >> 16) & 0xffff, bLo = b & 0xffff;
  final hi = ((aHi * bLo + aLo * bHi) & 0xffff) << 16;
  return (hi + aLo * bLo) & 0xffffffff;
}

/// Deterministic [0, 1) from a string (FNV-1a over UTF-16 code units), so sampling is stable per
/// user and identical to the JS SDK.
double unitHash(String s) {
  var h = 0x811c9dc5;
  for (final unit in s.codeUnits) {
    h = (h ^ unit) & 0xffffffff;
    h = _imul32(h, 0x01000193);
  }
  return h / 4294967296;
}

/// Exact match, or prefix match when [pattern] ends with `*`.
bool matchPattern(String pattern, String? value) {
  if (value == null) return false;
  return pattern.endsWith('*') ? value.startsWith(pattern.substring(0, pattern.length - 1)) : value == pattern;
}

/// Who and when, for [eligible].
typedef EligibilityContext = ({
  String? anonymousId,
  String? userId,
  String platform,
  String? appVersion,
  List<String> a11y,
  int now,
});

/// Whether a campaign's targeting and caps allow showing it now. Pure, for testing.
bool eligible(CampaignConfig c, EligibilityContext ctx, SurveyState state) {
  final t = c.targeting;
  if (t.identifiedOnly && ctx.userId == null) return false;
  if ((t.platforms?.isNotEmpty ?? false) && !t.platforms!.contains(ctx.platform)) return false;
  if ((t.appVersions?.isNotEmpty ?? false) && !t.appVersions!.any((v) => matchPattern(v, ctx.appVersion))) return false;
  if ((t.a11y?.isNotEmpty ?? false) && !t.a11y!.any(ctx.a11y.contains)) return false;
  if (unitHash('${ctx.anonymousId ?? ctx.userId ?? ''}:${c.id}') >= t.sampleRate) return false;
  final last = state.last;
  if (last != null && last != 0 && ctx.now - last < globalCooldownMs) return false;
  final s = state.c[c.id];
  final shown = s?.shown;
  if (s == null || shown == null || shown == 0) return true;
  final days = (t.frequency.days ?? (t.frequency.kind == 'recurring' ? 90 : 30)) * _day;
  return switch (t.frequency.kind) {
    'until_answered' => (s.answered ?? 0) == 0 && ctx.now - math.max(shown, s.dismissed ?? 0) >= days,
    'recurring' => ctx.now - shown >= days,
    _ => false, // once
  };
}

/// The engine. Created by [Metrickle]; apps use `Metrickle.surveys`.
class SurveyEngine {
  SurveyEngine(this._client, {required this.platform, this.appVersion, required this.a11y}) {
    _loaded = _load();
    _client.onEvent(_handle);
  }

  final Metrickle _client;
  final String platform;
  final String? appVersion;
  final List<String> Function() a11y;

  List<CampaignConfig> _campaigns = [];
  SurveyState _state = SurveyState();
  late final Future<void> _loaded;
  String? _active;
  final _pending = <String>{};
  final _timers = <Timer>{};
  String? _lastPath;

  /// Renders a survey; returns false when it can't (the survey is then released unseen).
  bool Function(ActiveSurvey s)? renderer;

  List<CampaignConfig> get campaigns => _campaigns;

  /// Completes once the persisted survey state is loaded.
  Future<void> get ready => _loaded;

  bool _isLoaded = false;

  Future<void> _load() async {
    try {
      final raw = await _client.storage?.get(_stateKey);
      if (raw != null) _state = SurveyState.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      // Corrupt state: start over.
    }
    _isLoaded = true;
  }

  void _save() => _client.storage?.set(_stateKey, jsonEncode(_state.toJson()));

  /// Re-evaluates `load` triggers, e.g. once a renderer is registered.
  void recheck() => _check('load');

  void setConfig(SdkConfig config) {
    _campaigns = config.campaigns;
    _check('load');
  }

  /// Shows a campaign now, ignoring targeting and caps (QA and previews).
  void show(String campaignId) {
    for (final c in _campaigns) {
      if (c.id == campaignId) return _present(c);
    }
  }

  void _handle(MetrickleEvent e) {
    if (e.name.startsWith(r'$survey_')) return;
    if (e.type == 'page' || e.type == 'screen') {
      _lastPath = e.path;
      _check('page', path: e.path);
      _check('load');
    } else {
      _check('event', name: e.name);
    }
  }

  void _check(String kind, {String? path, String? name}) {
    // Surveys need memory for frequency caps, so cookieless and opted-out clients never see them.
    if (renderer == null || _client.storage == null || _client.isOptedOut || _active != null) return;
    for (final c in _campaigns) {
      final t = c.targeting.trigger;
      if (t.kind != kind || _pending.contains(c.id)) continue;
      if (kind == 'page' && !matchPattern(t.match ?? '', path)) continue;
      if (kind == 'event' && t.match != name) continue;
      _pending.add(c.id);
      void schedule() {
        late final Timer timer;
        timer = Timer(Duration(milliseconds: t.delayMs), () {
          _timers.remove(timer);
          _pending.remove(c.id);
          if (_active != null || !_isEligible(c)) return;
          _present(c);
        });
        _timers.add(timer);
      }

      if (_isLoaded) {
        schedule();
      } else {
        _loaded.then((_) => schedule());
      }
      return;
    }
  }

  bool _isEligible(CampaignConfig c) {
    final id = _client.identity();
    return eligible(
      c,
      (
        anonymousId: id.anonymousId,
        userId: id.userId,
        platform: platform,
        appVersion: appVersion,
        a11y: a11y(),
        now: _client.now(),
      ),
      _state,
    );
  }

  void _present(CampaignConfig c) {
    final render = renderer;
    if (render == null) return;
    _active = c.id;
    final survey = _Survey(this, c, _client.uuid(), _lastPath);
    if (!render(survey)) _active = null;
  }

  void _record(String id, void Function(CampaignState s) patch) {
    patch(_state.c.putIfAbsent(id, CampaignState.new));
    _save();
  }

  /// Cancels pending delayed triggers.
  void dispose() {
    for (final t in _timers) {
      t.cancel();
    }
    _timers.clear();
  }
}

class _Survey implements ActiveSurvey {
  _Survey(this._engine, this.campaign, String response, this._path)
      : _base = {'campaign': campaign.id, 'version': campaign.version, 'response': response};

  final SurveyEngine _engine;
  @override
  final CampaignConfig campaign;
  final Properties _base;
  final String? _path;
  int _answered = 0;

  Metrickle get _client => _engine._client;

  @override
  void shown() {
    final now = _client.now();
    _engine._state.last = now;
    _engine._record(campaign.id, (s) => s.shown = now);
    _client.capture('track', r'$survey_shown', path: _path, properties: _base);
  }

  @override
  void answer(Question q, SurveyAnswer a) {
    _answered++;
    final last = campaign.questions.isNotEmpty && q.id == campaign.questions.last.id;
    final values = a.values;
    final text = a.text?.trim();
    final joined = values != null && values.isNotEmpty ? values.join('|') : null;
    _client.capture('track', r'$survey_answered', path: _path, properties: {
      ..._base,
      'question': q.id,
      'type': q.type,
      'score': a.score,
      'value': joined != null && joined.length > 1024 ? joined.substring(0, 1024) : joined,
      'text': text != null && text.isNotEmpty ? (text.length > _maxText ? text.substring(0, _maxText) : text) : null,
      'completed': last ? true : null,
    });
    _engine._record(campaign.id, (s) => s.answered = _client.now());
  }

  @override
  void complete() => _engine._active = null;

  @override
  void dismiss(int atIndex) {
    _engine._active = null;
    _engine._record(campaign.id, (s) => s.dismissed = _client.now());
    _client.capture('track', r'$survey_dismissed', path: _path, properties: {..._base, 'at': atIndex, 'answered': _answered});
  }
}
