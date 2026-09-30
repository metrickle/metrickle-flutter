import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:metrickle/metrickle.dart';

const day = 86400000;

/// A client wired to in-memory storage, a fake clock and a mock server.
class Harness {
  Harness({this.config, this.cookieless = false});

  final Map<String, Object?>? config;
  final bool cookieless;
  final storage = MemoryStorage();
  final requests = <http.Request>[];
  int status = 200;
  int clock = 100 * day;

  late final MockClient mock = MockClient((req) async {
    requests.add(req);
    if (req.url.path == '/v1/config') {
      return config == null ? http.Response('{}', 404) : http.Response(jsonEncode(config), 200);
    }
    if (req.url.path == '/v1/feedback') return http.Response('{"id":"fb_1"}', 200);
    return http.Response('{}', status);
  });

  List<http.Request> get batches => requests.where((r) => r.url.path == '/v1/batch').toList();

  List<Map<String, dynamic>> get events => [
        for (final r in batches)
          for (final e in (jsonDecode(r.body) as Map<String, dynamic>)['events'] as List) e as Map<String, dynamic>,
      ];

  Future<Metrickle> start({MetrickleEvent? Function(MetrickleEvent)? beforeSend}) =>
      Metrickle.init(
        writeKey: 'wk_test',
        options: MetrickleOptions(
          host: 'https://in.example.com/',
          storage: storage,
          cookieless: cookieless,
          httpClient: mock,
          clock: () => clock,
          flushInterval: const Duration(hours: 1),
          appVersion: '2.4.1',
          appBuild: '41',
          deviceModel: 'Pixel 9',
          osVersion: '15',
          timezone: 'Europe/London',
          beforeSend: beforeSend,
        ),
      );
}

CampaignConfig campaign({
  Trigger trigger = const Trigger(kind: 'load'),
  List<String>? platforms,
  List<String>? appVersions,
  List<String>? a11y,
  bool identifiedOnly = false,
  double sampleRate = 1,
  Frequency frequency = const Frequency(),
  String id = 'cmp_1',
  List<Question>? questions,
}) =>
    CampaignConfig(
      id: id,
      version: 1,
      questions: questions ??
          const [
            Question(id: 'nps', type: 'nps', prompt: 'How likely are you to recommend us?'),
            Question(id: 'why', type: 'text', prompt: 'Why?', required: false),
          ],
      targeting: Targeting(
        trigger: trigger,
        platforms: platforms,
        appVersions: appVersions,
        a11y: a11y,
        identifiedOnly: identifiedOnly,
        sampleRate: sampleRate,
        frequency: frequency,
      ),
    );
