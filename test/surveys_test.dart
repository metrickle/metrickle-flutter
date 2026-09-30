import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:metrickle/metrickle.dart';

import 'helpers.dart';

EligibilityContext ctx({String? userId, List<String> a11y = const []}) =>
    (anonymousId: 'anon-1', userId: userId, platform: 'web', appVersion: '2.4.1', a11y: a11y, now: 100 * day);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('unitHash matches the JS SDK (FNV-1a over UTF-16, Math.imul)', () {
    // Vectors computed with packages/sdk/src/surveys.ts.
    const vectors = {
      '': 0.5043428998906165,
      'a': 0.8908105595037341,
      'anon-1:cmp_1': 0.10740100289694965,
      'u1:cmp_2': 0.9209592742845416,
      'héllo wörld': 0.8269328339956701,
      'emoji 😀 ✓': 0.10655983327887952,
      '550e8400-e29b-41d4-a716-446655440000:c_abc': 0.676084328442812,
    };
    vectors.forEach((s, v) => expect(unitHash(s), v, reason: s));
  });

  test('matchPattern: exact and trailing wildcard', () {
    expect(matchPattern('/checkout*', '/checkout/done'), isTrue);
    expect(matchPattern('/checkout*', '/pricing'), isFalse);
    expect(matchPattern('Home', 'Home'), isTrue);
    expect(matchPattern('Home', 'Homepage'), isFalse);
    expect(matchPattern('*', 'anything'), isTrue);
    expect(matchPattern('Home', null), isFalse);
  });

  test('targeting: platform, version prefix, a11y, identified, sampling', () {
    final empty = SurveyState();
    expect(eligible(campaign(), ctx(), empty), isTrue);
    expect(eligible(campaign(platforms: ['ios']), ctx(), empty), isFalse);
    expect(eligible(campaign(appVersions: ['2.4*']), ctx(), empty), isTrue);
    expect(eligible(campaign(appVersions: ['2.3*', '3.0.0']), ctx(), empty), isFalse);
    expect(eligible(campaign(a11y: ['screen_reader']), ctx(), empty), isFalse);
    expect(eligible(campaign(a11y: ['screen_reader']), ctx(a11y: ['screen_reader']), empty), isTrue);
    expect(eligible(campaign(identifiedOnly: true), ctx(), empty), isFalse);
    expect(eligible(campaign(identifiedOnly: true), ctx(userId: 'u1'), empty), isTrue);
    expect(eligible(campaign(sampleRate: 0), ctx(), empty), isFalse);
    // Sampling is deterministic per user and campaign.
    final r = unitHash('anon-1:cmp_1');
    expect(eligible(campaign(sampleRate: r + 0.001), ctx(), empty), isTrue);
    expect(eligible(campaign(sampleRate: r), ctx(), empty), isFalse);
  });

  test('frequency caps and the global cooldown', () {
    const now = 100 * day;
    SurveyState shown(CampaignState s, [int last = now - 40 * day]) => SurveyState(last: last, c: {'cmp_1': s});
    expect(eligible(campaign(), ctx(), shown(CampaignState(shown: now - 400 * day))), isFalse); // once
    final ua = campaign(frequency: const Frequency(kind: 'until_answered', days: 30));
    expect(eligible(ua, ctx(), shown(CampaignState(shown: now - 40 * day, dismissed: now - 40 * day))), isTrue);
    expect(eligible(ua, ctx(), shown(CampaignState(shown: now - 10 * day), now - 10 * day)), isFalse);
    expect(eligible(ua, ctx(), shown(CampaignState(shown: now - 40 * day, answered: now - 40 * day))), isFalse);
    final rec = campaign(frequency: const Frequency(kind: 'recurring', days: 30));
    expect(eligible(rec, ctx(), shown(CampaignState(shown: now - 31 * day, answered: now - 31 * day))), isTrue);
    expect(eligible(rec, ctx(), shown(CampaignState(shown: now - 29 * day))), isFalse);
    // Another survey shown in the last day blocks everything.
    expect(eligible(campaign(id: 'cmp_2'), ctx(), SurveyState(last: now - globalCooldownMs + 1000)), isFalse);
  });

  test('config parsing ignores anything with v != 1', () {
    expect(SdkConfig.tryParse({'v': 2, 'campaigns': []}), isNull);
    expect(SdkConfig.tryParse('nope'), isNull);
    final cfg = SdkConfig.tryParse({
      'v': 1,
      'campaigns': [
        {
          'id': 'c',
          'version': 3,
          'questions': [
            {'id': 'q', 'type': 'csat', 'prompt': 'Happy?'},
          ],
          'targeting': {
            'trigger': {'kind': 'page', 'match': 'Checkout*'},
          },
        },
      ],
      'feedback': {
        'branding': {'accent': '#1f6fcf'},
      },
    })!;
    final c = cfg.campaigns.single;
    expect(c.version, 3);
    expect(c.questions.single.required, isTrue);
    expect(c.targeting.sampleRate, 1);
    expect(c.targeting.frequency.kind, 'once');
    expect(c.targeting.trigger.delayMs, 0);
    expect(cfg.accent, '#1f6fcf');
  });

  test('contrastRatio and textOn match the JS helpers', () {
    expect(contrastRatio('#1f6fcf', '#ffffff'), closeTo(4.960978540464101, 1e-12));
    expect(contrastRatio('#777777', '#000000'), closeTo(4.68949989000882, 1e-12));
    expect(textOn('#1f6fcf'), '#ffffff');
    expect(textOn('#ffcc00'), '#000000');
  });

  group('engine', () {
    tearDown(() => Metrickle.maybeInstance?.dispose());

    Map<String, Object?> config(CampaignConfig c) => {
          'v': 1,
          'campaigns': [
            {
              'id': c.id,
              'version': c.version,
              'questions': [
                {'id': 'nps', 'type': 'nps', 'prompt': 'How likely are you to recommend us?', 'required': true},
                {'id': 'why', 'type': 'text', 'prompt': 'Why?', 'required': false},
              ],
              'targeting': {
                'trigger': {'kind': 'page', 'match': 'Checkout*', 'delayMs': 0},
                'sampleRate': 1,
                'frequency': {'kind': 'once'},
              },
            },
          ],
        };

    test('page trigger shows once, answers become \$survey_* events', () async {
      final h = Harness(config: config(campaign()));
      final client = await h.start();
      await client.refreshConfig();
      final shown = <ActiveSurvey>[];
      client.surveys.onShow(shown.add);

      client.screen('Pricing');
      await Future<void>.delayed(const Duration(milliseconds: 5));
      expect(shown, isEmpty);

      client.screen('CheckoutDone');
      await Future<void>.delayed(const Duration(milliseconds: 5));
      expect(shown, hasLength(1));
      final s = shown.single;
      s.shown();
      s.answer(s.campaign.questions[0], const SurveyAnswer(score: 3));
      s.answer(s.campaign.questions[1], const SurveyAnswer(text: '  The pay button did nothing  '));
      s.complete();

      // Frequency "once": never again, even on the trigger screen.
      client.screen('CheckoutAgain');
      await Future<void>.delayed(const Duration(milliseconds: 5));
      expect(shown, hasLength(1));

      await client.flush();
      final events = h.events.where((e) => (e['name'] as String).startsWith(r'$survey_')).toList();
      expect(events.map((e) => e['name']), [r'$survey_shown', r'$survey_answered', r'$survey_answered']);
      final nps = events[1]['properties'] as Map, why = events[2]['properties'] as Map;
      expect(nps, containsPair('campaign', 'cmp_1'));
      expect(nps, containsPair('question', 'nps'));
      expect(nps, containsPair('type', 'nps'));
      expect(nps, containsPair('score', 3));
      expect(nps, containsPair('completed', null));
      expect(nps, containsPair('value', null));
      expect(why, containsPair('question', 'why'));
      expect(why, containsPair('text', 'The pay button did nothing'));
      expect(why, containsPair('completed', true));
      expect(nps['response'], why['response']);
      expect(events[1]['path'], 'CheckoutDone');
      final state = jsonDecode(h.storage.data['mk_surveys']!) as Map;
      expect((state['c'] as Map)['cmp_1']['shown'], isA<int>());
      expect(state['last'], isA<int>());
    });

    test('dismiss records at/answered', () async {
      final h = Harness(config: config(campaign()));
      final client = await h.start();
      await client.refreshConfig();
      client.surveys.onShow((s) {
        s.shown();
        s.dismiss(0);
      });
      client.screen('Checkout');
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await client.flush();
      final d = h.events.firstWhere((e) => e['name'] == r'$survey_dismissed');
      expect(d['properties'], containsPair('at', 0));
      expect(d['properties'], containsPair('answered', 0));
    });

    test('cookieless clients (no storage) never show surveys', () async {
      final h = Harness(config: config(campaign()), cookieless: true);
      final client = await h.start();
      await client.refreshConfig();
      var shown = 0;
      client.surveys.onShow((_) => shown++);
      client.screen('Checkout');
      await Future<void>.delayed(const Duration(milliseconds: 5));
      expect(shown, 0);
    });
  });
}
