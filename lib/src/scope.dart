import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'client.dart';
import 'contrast.dart';
import 'navigator_observer.dart';
import 'survey_sheet.dart';
import 'surveys.dart';

/// Connects the widget tree to Metrickle:
///
/// - keeps `context.a11y` in sync with MediaQuery (screen reader, reduced motion, high contrast,
///   inverted colours, bold text, large text) and hardware keyboard use;
/// - reports `$rage_click` (3 taps within 1s inside 30 logical px);
/// - presents the built-in, WCAG 2.2 AA survey sheet (unless `surveys.onShow` is used);
/// - gives [MetrickleFeedback.captureScreenshot] something to capture.
///
/// Wrap the child of `MaterialApp.builder`, or place it above the app:
///
/// ```dart
/// MaterialApp(
///   navigatorObservers: [MetrickleNavigatorObserver()],
///   builder: (context, child) => MetrickleScope(child: child!),
/// )
/// ```
///
/// The survey sheet opens on the navigator of a [MetrickleNavigatorObserver] (or an enclosing
/// [Navigator]); without one, register your own renderer with `surveys.onShow`.
class MetrickleScope extends StatefulWidget {
  const MetrickleScope({super.key, required this.child, this.client, this.builtInSurveys = true});

  final Widget child;

  /// Defaults to [Metrickle.instance].
  final Metrickle? client;

  /// Show surveys in the built-in sheet when no `surveys.onShow` renderer is registered.
  final bool builtInSurveys;

  static GlobalKey? _boundary;

  /// Key of the `RepaintBoundary` around the app, for screenshots.
  static GlobalKey? get boundaryKey => _boundary;

  @override
  State<MetrickleScope> createState() => _MetrickleScopeState();
}

class _MetrickleScopeState extends State<MetrickleScope> with WidgetsBindingObserver {
  final _boundary = GlobalKey(debugLabel: 'metrickle');
  final _taps = <(int, Offset)>[];
  bool _keyboard = false;
  Metrickle? _registered;

  Metrickle? get _client => widget.client ?? Metrickle.maybeInstance;

  @override
  void initState() {
    super.initState();
    MetrickleScope._boundary = _boundary;
    WidgetsBinding.instance.addObserver(this);
    HardwareKeyboard.instance.addHandler(_onKey);
    _register();
  }

  @override
  void didUpdateWidget(MetrickleScope old) {
    super.didUpdateWidget(old);
    _register();
  }

  void _register() {
    final c = _client;
    if (_registered != null && _registered != c) _registered!.builtInSurveyPresenter = null;
    _registered = c;
    c?.builtInSurveyPresenter = widget.builtInSurveys ? _present : null;
  }

  @override
  void dispose() {
    if (MetrickleScope._boundary == _boundary) MetrickleScope._boundary = null;
    WidgetsBinding.instance.removeObserver(this);
    HardwareKeyboard.instance.removeHandler(_onKey);
    _registered?.builtInSurveyPresenter = null;
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _readA11y();
  }

  @override
  void didChangeAccessibilityFeatures() => _readA11y();

  @override
  void didChangeTextScaleFactor() => _readA11y();

  bool _onKey(KeyEvent e) {
    if (!_keyboard && e is KeyDownEvent) {
      _keyboard = true;
      _readA11y();
    }
    return false;
  }

  void _readA11y() {
    if (!mounted) return;
    final mq = MediaQuery.maybeOf(context) ?? MediaQueryData.fromView(View.of(context));
    _client?.updateA11y({
      if (mq.accessibleNavigation) 'screen_reader',
      if (_keyboard || mq.navigationMode == NavigationMode.directional) 'keyboard',
      if (mq.disableAnimations) 'reduced_motion',
      if (mq.highContrast) 'high_contrast',
      if (mq.invertColors) 'inverted_colors',
      if (mq.boldText) 'bold_text',
      if (mq.textScaler.scale(1) > 1.15) 'large_text',
    });
  }

