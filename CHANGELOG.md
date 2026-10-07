## 0.2.0

- Survey follow-ups: when a campaign invites people into a study, the built-in sheet asks for the
  respondent's personal link after the last answer and offers a booked video call or a self-guided
  test, opened in the system browser. The invite never closes on its own and its heading is focused
  and announced. Headless renderers get `survey.followUp`, `qualifies()`, `invite()`,
  `followUpOffered()` and `followUpAccepted()`; `$survey_follow_up` is sent at most once each.
- Opting out now removes the anonymous and session ids from the device, and no new anonymous id is
  made while opted out (on launch or `reset()`). `optIn()` starts a new anonymous id and fetches
  surveys and settings again.
- The app version and build are read from the package info (`package_info_plus`) when you don't set
  `appVersion` / `appBuild`, so releases are detected without extra setup.
- `feedback.isEnabled`: false when feedback is switched off for Flutter in the dashboard (shipped in
  0.1.x without a changelog entry). New `configListenable` to rebuild when settings arrive.
- New `openUrl` option to replace how invite links are opened (e.g. in tests).
- New dependencies: `package_info_plus`, `url_launcher`.

## 0.1.0

- Initial release: events, screens (`MetrickleNavigatorObserver`), sessions, persisted offline queue,
  accessibility context, rage taps, u-turns, form errors, surveys (headless and a built-in WCAG 2.2 AA
  sheet) and feedback with an optional screenshot.
