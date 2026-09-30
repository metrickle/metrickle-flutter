/// `GET /v1/config` payload (`SdkConfig` in `packages/schema/src/research.ts`). Only the fields the
/// SDK needs are typed; parsing is lenient so a newer server never breaks an older app.
library;

/// Score range per scored question type (`SCALES`).
const Map<String, ({int min, int max})> surveyScales = {
  'nps': (min: 0, max: 10),
  'csat': (min: 1, max: 5),
  'ces': (min: 1, max: 7),
  'rating': (min: 1, max: 5),
};

List<String>? _strings(Object? v) => v is List ? v.whereType<String>().toList() : null;

/// A survey question.
class Question {
  const Question({
    required this.id,
    required this.type,
    required this.prompt,
    this.required = true,
    this.choices,
    this.multiple = false,
    this.lowLabel,
    this.highLabel,
    this.placeholder,
  });

  factory Question.fromJson(Map<String, dynamic> j) => Question(
        id: j['id'] as String,
        type: j['type'] as String,
        prompt: j['prompt'] as String,
        required: j['required'] as bool? ?? true,
        choices: _strings(j['choices']),
        multiple: j['multiple'] as bool? ?? false,
        lowLabel: j['lowLabel'] as String?,
        highLabel: j['highLabel'] as String?,
        placeholder: j['placeholder'] as String?,
      );

  final String id;

  /// `nps`, `csat`, `ces`, `rating`, `choice` or `text`.
  final String type;
  final String prompt;
  final bool required;

  /// Choice questions: the options, in order.
  final List<String>? choices;

  /// Choice questions: allow several answers.
  final bool multiple;

  /// Scale end labels, e.g. "Not likely" / "Very likely".
  final String? lowLabel;
  final String? highLabel;
  final String? placeholder;
}

/// When a campaign shows: `load`, `page` (screen name, trailing `*` wildcard) or `event`.
class Trigger {
  const Trigger({required this.kind, this.match, this.delayMs = 0});

  factory Trigger.fromJson(Map<String, dynamic> j) =>
      Trigger(kind: j['kind'] as String, match: j['match'] as String?, delayMs: (j['delayMs'] as num?)?.toInt() ?? 0);

  final String kind;
  final String? match;
  final int delayMs;
}

/// `once`, `until_answered` (re-ask after dismissal every [days]) or `recurring` (every [days]).
class Frequency {
  const Frequency({this.kind = 'once', this.days});

  factory Frequency.fromJson(Map<String, dynamic>? j) =>
      Frequency(kind: j?['kind'] as String? ?? 'once', days: (j?['days'] as num?)?.toInt());

  final String kind;
  final int? days;
}

class Targeting {
  const Targeting({
    required this.trigger,
    this.platforms,
    this.appVersions,
    this.a11y,
    this.identifiedOnly = false,
    this.sampleRate = 1,
    this.frequency = const Frequency(),
  });

  factory Targeting.fromJson(Map<String, dynamic> j) => Targeting(
        trigger: Trigger.fromJson(j['trigger'] as Map<String, dynamic>),
        platforms: _strings(j['platforms']),
        appVersions: _strings(j['appVersions']),
        a11y: _strings(j['a11y']),
        identifiedOnly: j['identifiedOnly'] as bool? ?? false,
        sampleRate: (j['sampleRate'] as num?)?.toDouble() ?? 1,
        frequency: Frequency.fromJson(j['frequency'] as Map<String, dynamic>?),
      );

  final Trigger trigger;
  final List<String>? platforms;

  /// Exact versions or prefixes with a trailing `*`, e.g. "2.4*".
  final List<String>? appVersions;

  /// Only show to users with any of these accessibility flags.
  final List<String>? a11y;
  final bool identifiedOnly;

  /// Share of eligible users who see it, 0–1. Deterministic per user.
  final double sampleRate;
  final Frequency frequency;
}

/// What the SDK receives for a campaign: only what's needed to decide and render.
class CampaignConfig {
  const CampaignConfig({required this.id, required this.questions, required this.targeting, this.thankYou, this.version = 1});

  factory CampaignConfig.fromJson(Map<String, dynamic> j) => CampaignConfig(
        id: j['id'] as String,
        questions: [for (final q in j['questions'] as List) Question.fromJson(q as Map<String, dynamic>)],
        targeting: Targeting.fromJson(j['targeting'] as Map<String, dynamic>),
        thankYou: j['thankYou'] as String?,
        version: (j['version'] as num?)?.toInt() ?? 1,
      );

  final String id;
  final List<Question> questions;
  final Targeting targeting;
  final String? thankYou;

  /// Bumps when the campaign is edited.
  final int version;
}

/// `GET /v1/config` response.
class SdkConfig {
  const SdkConfig({this.campaigns = const [], this.accent, this.feedbackPlatforms, this.raw = const {}});

  /// Parses a config, or returns null when it is malformed or `v != 1`.
  static SdkConfig? tryParse(Object? json) {
    if (json is! Map<String, dynamic> || json['v'] != 1) return null;
    try {
      final feedback = json['feedback'] as Map<String, dynamic>?;
      final branding = feedback?['branding'] as Map<String, dynamic>?;
      final platforms = feedback?['platforms'] as List?;
      return SdkConfig(
        campaigns: [
          for (final c in (json['campaigns'] as List?) ?? const []) CampaignConfig.fromJson(c as Map<String, dynamic>),
        ],
        accent: branding?['accent'] as String?,
        feedbackPlatforms: platforms?.whereType<String>().toList(),
        raw: json,
      );
    } catch (_) {
      return null;
    }
  }

  final List<CampaignConfig> campaigns;

  /// `feedback.branding.accent` (#rrggbb), or null for the default.
  final String? accent;

  /// `feedback.platforms`: where the app takes feedback. Null (configs from before the setting) means everywhere.
  final List<String>? feedbackPlatforms;

  /// The whole response, for settings not typed here.
  final Map<String, dynamic> raw;
}