  bool _present(ActiveSurvey survey) {
    if (!mounted) return false;
    final nav = Navigator.maybeOf(context) ?? MetrickleNavigatorObserver.attachedNavigator;
    if (nav == null) return false;
    final ctx = nav.context;
    final reduceMotion = MediaQuery.maybeDisableAnimationsOf(ctx) ?? false;
    final surface = Theme.of(ctx).colorScheme.surface;
    showModalBottomSheet<void>(
      context: ctx,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: surface,
      clipBehavior: Clip.antiAlias,
      sheetAnimationStyle: reduceMotion ? AnimationStyle.noAnimation : null,
      builder: (_) => MetrickleSurveySheet(survey: survey, accent: hexToColor(_client?.config?.accent)),
    );
    return true;
  }

  void _onPointerDown(PointerDownEvent e) {
    final client = _client;
    if (client == null || !client.collectsRageTaps || e.kind == PointerDeviceKind.trackpad) return;
    final t = client.now();
    _taps.removeWhere((p) => t - p.$1 > 1000 || (p.$2 - e.position).distance > 30);
    _taps.add((t, e.position));
    if (_taps.length < 3) return;
    _taps.clear();
    final target = describeTarget(context, e.position, e.viewId);
    client.capture('track', r'$rage_click', properties: {'selector': target.selector, 'text': target.text});
  }

  @override
  Widget build(BuildContext context) => Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: _onPointerDown,
        child: RepaintBoundary(key: _boundary, child: widget.child),
      );
}

final _interactive = RegExp(r'(Button|Tile|Chip|Card|Tab|Checkbox|Radio|Switch|Slider|Field|MenuItem|Link|Dropdown.*)$');
const _generic = {'Text', 'RichText', 'Icon', 'Builder', 'DefaultTextStyle', 'IconTheme', 'Semantics', 'Tooltip'};

/// Identifies the widget under [position]: `selector` is the nearest `Semantics(identifier:)`, else
/// a `ValueKey<String>`, else the widget class name; `text` is the nearest semantics label or
/// tooltip (≤ 80 chars). Text field contents are never read.
({String? selector, String? text}) describeTarget(BuildContext root, Offset position, int viewId) {
  final result = HitTestResult();
  WidgetsBinding.instance.hitTestInView(result, position, viewId);
  final hits = [for (final e in result.path) if (e.target is RenderObject) e.target as RenderObject];
  if (hits.isEmpty) return (selector: null, text: null);
  Element? found;
  final targets = hits.toSet();
  // Deepest hit render object that belongs to this subtree.
  var best = hits.length;
  void visit(Element e) {
    if (e is RenderObjectElement && targets.contains(e.renderObject)) {
      final i = hits.indexOf(e.renderObject);
      if (i < best) {
        best = i;
        found = e;
      }
      if (i == 0) return;
    }
    e.visitChildren(visit);
  }

  root.visitChildElements(visit);
  final start = found;
  if (start == null) return (selector: null, text: null);
  final chain = <Widget>[start.widget];
  start.visitAncestorElements((a) {
    chain.add(a.widget);
    return a.widget is! MetrickleScope && chain.length < 60;
  });
  String? identifier, key, label, typeName, fallback;
  var inField = false;
  for (final w in chain) {
    if (w is EditableText) inField = true;
    if (w is Semantics) {
      final id = w.properties.identifier;
      if (identifier == null && id != null && id.isNotEmpty) identifier = id;
      final l = w.properties.label;
      if (label == null && l != null && l.isNotEmpty) label = l;
    }
    if (w is Tooltip && label == null) label = w.message;
    final k = w.key;
    if (key == null && k is ValueKey<String>) key = k.value;
    final name = w.runtimeType.toString();
    if (w is StatelessWidget || w is StatefulWidget) {
      if (typeName == null && _interactive.hasMatch(name)) typeName = name;
      if (fallback == null && !name.startsWith('_') && !_generic.contains(name)) fallback = name;
    }
  }
  if (label == null && chain.first is RichText) label = (chain.first as RichText).text.toPlainText();
  if (inField) label = null;
  final text = label?.trim();
  return (
    selector: identifier ?? key ?? typeName ?? fallback ?? chain.first.runtimeType.toString(),
    text: text == null || text.isEmpty ? null : String.fromCharCodes(text.runes.take(80)),
  );
}
