# metrickle

Accessibility-first UX research and conversion analytics for Flutter apps. Track screens and events,
find friction (rage taps, u-turns, form errors), run in-app surveys and collect feedback, and segment
every funnel and journey by assistive-technology use (screen reader, large text, reduced motion, …).

Works on iOS, Android, web and desktop. Pure Dart: no platform channels.

## Install

```sh
flutter pub add metrickle
```

## Set up

Initialise before `runApp`, add the navigator observer for automatic screen views, and wrap the app
in `MetrickleScope` for accessibility context, rage taps and the built-in survey sheet.

```dart
import 'package:flutter/material.dart';
import 'package:metrickle/metrickle.dart';

Future<void> main() async {
  await Metrickle.init(
    writeKey: 'mk_live_…',
    options: const MetrickleOptions(appVersion: '1.4.0', appBuild: '112'),
  );
  runApp(MaterialApp(
    navigatorObservers: [MetrickleNavigatorObserver()],
    builder: (context, child) => MetrickleScope(child: child!),
    routes: {'Home': (_) => const HomePage(), 'Checkout': (_) => const CheckoutPage()},
    initialRoute: 'Home',
  ));
}
```

Screens are named from `RouteSettings.name`. Unnamed routes and popups (dialogs, menus, bottom
sheets) are skipped; name them with `MetrickleNavigatorObserver(nameExtractor: (route) => …)`.

### go_router

```dart
final router = GoRouter(
  observers: [MetrickleNavigatorObserver()],
  routes: [
    GoRoute(name: 'Home', path: '/', builder: (_, __) => const HomePage()),
    GoRoute(name: 'Checkout', path: '/checkout', builder: (_, __) => const CheckoutPage()),
  ],
);

MaterialApp.router(
  routerConfig: router,
  builder: (context, child) => MetrickleScope(child: child!),
);
```

Give each `GoRoute` a `name`, or use `nameExtractor`. A `ShellRoute` has its own navigator: pass a
`MetrickleNavigatorObserver` in its `observers` too.

## Events

```dart
final mk = Metrickle.instance;
mk.track('plan_selected', {'plan': 'team', 'seats': 5});
mk.screen('Onboarding step 2'); // manual screen views, if you don't use the observer
mk.identify('user_42', {'plan': 'team'});
mk.register({'experiment': 'b'}); // added to every later event
mk.formError(form: 'signup', field: 'email', reason: 'invalid');
mk.reset(); // on logout
await mk.flush();
```

Property values are strings (≤ 1024 chars), finite numbers, booleans or null; at most 64 per event.
Names starting with `$` are reserved.

Sent automatically: `$app_open` (launch and each return to the foreground), `$app_background`,
`$screen`, `$u_turn` (A → B → back to A within 7s) and `$rage_click` (3 taps within 1s inside 30
logical px, identified by `Semantics(identifier:)`, a `ValueKey<String>` or the widget class).

## Options

| Option | Default | |
|---|---|---|
| `host` | `https://in.metrickle.com` | Ingest origin |
| `cookieless` | `false` | Persist nothing; no anonymous or session id, surveys off |
| `flushInterval` | 5s | Also flushes at 20 queued events and on background |
| `sessionTimeout` | 30 min | Inactivity before a new session |
| `rageTaps` | `true` | Needs `MetrickleScope` |
| `debug` | `false` | Logs queued events and send results |
| `beforeSend` | | `(event) => event` to scrub, `null` to drop |
| `appVersion`, `appBuild` | | e.g. from `package_info_plus` |
| `deviceModel`, `osVersion`, `timezone` | read where possible | Flutter can't read the device model without a plugin |
| `httpClient`, `storage` | `http.Client()`, SharedPreferences | Inject for tests |

Events are queued in SharedPreferences (up to 1000, dropped after 7 days) so they survive the app
being killed and offline periods. Failed sends back off from 1s to 60s.

## Surveys

Campaigns are authored in the Metrickle dashboard. With `MetrickleScope` in place, eligible surveys
open in a built-in bottom sheet that meets WCAG 2.2 AA: 48dp targets, scale buttons announced with
their end labels and selected state, a focused heading, text scaling without truncation, dark mode,
high contrast, reduced motion, a visible Close button and Escape/back to dismiss. Your brand accent
is used only when it has 4.5:1 contrast.

To render surveys yourself:

```dart
final stop = Metrickle.instance.surveys.onShow((survey) {
  // Show survey.campaign.questions, then:
  survey.shown();
  survey.answer(question, const SurveyAnswer(score: 9));
  survey.complete(); // or survey.dismiss(questionIndex)
});
Metrickle.instance.surveys.show('cmp_123'); // QA: show now, ignoring targeting
```

Turn the built-in sheet off with `MetrickleScope(builtInSurveys: false, child: …)`. The sheet opens on
the navigator of a `MetrickleNavigatorObserver` (or a `Navigator` above the scope).

## Feedback

```dart
final shot = await Metrickle.instance.feedback.captureScreenshot(); // only after the user opts in
final result = await Metrickle.instance.feedback.submit(
  category: FeedbackCategory.accessibility,
  message: 'The Pay button is not announced',
  screenshot: shot,
);
```

Feedback can be switched off per platform under Settings → Research in the dashboard. While it's off, `Metrickle.instance.feedback.isEnabled` is false and `submit` sends nothing, so use it to hide your feedback button.

Session, screen, device, app version, locale and accessibility settings are attached. Screenshots are
PNG, downscaled to 1280px on the long edge and at most 2 MB.

## Privacy

- Text field contents are never captured, only identifiers and semantics labels.
- No advertising ids or device serials. The anonymous id is a random UUID in app storage.
- `optOut()` clears the queue and stops all network calls, and is remembered; `optIn()` reverses it.
- `cookieless: true` stores nothing on the device.
- `consent(replay: true)` records consent for research features (kept for parity with the web SDK).

## License

MIT
