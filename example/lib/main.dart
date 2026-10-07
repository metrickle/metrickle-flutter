import 'package:flutter/material.dart';
import 'package:metrickle/metrickle.dart';

Future<void> main() async {
  await Metrickle.init(
    writeKey: 'mk_live_your_write_key',
    // The app version and build are read from the package info.
    options: const MetrickleOptions(debug: true),
  );
  runApp(const ExampleApp());
}

class ExampleApp extends StatelessWidget {
  const ExampleApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Metrickle example',
        theme: ThemeData(colorSchemeSeed: Colors.indigo),
        darkTheme: ThemeData(colorSchemeSeed: Colors.indigo, brightness: Brightness.dark),
        navigatorObservers: [MetrickleNavigatorObserver()],
        builder: (context, child) => MetrickleScope(child: child!),
        initialRoute: 'Home',
        routes: {'Home': (_) => const HomePage(), 'Checkout': (_) => const CheckoutPage()},
      );
}

class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Home')),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            FilledButton(
              onPressed: () => Navigator.pushNamed(context, 'Checkout'),
              child: const Text('Go to checkout'),
            ),
            // Hidden while feedback is switched off for Flutter in the dashboard.
            ValueListenableBuilder(
              valueListenable: Metrickle.instance.configListenable,
              builder: (context, _, _) => !Metrickle.instance.feedback.isEnabled
                  ? const SizedBox.shrink()
                  : Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: OutlinedButton(
                        onPressed: () async {
                          final messenger = ScaffoldMessenger.of(context);
                          final result = await Metrickle.instance.feedback.submit(
                            category: FeedbackCategory.idea,
                            message: 'Sent from the example app',
                          );
                          messenger.showSnackBar(SnackBar(content: Text(result.ok ? 'Thanks!' : 'Could not send')));
                        },
                        child: const Text('Send feedback'),
                      ),
                    ),
            ),
          ],
        ),
      );
}

class CheckoutPage extends StatelessWidget {
  const CheckoutPage({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Checkout')),
        body: Center(
          child: Semantics(
            identifier: 'pay-button',
            child: FilledButton(
              onPressed: () => Metrickle.instance.track('checkout_completed', {'items': 2}),
              child: const Text('Pay'),
            ),
          ),
        ),
      );
}
