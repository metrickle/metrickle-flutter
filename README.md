# metrickle

Accessibility-first UX research and conversion analytics for Flutter apps. Track screens and events,
find friction (rage taps, u-turns, form errors), run in-app surveys and collect feedback, and segment
every funnel and journey by assistive-technology use (screen reader, large text, reduced motion, …).

Works on iOS, Android, web and desktop. Uses `package_info_plus` (app version) and `url_launcher`
(study invite links) and no platform code of its own.

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
  await Metrickle.init(writeKey: 'mk_live_…');
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

## Revenue from Stripe or RevenueCat

Connect your RevenueCat project (or Stripe account) in the Metrickle dashboard under Integrations → Revenue. Purchases, renewals, refunds and cancels then arrive server-side on the person you identified, so a refund takes back the task they completed. Log in to RevenueCat with the same id:

```dart
mk.identify(user.id);
await Purchases.logIn(user.id);
// Or keep RevenueCat's id and name the Metrickle user:
// await Purchases.setAttributes({'metrickle_user_id': user.id});
```

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
| `appVersion`, `appBuild` | read from the package info | Set them to override; the version is how releases are detected |
| `deviceModel`, `osVersion`, `timezone` | read where possible | Flutter can't read the device model without a plugin |
| `httpClient`, `storage` | `http.Client()`, SharedPreferences | Inject for tests |
| `openUrl` | system browser (`url_launcher`) | How study invite links open; inject for tests |

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

### Follow-ups (study invites)

A campaign can invite people who answered into a study: a booked video call (moderated) or a
self-guided test on the web (unmoderated), optionally only for some answers (e.g. NPS 0–6). After the
last answer the built-in sheet asks for the respondent's personal link ("One moment…" on the submit
button, up to 5 seconds). If one comes back it shows the invite, with its heading focused and
announced, "No thanks" and "Choose a time" / "Take part", which opens the link in the system browser.
Otherwise it shows the usual thank-you. The invite never closes on its own.

With your own renderer:

```dart
survey.complete();
if (survey.followUp != null && survey.qualifies()) {
  final url = await survey.invite(); // null: show the plain thank-you
  if (url != null) {
    survey.followUpOffered(); // once the invite is on screen
    // Show survey.followUp!.prompt with your buttons. When they accept:
    survey.followUpAccepted();
    await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
  }
}
```

`invite()` asks once per response and only returns https links. `$survey_follow_up` is recorded at
most once for the offer and once for the acceptance.

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

Feedback can be switched off per platform under Settings → Research in the dashboard. While it's off, `Metrickle.instance.feedback.isEnabled` is false and `submit` sends nothing, so use it to hide your feedback button. Settings arrive after launch, so rebuild when they do:

```dart
ValueListenableBuilder(
  valueListenable: Metrickle.instance.configListenable,
  builder: (context, _, _) => Metrickle.instance.feedback.isEnabled ? const FeedbackButton() : const SizedBox.shrink(),
);
```

Session, screen, device, app version, locale and accessibility settings are attached. Screenshots are
PNG, downscaled to 1280px on the long edge and at most 2 MB.

## Privacy

- Text field contents are never captured, only identifiers and semantics labels.
- No advertising ids or device serials. The anonymous id is a random UUID in app storage.
- `optOut()` stops all collection and network calls, clears the queue and removes the anonymous and
  session ids from the device, and is remembered. While opted out no anonymous id is created, on
  launch or by `reset()`. Your own user id (from `identify`) and consent are kept. `optIn()` starts a
  new anonymous id and fetches surveys and settings again.
- `cookieless: true` stores nothing on the device.
- `consent(replay: true)` records consent for research features (kept for parity with the web SDK).

## License

MIT
