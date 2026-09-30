import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:metrickle/metrickle.dart';

import 'helpers.dart';

class FakeSurvey implements ActiveSurvey {
  FakeSurvey(this.campaign);
  @override
  final CampaignConfig campaign;
  final log = <String>[];
  final answers = <(String, SurveyAnswer)>[];
  @override
  void shown() => log.add('shown');
  @override
  void answer(Question q, SurveyAnswer a) => answers.add((q.id, a));
  @override
  void complete() => log.add('complete');
  @override
  void dismiss(int atIndex) => log.add('dismiss $atIndex');
}

Widget sheetApp(ActiveSurvey s, {ThemeData? theme, Color? accent}) => MaterialApp(
      theme: theme,
      home: Scaffold(body: Align(alignment: Alignment.bottomCenter, child: MetrickleSurveySheet(survey: s, accent: accent))),
    );

void main() {
  group('survey sheet', () {
    testWidgets('scale: labels with end labels, selected state, heading, focus', (tester) async {
      final handle = tester.ensureSemantics();
      final s = FakeSurvey(campaign());
      await tester.pumpWidget(sheetApp(s));
      await tester.pump();
      expect(s.log, ['shown']);

      final low = find.bySemanticsLabel('0, Not at all likely');
      expect(low, findsOneWidget);
      expect(find.bySemanticsLabel('10, Extremely likely'), findsOneWidget);
      expect(tester.getSemantics(low), isSemantics(label: '0, Not at all likely', isButton: true, isInMutuallyExclusiveGroup: true, isSelected: false, hasTapAction: true));
      expect(tester.getSemantics(find.text('Quick survey · 1 of 2')), isSemantics(isHeader: true));
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'metrickle survey heading');
      expect(find.byTooltip('Close survey'), findsOneWidget);

      await tester.tap(find.text('7'));
      await tester.pump();
      expect(tester.getSemantics(find.bySemanticsLabel('7')), isSemantics(isSelected: true, isChecked: true));
      // Tapping the selected option again clears it.
      await tester.tap(find.text('7'));
      await tester.pump();
      expect(tester.getSemantics(find.bySemanticsLabel('7')), isSemantics(isSelected: false));

      await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
      await expectLater(tester, meetsGuideline(iOSTapTargetGuideline));
      await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
      // Needs a screenshot of the layer tree, which web tests can't take.
      if (!kIsWeb) await expectLater(tester, meetsGuideline(textContrastGuideline));
      handle.dispose();
    });

    testWidgets('required question shows an error; answers flow to thank-you', (tester) async {
      final s = FakeSurvey(campaign());
      await tester.pumpWidget(sheetApp(s));
      await tester.pump();
      await tester.tap(find.text('Next'));
      await tester.pump();
      expect(find.text('Please choose an answer, or close the survey.'), findsOneWidget);

      await tester.tap(find.text('9'));
      await tester.tap(find.text('Next'));
      await tester.pump();
      expect(find.text('Quick survey · 2 of 2'), findsOneWidget);
      expect(find.text('Skip'), findsOneWidget); // optional question
      await tester.enterText(find.byType(TextField), 'Fast checkout');
      await tester.tap(find.text('Submit'));
      await tester.pump();
      expect(find.text('Thanks for your feedback'), findsOneWidget);
      expect(s.answers.map((a) => a.$1), ['nps', 'why']);
      expect(s.answers.first.$2.score, 9);
      expect(s.answers.last.$2.text, 'Fast checkout');
      expect(s.log, ['shown', 'complete']);
      await tester.pump(const Duration(seconds: 7)); // auto-close timer
    });

    testWidgets('dark theme, large text and choice questions stay accessible', (tester) async {
      final handle = tester.ensureSemantics();
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.platformDispatcher.clearAllTestValues);
      final s = FakeSurvey(campaign(questions: const [
        Question(id: 'why', type: 'choice', prompt: 'What stopped you?', choices: ['Price', 'Shipping', 'Something else']),
        Question(id: 'all', type: 'choice', prompt: 'Which apply?', multiple: true, choices: ['A', 'B']),
      ]));
      await tester.pumpWidget(sheetApp(s, theme: ThemeData.dark()));
      await tester.pump();
      expect(tester.takeException(), isNull, reason: 'no overflow at 200% text');
      await tester.tap(find.text('Shipping'));
      await tester.pump();
      await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
      await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
      // Needs a screenshot of the layer tree, which web tests can't take.
      if (!kIsWeb) await expectLater(tester, meetsGuideline(textContrastGuideline));
      await tester.tap(find.text('Next'));
      await tester.pump();
      expect(find.text('Which apply? (choose all that apply)'), findsOneWidget);
      await tester.tap(find.text('A'));
      await tester.tap(find.text('B'));
      await tester.pump();
      await tester.tap(find.text('Submit'));
      await tester.pump();
      expect(s.answers.first.$2.values, ['Shipping']);
      expect(s.answers.last.$2.values, ['A', 'B']);
      await tester.pump(const Duration(seconds: 7));
      handle.dispose();
    });

    testWidgets('accent is used only with 4.5:1 contrast', (tester) async {
      Color? primaryFor(Color accent) {
        final btn = tester.widget<Material>(
          find.descendant(of: find.byKey(const ValueKey('metrickle-score-5')), matching: find.byType(Material)).first,
        );
        return btn.color == Colors.transparent ? null : btn.color;
      }

      for (final (accent, used) in [(const Color(0xff1f6fcf), true), (const Color(0xffffee58), false)]) {
        final s = FakeSurvey(campaign());
        await tester.pumpWidget(sheetApp(s, accent: accent));
        await tester.pump();
        await tester.tap(find.text('5'));
        await tester.pump();
        expect(primaryFor(accent) == accent, used);
        await tester.pumpWidget(const SizedBox());
      }
    });
  });

  group('navigator observer and scope', () {
    tearDown(() => Metrickle.maybeInstance?.dispose());

    Future<Harness> boot(WidgetTester tester, {Map<String, Object?>? config}) async {
      final h = Harness(config: config);
      await tester.runAsync(() => h.start());
      return h;
    }

    Future<List<Map<String, dynamic>>> sent(WidgetTester tester, Harness h) async {
      await tester.runAsync(() => Metrickle.instance.flush(force: true));
      return h.events;
    }

    testWidgets('named routes become \$screen events; popups and unnamed routes are skipped', (tester) async {
      final h = await boot(tester);
      final nav = GlobalKey<NavigatorState>();
      await tester.pumpWidget(MaterialApp(
        navigatorKey: nav,
        navigatorObservers: [MetrickleNavigatorObserver()],
        builder: (context, child) => MetrickleScope(child: child!),
        initialRoute: 'Home',
        routes: {
          'Home': (_) => const Text('home'),
          'Settings': (_) => const Text('settings'),
        },
      ));
      unawaited(nav.currentState!.pushNamed('Settings'));
      await tester.pumpAndSettle();
      unawaited(showDialog<void>(context: nav.currentContext!, builder: (_) => const Text('dialog')));
      await tester.pumpAndSettle();
      nav.currentState!.pop(); // dialog
      await tester.pumpAndSettle();
      unawaited(nav.currentState!.push(MaterialPageRoute<void>(builder: (_) => const Text('anon'))));
      await tester.pumpAndSettle();
      nav.currentState!.pop();
      await tester.pumpAndSettle();
      nav.currentState!.pop(); // back to Home
      await tester.pumpAndSettle();

      final screens = (await sent(tester, h)).where((e) => e['name'] == r'$screen').map((e) => (e['path'], e['referrer'])).toList();
      expect(screens, [('Home', null), ('Settings', 'Home'), ('Home', 'Settings')]);
    });

    testWidgets('nameExtractor names any route', (tester) async {
      final h = await boot(tester);
      final nav = GlobalKey<NavigatorState>();
      await tester.pumpWidget(MaterialApp(
        navigatorKey: nav,
        navigatorObservers: [MetrickleNavigatorObserver(nameExtractor: (r) => r is DialogRoute ? 'Dialog' : null)],
        home: const Text('home'),
      ));
      unawaited(showDialog<void>(context: nav.currentContext!, builder: (_) => const Text('dialog')));
      await tester.pumpAndSettle();
      final paths = (await sent(tester, h)).where((e) => e['name'] == r'$screen').map((e) => e['path']);
      expect(paths, ['/', 'Dialog']);
    });

    testWidgets('scope: a11y context from MediaQuery, keyboard, rage taps', (tester) async {
      final h = await boot(tester);
      tester.platformDispatcher.accessibilityFeaturesTestValue = const FakeAccessibilityFeatures(accessibleNavigation: true, boldText: true);
      tester.platformDispatcher.textScaleFactorTestValue = 1.3;
      addTearDown(tester.platformDispatcher.clearAllTestValues);
      await tester.pumpWidget(MaterialApp(
        builder: (context, child) => MetrickleScope(child: child!),
        home: Scaffold(
          body: Center(
            child: Semantics(
              identifier: 'pay-button',
              child: ElevatedButton(onPressed: () {}, child: const Text('Pay now')),
            ),
          ),
        ),
      ));
      expect(Metrickle.instance.a11y, ['screen_reader', 'bold_text', 'large_text']);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      expect(Metrickle.instance.a11y, contains('keyboard'));

      for (var i = 0; i < 3; i++) {
        await tester.tap(find.text('Pay now'));
        await tester.pump(const Duration(milliseconds: 100));
      }
      final rage = (await sent(tester, h)).where((e) => e['name'] == r'$rage_click').toList();
      expect(rage, hasLength(1));
      expect(rage.single['properties'], {'selector': 'pay-button', 'text': 'Pay now'});
      final ctx = jsonDecode(h.batches.last.body)['context'] as Map;
      expect(ctx['a11y'], ['screen_reader', 'keyboard', 'bold_text', 'large_text']);
    });

    testWidgets('rage taps never read text field contents', (tester) async {
      final h = await boot(tester);
      await tester.pumpWidget(MaterialApp(
        builder: (context, child) => MetrickleScope(child: child!),
        home: const Scaffold(body: Center(child: TextField(key: ValueKey('email')))),
      ));
      await tester.enterText(find.byType(TextField), 'secret@example.com');
      for (var i = 0; i < 3; i++) {
        await tester.tap(find.byType(TextField));
        await tester.pump(const Duration(milliseconds: 100));
      }
      await tester.pump(const Duration(seconds: 1));
      final rage = (await sent(tester, h)).singleWhere((e) => e['name'] == r'$rage_click');
      expect(rage['properties']['selector'], 'email');
      expect(rage['properties']['text'], isNull);
      expect(jsonEncode(h.events), isNot(contains('secret@example.com')));
    });

    testWidgets('built-in sheet opens on trigger; Escape dismisses it', (tester) async {
      final h = await boot(tester, config: {
        'v': 1,
        'campaigns': [
          {
            'id': 'cmp_1',
            'version': 2,
            'questions': [
              {'id': 'csat', 'type': 'csat', 'prompt': 'How was checkout?'},
            ],
            'targeting': {
              'trigger': {'kind': 'page', 'match': 'Checkout'},
            },
          },
        ],
      });
      await tester.runAsync(() => Metrickle.instance.refreshConfig());
      final nav = GlobalKey<NavigatorState>();
      await tester.pumpWidget(MaterialApp(
        navigatorKey: nav,
        navigatorObservers: [MetrickleNavigatorObserver()],
        builder: (context, child) => MetrickleScope(child: child!),
        home: const Text('home'),
        routes: {'Checkout': (_) => const Text('checkout')},
      ));
      unawaited(nav.currentState!.pushNamed('Checkout'));
      await tester.pumpAndSettle();
      expect(find.text('How was checkout?'), findsOneWidget);
      expect(find.bySemanticsLabel('1, Very dissatisfied'), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text('How was checkout?'), findsNothing);
      final names = (await sent(tester, h)).map((e) => e['name']);
      expect(names, containsAllInOrder([r'$survey_shown', r'$survey_dismissed']));
    });
  });
}

void unawaited(Future<void> f) {}
