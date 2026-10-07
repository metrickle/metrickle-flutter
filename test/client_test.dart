import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:metrickle/metrickle.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'helpers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(() => Metrickle.maybeInstance?.dispose());

  test('batch JSON: headers, body, context and event fields', () async {
    final h = Harness();
    final client = await h.start();
    client.register({'plan': 'pro'});
    client.screen('Home');
    client.track('signup_clicked', {'plan': 'team', 'n': 2, 'ok': true, 'none': null, 'bad': double.nan});
    await client.flush();

    final req = h.batches.single;
    expect(req.method, 'POST');
    expect(req.url.toString(), 'https://in.example.com/v1/batch');
    expect(req.headers['content-type'], startsWith('application/json'));
    expect(req.headers['x-metrickle-key'], 'wk_test');
    // Browsers forbid setting User-Agent.
    expect(req.headers['user-agent'], kIsWeb ? isNull : matches(RegExp(r'^metrickle-flutter/0\.2\.0 \(\w+ 15; Pixel 9\)$')));
    expect(client.userAgent, isNot(matches(RegExp('bot|crawl|spider|headless|monitor|preview|curl', caseSensitive: false))));

    final body = jsonDecode(req.body) as Map<String, dynamic>;
    expect(body['writeKey'], 'wk_test');
    expect(body['sentAt'], h.clock);
    final ctx = body['context'] as Map<String, dynamic>;
    expect(ctx['library'], {'name': 'metrickle-flutter', 'version': sdkVersion});
    expect(ctx['platform'], 'flutter');
    expect(ctx['app'], {'version': '2.4.1', 'build': '41'});
    expect((ctx['device'] as Map)['model'], 'Pixel 9');
    expect((ctx['device'] as Map)['osVersion'], '15');
    expect(ctx['timezone'], 'Europe/London');
    expect(ctx['locale'], isA<String>());

    final events = (body['events'] as List).cast<Map<String, dynamic>>();
    expect(events.map((e) => e['name']), [r'$app_open', r'$screen', 'signup_clicked']);
    final screen = events[1], track = events[2];
    expect(screen['type'], 'screen');
    expect(screen['path'], 'Home');
    expect(screen['title'], 'Home');
    expect(screen.containsKey('referrer'), isFalse);
    expect(track['type'], 'track');
    expect(track['path'], 'Home', reason: 'events get the current screen');
    expect(track['properties'], {'plan': 'team', 'n': 2, 'ok': true, 'none': null, 'bad': null});
    expect(track['id'], matches(RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$')));
    expect(track['ts'], h.clock);
    expect(track['anonymousId'], h.storage.data['mk_aid']);
    expect(track['sessionId'], isA<String>());
    expect(screen['properties'], {'plan': 'pro'}, reason: 'super properties apply to later events');
    expect(events[0].containsKey('properties'), isFalse);
  });

  test('properties: empty is dropped, strings clipped, at most 64 keys', () async {
    final h = Harness();
    final client = await h.start();
    client.track('a');
    client.track('b', {'s': 'x' * 2000, for (var i = 0; i < 80; i++) 'k$i': i});
    await client.flush();
    final a = h.events.firstWhere((e) => e['name'] == 'a');
    final b = h.events.firstWhere((e) => e['name'] == 'b');
    expect(a.containsKey('properties'), isFalse);
    final props = b['properties'] as Map;
    expect(props.length, 64);
    expect((props['s'] as String).length, 1024);
  });

  test(r'track rejects names starting with $', () async {
    final client = await Harness().start();
    expect(() => client.track(r'$pageview'), throwsArgumentError);
  });

  test('sessions time out after 30 minutes of inactivity; passive events do not extend them', () async {
    final h = Harness();
    final client = await h.start();
    client.track('a');
    h.clock += 29 * 60000;
    client.track('b');
    h.clock += 29 * 60000;
    client.capture('track', r'$app_background');
    h.clock += 2 * 60000; // 31 min after b: the passive event did not extend the session
    client.track('c');
    await client.flush();
    final ids = {for (final e in h.events) e['name']: e['sessionId']};
    expect(ids['a'], ids['b']);
    expect(ids[r'$app_background'], ids['b']);
    expect(ids['c'], isNot(ids['b']));
    expect(jsonDecode(h.storage.data['mk_sid']!)['id'], ids['c']);
  });

  test('retry: 5xx and 429 requeue with backoff (1s doubling), other 4xx drop', () async {
    final h = Harness();
    final client = await h.start();
    h.status = 500;
    client.track('a');
    await client.flush();
    expect(h.batches, hasLength(1));
    await client.flush(); // within the 1s backoff: no request
    expect(h.batches, hasLength(1));
    h.clock += 1000;
    h.status = 429;
    await client.flush();
    expect(h.batches, hasLength(2));
    h.clock += 1999; // backoff is now 2s
    await client.flush();
    expect(h.batches, hasLength(2));
    h.clock += 1;
    h.status = 200;
    await client.flush();
    expect(h.batches, hasLength(3));
    // Same events, in order, with the same ids (server dedupes on id).
    final first = jsonDecode(h.batches.first.body)['events'] as List, last = jsonDecode(h.batches.last.body)['events'] as List;
    expect(last.map((e) => e['id']), first.map((e) => e['id']));
    await client.flush();
    expect(h.batches, hasLength(3), reason: 'queue is empty');

    h.status = 400;
    client.track('b');
    await client.flush();
    client.track('c');
    h.status = 200;
    await client.flush();
    expect(jsonDecode(h.batches.last.body)['events'].map((e) => e['name']), ['c']);
  });

  test('background flush ignores the backoff and sends at most 100 events per request', () async {
    final h = Harness();
    final client = await h.start();
    h.status = 503;
    await client.flush(); // $app_open fails, so nothing is sent until forced
    for (var i = 0; i < 250; i++) {
      client.capture('track', 'e$i');
    }
    await Future<void>.delayed(Duration.zero);
    h.status = 503;
    await client.flush(); // fails: now backing off
    h.requests.clear();
    await client.flush();
    expect(h.batches, isEmpty, reason: 'backing off');
    await client.flush(force: true);
    expect(h.batches, hasLength(1), reason: 'forced flush stops at the first failure');
    h.status = 200;
    h.requests.clear();
    await client.flush(force: true);
    final sizes = [for (final r in h.batches) (jsonDecode(r.body)['events'] as List).length];
    expect(sizes, [100, 100, 51]);
  });

  test('queue persists across launches and drops events older than 7 days', () async {
    final h = Harness();
    h.status = 500;
    var client = await h.start();
    client.track('old');
    await Future<void>.delayed(Duration.zero);
    h.clock += 3 * day;
    client.track('recent');
    await Future<void>.delayed(Duration.zero);
    expect((jsonDecode(h.storage.data['mk_queue']!) as List).length, 3); // $app_open, old, recent
    client.dispose();

    h.clock += 5 * day; // "old" and $app_open are now 8 days old
    h.status = 200;
    h.requests.clear();
    client = await h.start();
    await client.flush();
    expect(h.events.map((e) => e['name']), ['recent', r'$app_open']);
  });

  test('identify, reset and persisted ids', () async {
    final h = Harness();
    final client = await h.start();
    final aid = client.identity().anonymousId;
    client.identify('user_42', {'plan': 'pro'});
    expect(h.storage.data['mk_uid'], 'user_42');
    await client.flush();
    final id = h.events.last;
    expect((id['type'], id['name'], id['userId']), ('identify', r'$identify', 'user_42'));
    expect(id['traits'], {'plan': 'pro'});

    client.reset();
    expect(client.identity().userId, isNull);
    expect(client.identity().anonymousId, isNot(aid));
    expect(h.storage.data.containsKey('mk_uid'), isFalse);
    expect(h.storage.data['mk_aid'], client.identity().anonymousId);
  });

  test('opt-out clears the queue, persists, and makes no network calls', () async {
    final h = Harness();
    final client = await h.start();
    await Future<void>.delayed(Duration.zero); // let the launch config fetch finish
    client.optOut();
    h.requests.clear();
    client.track('a');
    await client.flush();
    await client.refreshConfig();
    final fb = await client.feedback.submit(category: FeedbackCategory.bug, message: 'x');
    expect(fb.ok, isFalse);
    expect(h.requests, isEmpty);
    expect(h.storage.data['mk_optout'], '1');
    client.dispose();

    final again = await h.start();
    expect(again.isOptedOut, isTrue);
    again.optIn();
    expect(h.storage.data.containsKey('mk_optout'), isFalse);
  });

  test('opt-out: a first launch while opted out creates no anonymous id', () async {
    final h = Harness();
    h.storage.data['mk_optout'] = '1';
    final client = await h.start();
    expect(client.identity().anonymousId, isNull);
    expect(h.storage.data.containsKey('mk_aid'), isFalse);
  });

  test('opt-out: an id stored from before is not used', () async {
    final h = Harness();
    h.storage.data['mk_optout'] = '1';
    h.storage.data['mk_aid'] = 'old-anon';
    final client = await h.start();
    expect(client.identity().anonymousId, isNull);
  });

  test('opt-out removes the stored anonymous and session ids, keeps the user id and consent', () async {
    final h = Harness();
    final client = await h.start();
    client.identify('user_42');
    client.consent(replay: true);
    client.track('a');
    await Future<void>.delayed(Duration.zero);
    expect(h.storage.data.keys, containsAll(['mk_aid', 'mk_sid', 'mk_queue']));
    client.optOut();
    await Future<void>.delayed(Duration.zero);
    expect(client.identity().anonymousId, isNull);
    expect(client.identity().sessionId, isNull);
    expect(h.storage.data.keys, isNot(anyOf(contains('mk_aid'), contains('mk_sid'), contains('mk_queue'))));
    expect(h.storage.data['mk_uid'], 'user_42');
    expect(h.storage.data['mk_consent'], 'replay');
    expect(h.storage.data['mk_optout'], '1');
  });

  test('reset while opted out creates no anonymous id; opt-in creates one and refetches the config', () async {
    final h = Harness(config: {'v': 1, 'campaigns': []});
    final client = await h.start();
    client.optOut();
    client.reset();
    await Future<void>.delayed(Duration.zero);
    expect(client.identity().anonymousId, isNull);
    expect(h.storage.data.containsKey('mk_aid'), isFalse);

    h.requests.clear();
    client.optIn();
    await Future<void>.delayed(Duration.zero);
    final aid = client.identity().anonymousId;
    expect(aid, isNotNull);
    expect(h.storage.data['mk_aid'], aid);
    expect(h.storage.data.containsKey('mk_optout'), isFalse);
    expect(h.requests.map((r) => r.url.path), contains('/v1/config'));
    client.track('back');
    await client.flush();
    expect(h.events.last['anonymousId'], aid);
  });

  test('app version and build are read from the package info; options override them', () async {
    PackageInfo.setMockInitialValues(
      appName: 'Example',
      packageName: 'com.example.app',
      version: '3.1.0',
      buildNumber: '310',
      buildSignature: '',
    );
    final client = await Harness(appInfo: false).start();
    expect(client.context['app'], {'version': '3.1.0', 'build': '310'});
    expect(client.appVersion, '3.1.0');
    client.dispose();

    final overridden = await Harness().start();
    expect(overridden.context['app'], {'version': '2.4.1', 'build': '41'});
  });

  test('cookieless: no ids, nothing persisted', () async {
    final h = Harness(cookieless: true);
    final client = await h.start();
    client.track('a');
    await client.flush();
    final e = h.events.last;
    expect(e.containsKey('anonymousId'), isFalse);
    expect(e.containsKey('sessionId'), isFalse);
    expect(h.storage.data, isEmpty);
  });

  test('beforeSend can scrub or drop events', () async {
    final h = Harness();
    final client = await h.start(beforeSend: (e) {
      if (e.name == 'secret') return null;
      e.properties?.remove('email');
      return e;
    });
    client.track('secret');
    client.track('ok', {'email': 'a@b.c', 'k': 1});
    await client.flush();
    expect(h.events.map((e) => e['name']), [r'$app_open', 'ok']);
    expect(h.events.last['properties'], {'k': 1});
  });

  test(r'formError collapses duplicates within 1.5s; u-turn precedes $screen', () async {
    final h = Harness();
    final client = await h.start();
    client.formError(form: 'signup', field: 'email', reason: 'invalid');
    h.clock += 1000;
    client.formError(form: 'signup', field: 'email', reason: 'invalid');
    h.clock += 1000;
    client.formError(form: 'signup', field: 'email', reason: 'invalid');
    client.screen('A');
    h.clock += 1000;
    client.screen('B');
    h.clock += 2000;
    client.screen('A');
    await client.flush();
    final names = h.events.map((e) => e['name']).toList();
    expect(names.where((n) => n == r'$form_error'), hasLength(2));
    final i = names.indexOf(r'$u_turn');
    expect(names[i + 1], r'$screen');
    final turn = h.events[i];
    expect(turn['path'], 'B');
    expect(turn['properties'], {'back_to': 'A', 'dwell_ms': 2000});
    expect(h.events[i + 1]['referrer'], 'B');
  });

  test('consent is persisted', () async {
    final h = Harness();
    final client = await h.start();
    client.consent(replay: true);
    expect(h.storage.data['mk_consent'], 'replay');
    expect(client.hasConsent('replay'), isTrue);
    client.consent(replay: false);
    expect(h.storage.data['mk_consent'], '');
  });

  test('feedback: body fields and response id', () async {
    final h = Harness();
    final client = await h.start();
    client.screen('Checkout');
    final r = await client.feedback.submit(category: FeedbackCategory.accessibility, message: 'Button has no label', rating: 2);
    expect(r.ok, isTrue);
    expect(r.id, 'fb_1');
    final req = h.requests.firstWhere((r) => r.url.path == '/v1/feedback');
    final body = jsonDecode(req.body) as Map<String, dynamic>;
    expect(body['category'], 'accessibility');
    expect(body['platform'], 'flutter');
    expect(body['path'], 'Checkout');
    expect(body['appVersion'], '2.4.1');
    expect(body['rating'], 2);
    expect(body['anonymousId'], isA<String>());
    expect((body['device'] as Map)['model'], 'Pixel 9');
  });

  test('feedback: switched off for flutter in the config', () async {
    final h = Harness(config: {
      'v': 1,
      'campaigns': [],
      'feedback': {'platforms': ['web', 'ios'], 'enabled': true},
    });
    final client = await h.start();
    await client.refreshConfig();
    expect(client.feedback.isEnabled, isFalse);
    final r = await client.feedback.submit(category: FeedbackCategory.bug, message: 'Broken');
    expect(r.ok, isFalse);
    expect(h.requests.where((r) => r.url.path == '/v1/feedback'), isEmpty);
  });

  test('feedback: configs without a platform list allow it', () async {
    final h = Harness(config: {'v': 1, 'campaigns': [], 'feedback': {'enabled': false}});
    final client = await h.start();
    await client.refreshConfig();
    expect(client.feedback.isEnabled, isTrue);
  });

  test('config: GET /v1/config?key=…', () async {
    final h = Harness(config: {'v': 1, 'campaigns': []});
    final client = await h.start();
    await client.refreshConfig();
    final req = h.requests.lastWhere((r) => r.url.path == '/v1/config');
    expect(req.method, 'GET');
    expect(req.url.queryParameters['key'], 'wk_test');
    expect(client.config, isNotNull);
  });
}
