import 'dart:js_interop';

@JS('Intl.DateTimeFormat')
external _DateTimeFormat _dateTimeFormat();

extension type _DateTimeFormat(JSObject _) implements JSObject {
  external _ResolvedOptions resolvedOptions();
}

extension type _ResolvedOptions(JSObject _) implements JSObject {
  external String? get timeZone;
}

/// Browsers don't expose the OS version reliably.
String? platformOsVersion() => null;

/// IANA time zone from `Intl.DateTimeFormat`.
String? platformTimeZone() {
  try {
    return _dateTimeFormat().resolvedOptions().timeZone;
  } catch (_) {
    return null;
  }
}

/// Browsers forbid setting User-Agent; native platforms can.
const bool canSetUserAgent = false;
