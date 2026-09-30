import 'dart:math' as math;
import 'dart:ui' show Color;

/// WCAG 2.x contrast ratio between two #rrggbb colours (1 to 21). Port of `contrastRatio`.
double contrastRatio(String a, String b) {
  double lum(String hex) {
    final c = [1, 3, 5].map((i) {
      final v = int.parse(hex.substring(i, i + 2), radix: 16) / 255;
      return v <= 0.04045 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
    }).toList();
    return 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2];
  }

  final x = lum(a), y = lum(b);
  return (math.max(x, y) + 0.05) / (math.min(x, y) + 0.05);
}

/// Text colour for a brand fill: white when it reaches 4.5:1, otherwise black. Port of `textOn`.
String textOn(String fill) => contrastRatio(fill, '#ffffff') >= 4.5 ? '#ffffff' : '#000000';

/// `#rrggbb` for an opaque [Color].
String colorToHex(Color c) {
  String h(double v) => (v * 255).round().clamp(0, 255).toRadixString(16).padLeft(2, '0');
  return '#${h(c.r)}${h(c.g)}${h(c.b)}';
}

/// Parses `#rrggbb`, or null when malformed.
Color? hexToColor(String? hex) {
  if (hex == null || !RegExp(r'^#[0-9a-fA-F]{6}$').hasMatch(hex)) return null;
  return Color(0xff000000 | int.parse(hex.substring(1), radix: 16));
}
