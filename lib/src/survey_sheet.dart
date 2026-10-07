import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';

import 'client.dart';
import 'config.dart';
import 'contrast.dart';
import 'surveys.dart';

const _scaleEnds = {
  'nps': ('Not at all likely', 'Extremely likely'),
  'csat': ('Very dissatisfied', 'Very satisfied'),
  'ces': ('Very difficult', 'Very easy'),
  'rating': ('Poor', 'Excellent'),
};

/// The built-in survey, meeting WCAG 2.2 AA: 48dp targets, labelled single-select scales with
/// selected state, a focused heading on open, text scaling without truncation (it scrolls), dark
/// mode and high contrast from the theme, no animation with reduced motion, a visible Close button,
/// Escape/back to dismiss, and a thank-you message.
///
/// When the campaign has a follow-up and the answers qualify, the sheet asks for the respondent's
/// personal study link after the last answer ("One moment…" on the submit button, up to 5s) and,
/// if one comes back, shows the invite before the thank-you. The invite never closes on its own.
///
/// [MetrickleScope] shows it in a modal bottom sheet. Closing it before the end reports
/// `$survey_dismissed`. [accent] is used for the primary colour only when it reaches 4.5:1
/// against the surface.
class MetrickleSurveySheet extends StatefulWidget {
  const MetrickleSurveySheet({super.key, required this.survey, this.accent, this.onClose, this.openUrl});

  final ActiveSurvey survey;
  final Color? accent;

  /// Opens the study invite link. Defaults to [Metrickle.openUrl] (the system browser).
  final Future<bool> Function(Uri url)? openUrl;

  /// Defaults to popping the enclosing route.
  final VoidCallback? onClose;

  @override
  State<MetrickleSurveySheet> createState() => _MetrickleSurveySheetState();
}

class _MetrickleSurveySheetState extends State<MetrickleSurveySheet> {
  final _heading = FocusNode(debugLabel: 'metrickle survey heading');
  final _text = TextEditingController();
  int _index = 0;
  int? _score;
  final Set<String> _values = {};
  String? _single;
  String? _error;
  bool _done = false;
  bool _closed = false;
  Timer? _autoClose;

  /// Waiting for the invite link after the last answer.
  bool _waiting = false;

  /// The personal study link while the invite is on screen.
  String? _inviteUrl;
  final _inviteHeading = FocusNode(debugLabel: 'metrickle invite heading');

