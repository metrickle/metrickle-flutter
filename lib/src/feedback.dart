import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import 'client.dart';
import 'platform/device.dart';
import 'scope.dart';

/// `FEEDBACK_CATEGORIES`.
enum FeedbackCategory { bug, confusing, idea, accessibility, other }

/// Max decoded screenshot size accepted by `POST /v1/feedback`.
const maxScreenshotBytes = 2 * 1024 * 1024;

/// Result of [MetrickleFeedback.submit]; [id] is the report id on success.
typedef FeedbackResult = ({bool ok, String? id});

/// "Report a problem" submissions. Session, device, app version, locale and accessibility
/// context are attached automatically so the report links to the user's journey. Port of `feedback.ts`.
class MetrickleFeedback {
  MetrickleFeedback(this._client);
  final Metrickle _client;

  /// False when feedback is switched off for Flutter in the dashboard; [submit] then sends nothing.
  /// Use it to hide your own feedback button. True until the config has loaded.
  bool get isEnabled => _client.config?.feedbackPlatforms?.contains('flutter') ?? true;

  /// Sends a report. [screenshot] is a `data:image/png|jpeg;base64,…` URL, e.g. from
  /// [captureScreenshot]. [path] defaults to the current screen.
  Future<FeedbackResult> submit({
    required FeedbackCategory category,
    required String message,
    int? rating,
    String? screenshot,
    String? path,
  }) async {
    final c = _client;
    if (c.isOptedOut || !isEnabled) return (ok: false, id: null);
    if (screenshot != null && _decodedSize(screenshot) > maxScreenshotBytes) {
      if (c.options.debug) debugPrint('[metrickle] screenshot over 2 MB, not sent');
      return (ok: false, id: null);
    }
    final ctx = c.context;
    final id = c.identity();
    final device = ctx['device'] as Map<String, Object?>?;
    final body = {
      'writeKey': c.writeKey,
      'anonymousId': ?id.anonymousId,
      'userId': ?id.userId,
      'sessionId': ?id.sessionId,
      'category': category.name,
      'message': message,
      'rating': ?rating,
      'path': ?(path ?? c.currentScreen),
      'platform': 'flutter',
      'appVersion': ?(ctx['app'] as Map<String, Object?>?)?['version'],
      if (device != null) 'device': {'type': ?device['type'], 'os': ?device['os'], 'model': ?device['model']},
      'screen': ?ctx['screen'],
      'locale': ?ctx['locale'],
      'a11y': ?ctx['a11y'],
      'screenshot': ?screenshot,
    };
    try {
      final res = await c.httpClient.post(
        Uri.parse('${c.host}/v1/feedback'),
        headers: {
          'content-type': 'application/json',
          'x-metrickle-key': c.writeKey,
          if (canSetUserAgent) 'user-agent': c.userAgent,
        },
        body: jsonEncode(body),
      );
      if (res.statusCode < 200 || res.statusCode >= 300) return (ok: false, id: null);
      final data = jsonDecode(res.body);
      return (ok: true, id: data is Map ? data['id'] as String? : null);
    } catch (_) {
      return (ok: false, id: null);
    }
  }

  /// Captures a PNG screenshot as a data URL, downscaled to at most [maxDimension] px on the long
  /// edge and 2 MB. Uses [repaintBoundaryKey] (a `RepaintBoundary`'s key), or the app wrapped by
  /// [MetrickleScope]. Returns null when nothing can be captured.
  ///
  /// A screenshot may contain personal data: only attach one after the user opts in.
  Future<String?> captureScreenshot([GlobalKey? repaintBoundaryKey, int maxDimension = 1280]) async {
    final ro = (repaintBoundaryKey ?? MetrickleScope.boundaryKey)?.currentContext?.findRenderObject();
    if (ro is! RenderRepaintBoundary || !ro.hasSize || ro.size.isEmpty) return null;
    final longest = ro.size.longestSide;
    final dpr = _dpr(repaintBoundaryKey ?? MetrickleScope.boundaryKey);
    var ratio = math.min(dpr, maxDimension / longest);
    for (var attempt = 0; attempt < 5; attempt++) {
      final image = await ro.toImage(pixelRatio: ratio);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      if (bytes == null) return null;
      if (bytes.lengthInBytes <= maxScreenshotBytes) {
        return 'data:image/png;base64,${base64Encode(bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes))}';
      }
      ratio *= 0.7;
    }
    return null;
  }

  double _dpr(GlobalKey? key) {
    final ctx = key?.currentContext;
    return ctx == null ? 1.0 : MediaQuery.maybeDevicePixelRatioOf(ctx) ?? View.of(ctx).devicePixelRatio;
  }

  static int _decodedSize(String dataUrl) {
    final i = dataUrl.indexOf(',');
    final b64 = i < 0 ? dataUrl : dataUrl.substring(i + 1);
    return (b64.length * 3) ~/ 4;
  }
}
