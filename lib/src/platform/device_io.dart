import 'dart:io';

import 'package:flutter/foundation.dart';

/// OS version from `Platform.operatingSystemVersion` ("Version 17.2 (Build 21C62)" → "17.2").
/// Android only exposes the kernel version there, so it is left out unless passed as an option.
String? platformOsVersion() {
  if (defaultTargetPlatform == TargetPlatform.android) return null;
  try {
    return RegExp(r'\d+(\.\d+)+').firstMatch(Platform.operatingSystemVersion)?.group(0);
  } catch (_) {
    return null;
  }
}

/// IANA time zone from `TZ` or the `/etc/localtime` link, when the OS exposes one.
String? platformTimeZone() {
  try {
    final tz = Platform.environment['TZ'];
    if (tz != null && tz.contains('/')) return tz.replaceFirst(':', '');
    final link = File('/etc/localtime').resolveSymbolicLinksSync();
    final i = link.indexOf('zoneinfo/');
    if (i >= 0) return link.substring(i + 9);
  } catch (_) {}
  return null;
}

/// Browsers forbid setting User-Agent; native platforms can.
const bool canSetUserAgent = true;