  CampaignConfig get _campaign => widget.survey.campaign;
  Question get _q => _campaign.questions[_index];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      widget.survey.shown();
      _heading.requestFocus();
      SemanticsService.sendAnnouncement(View.of(context), 'Survey', Directionality.of(context));
    });
  }

  @override
  void dispose() {
    _autoClose?.cancel();
    if (!_done) widget.survey.dismiss(_index);
    _heading.dispose();
    _inviteHeading.dispose();
    _text.dispose();
    super.dispose();
  }

  void _close() {
    if (_closed) return;
    _closed = true;
    final cb = widget.onClose;
    if (cb != null) {
      cb();
    } else {
      Navigator.maybePop(context);
    }
  }

  SurveyAnswer? _read() => switch (_q.type) {
        'text' => _text.text.trim().isEmpty ? null : SurveyAnswer(text: _text.text),
        'choice' => _q.multiple
            ? (_values.isEmpty ? null : SurveyAnswer(values: [for (final c in _q.choices ?? const <String>[]) if (_values.contains(c)) c]))
            : (_single == null ? null : SurveyAnswer(values: [_single!])),
        _ => _score == null ? null : SurveyAnswer(score: _score),
      };

  void _next({bool skip = false}) {
    if (_waiting) return;
    final a = skip ? null : _read();
    if (!skip && a == null && _q.required) {
      setState(() => _error = _q.type == 'text'
          ? 'Please write an answer, or close the survey.'
          : 'Please choose an answer, or close the survey.');
      return;
    }
    if (a != null) widget.survey.answer(_q, a);
    setState(() {
      _error = null;
      if (_index < _campaign.questions.length - 1) {
        _index++;
        _score = null;
        _single = null;
        _values.clear();
        _text.clear();
      } else {
        _done = true;
        widget.survey.complete();
      }
    });
    if (!_done) {
      // The user is mid-interaction, so moving focus to the next heading is expected.
      WidgetsBinding.instance.addPostFrameCallback((_) => mounted ? _heading.requestFocus() : null);
      return;
    }
    final s = widget.survey;
    if (s.followUp == null || !s.qualifies()) return _thanks();
    // Ask for the personal link before saying anything: no invite is shown that can't be kept.
    // Focus stays on the submit button meanwhile, which reads "One moment…".
    setState(() => _waiting = true);
    s.invite().timeout(const Duration(seconds: 5), onTimeout: () => null).catchError((_) => null).then((url) {
      if (!mounted || _closed) return;
      if (url == null) return _thanks();
      setState(() {
        _waiting = false;
        _inviteUrl = url;
      });
      s.followUpOffered();
      // The user just submitted, so moving focus to the invite is expected. It stays until they choose.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _inviteHeading.requestFocus();
        SemanticsService.sendAnnouncement(View.of(context), s.followUp!.prompt, Directionality.of(context));
      });
    });
  }

  void _thanks() {
    if (!mounted) return;
    setState(() {
      _waiting = false;
      _inviteUrl = null;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => mounted ? _heading.requestFocus() : null);
    _autoClose?.cancel();
    if (!(MediaQuery.maybeAccessibleNavigationOf(context) ?? false)) {
      _autoClose = Timer(const Duration(seconds: 6), _close);
    }
  }

  Future<void> _accept() async {
    final url = _inviteUrl;
    if (url == null) return;
    widget.survey.followUpAccepted();
    final uri = Uri.parse(url);
    final open = widget.openUrl ?? Metrickle.maybeInstance?.openUrl;
    if (open != null) await open(uri);
    _thanks();
  }

  @override
  Widget build(BuildContext context) {
    final base = Theme.of(context);
    final scheme = base.colorScheme;
    final accent = widget.accent;
    final useAccent = accent != null && contrastRatio(colorToHex(accent), colorToHex(scheme.surface)) >= 4.5;
    final theme = useAccent
        ? base.copyWith(
            colorScheme: scheme.copyWith(primary: accent, onPrimary: hexToColor(textOn(colorToHex(accent)))),
          )
        : base;
    final total = _campaign.questions.length;
    final title = _done || total == 1 ? 'Quick survey' : 'Quick survey · ${_index + 1} of $total';

    return Theme(
      data: theme,
      child: CallbackShortcuts(
        bindings: {const SingleActivator(LogicalKeyboardKey.escape): _close},
        child: FocusScope(
          child: Material(
            color: theme.colorScheme.surface,
            child: SingleChildScrollView(
              padding: EdgeInsets.fromLTRB(20, 8, 8, 16 + MediaQuery.viewInsetsOf(context).bottom),
              child: Padding(
                padding: const EdgeInsets.only(right: 12),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Expanded(
                          child: Focus(
                            focusNode: _heading,
                            child: Semantics(
                              header: true,
                              child: Text(title, style: theme.textTheme.titleMedium),
                            ),
                          ),
                        ),
                        IconButton(
                          onPressed: _close,
                          tooltip: 'Close survey',
                          icon: const Icon(Icons.close),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    if (_inviteUrl != null)
                      _invite(theme)
                    else if (_done && !_waiting)
                      Semantics(
                        liveRegion: true,
                        child: Text(_campaign.thankYou ?? 'Thanks for your feedback', style: theme.textTheme.bodyLarge),
                      )
                    else ...[
                      _body(theme),
                      if (_error != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Semantics(
                            liveRegion: true,
                            child: Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
                          ),
                        ),
                      const SizedBox(height: 16),
                      Wrap(
                        alignment: WrapAlignment.end,
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          if (!_q.required && !_waiting)
                            TextButton(onPressed: () => _next(skip: true), child: const Text('Skip')),
                          // Stays enabled while waiting, so focus isn't dropped; _next ignores it.
                          FilledButton(
                            onPressed: _next,
                            child: Text(_waiting ? 'One moment…' : (_index == total - 1 ? 'Submit' : 'Next')),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _invite(ThemeData theme) {
    final f = widget.survey.followUp!;
    final what = f.kind == 'moderated'
        ? 'A ${f.durationMin != null ? '${f.durationMin}-minute ' : ''}video call at a time that suits you.'
        : 'A short self-guided test of the site. Takes about 10–15 minutes.';
    final action = f.kind == 'moderated' ? 'Choose a time' : 'Take part';
    final incentive = f.incentive;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Focus(
          focusNode: _inviteHeading,
          child: Semantics(
            header: true,
            child: Text(f.prompt, style: theme.textTheme.titleSmall),
          ),
        ),
        const SizedBox(height: 4),
        Text(what, style: theme.textTheme.bodyMedium),
        if (incentive != null && incentive.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text('As a thank-you: $incentive', style: theme.textTheme.bodyMedium),
        ],
        const SizedBox(height: 16),
        Wrap(
          alignment: WrapAlignment.end,
          spacing: 8,
          runSpacing: 8,
          children: [
            TextButton(onPressed: _thanks, child: const Text('No thanks')),
            FilledButton.icon(
              onPressed: _accept,
              icon: const Icon(Icons.open_in_new, size: 18),
              label: Semantics(
                label: '$action, opens in your browser',
                excludeSemantics: true,
                child: Text(action),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _body(ThemeData theme) {
    final q = _q;
    final prompt = Text(q.prompt, style: theme.textTheme.titleSmall);
    switch (q.type) {
      case 'text':
        return MergeSemantics(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              prompt,
              const SizedBox(height: 8),
              TextField(
                key: ValueKey('metrickle-text-${q.id}'),
                controller: _text,
                minLines: 3,
                maxLines: 6,
                maxLength: 1000,
                decoration: InputDecoration(hintText: q.placeholder, border: const OutlineInputBorder()),
              ),
            ],
          ),
        );
      case 'choice':
        final choices = q.choices ?? const <String>[];
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(q.multiple ? '${q.prompt} (choose all that apply)' : q.prompt, style: theme.textTheme.titleSmall),
            const SizedBox(height: 4),
            if (q.multiple)
              for (final c in choices)
                CheckboxListTile(
                  value: _values.contains(c),
                  title: Text(c),
                  controlAffinity: ListTileControlAffinity.leading,
                  contentPadding: EdgeInsets.zero,
                  onChanged: (v) => setState(() => v == true ? _values.add(c) : _values.remove(c)),
                )
            else
              RadioGroup<String>(
                groupValue: _single,
                onChanged: (v) => setState(() => _single = v),
                child: Column(
                  children: [
                    for (final c in choices)
                      RadioListTile<String>(
                        value: c,
                        toggleable: true,
                        title: Text(c),
                        contentPadding: EdgeInsets.zero,
                      ),
                  ],
                ),
              ),
          ],
        );
      default:
        final range = surveyScales[q.type] ?? (min: 1, max: 5);
        final ends = _scaleEnds[q.type] ?? ('', '');
        final low = q.lowLabel ?? ends.$1, high = q.highLabel ?? ends.$2;
        String label(int n) {
          final face = q.type == 'rating' ? '$n out of ${range.max} stars' : '$n';
          if (n == range.min && low.isNotEmpty) return '$face, $low';
          if (n == range.max && high.isNotEmpty) return '$face, $high';
          return face;
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            prompt,
            const SizedBox(height: 12),
            Semantics(
              role: SemanticsRole.radioGroup,
              container: true,
              label: q.prompt,
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (var n = range.min; n <= range.max; n++)
                    _ScaleOption(
                      key: ValueKey('metrickle-score-$n'),
                      text: q.type == 'rating' ? '★ $n' : '$n',
                      label: label(n),
                      selected: _score == n,
                      // Choosing the selected option again clears it, so a mis-tap is never stuck.
                      onTap: () => setState(() => _score = _score == n ? null : n),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            ExcludeSemantics(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: Text('${range.min} = $low', style: theme.textTheme.bodySmall)),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text('${range.max} = $high', textAlign: TextAlign.end, style: theme.textTheme.bodySmall),
                  ),
                ],
              ),
            ),
          ],
        );
    }
  }
}

class _ScaleOption extends StatelessWidget {
  const _ScaleOption({super.key, required this.text, required this.label, required this.selected, required this.onTap});

  final String text;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final highContrast = MediaQuery.maybeHighContrastOf(context) ?? false;
    return Semantics(
      container: true,
      button: true,
      inMutuallyExclusiveGroup: true,
      checked: selected,
      selected: selected,
      label: label,
      onTap: onTap,
      excludeSemantics: true,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
        child: Material(
          color: selected ? scheme.primary : scheme.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
            side: BorderSide(
              color: selected ? scheme.primary : (highContrast ? scheme.onSurface : scheme.outline),
              width: selected || highContrast ? 2 : 1,
            ),
          ),
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
              child: Center(
                widthFactor: 1,
                heightFactor: 1,
                child: Text(
                  text,
                  style: theme.textTheme.titleMedium?.copyWith(color: selected ? scheme.onPrimary : scheme.onSurface),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
