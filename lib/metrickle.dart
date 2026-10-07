/// Metrickle: accessibility-first UX research and conversion analytics for Flutter.
///
/// ```dart
/// await Metrickle.init(writeKey: 'mk_live_…');
/// runApp(MaterialApp(
///   navigatorObservers: [MetrickleNavigatorObserver()],
///   builder: (context, child) => MetrickleScope(child: child!),
///   home: const HomePage(),
/// ));
/// ```
library;

export 'src/client.dart' show Metrickle, MetrickleOptions, MetrickleSurveys, sdkVersion, a11yFlags;
export 'src/config.dart';
export 'src/contrast.dart' show contrastRatio, textOn;
export 'src/event.dart' show MetrickleEvent, Properties;
export 'src/feedback.dart' show FeedbackCategory, FeedbackResult, MetrickleFeedback, maxScreenshotBytes;
export 'src/navigator_observer.dart';
export 'src/scope.dart' show MetrickleScope;
export 'src/storage.dart';
export 'src/survey_sheet.dart';
export 'src/surveys.dart'
    show
        ActiveSurvey,
        SurveyAnswer,
        SurveyState,
        CampaignState,
        eligible,
        unitHash,
        matchPattern,
        globalCooldownMs,
        EligibilityContext,
        FollowUpAnswer,
        followUpMatches;
export 'src/uturn.dart';
