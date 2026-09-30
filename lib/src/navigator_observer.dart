import 'package:flutter/widgets.dart';

import 'client.dart';

/// Sends a `$screen` event whenever the visible route changes. Uses `route.settings.name`; unnamed
/// routes and popups (dialogs, menus, sheets) are skipped unless [nameExtractor] names them.
///
/// ```dart
/// MaterialApp(navigatorObservers: [MetrickleNavigatorObserver()], …)
/// GoRouter(observers: [MetrickleNavigatorObserver()], routes: […])
/// ```
///
/// It also lets [MetrickleScope] present the built-in survey sheet on this navigator.
class MetrickleNavigatorObserver extends NavigatorObserver {
  MetrickleNavigatorObserver({this.nameExtractor, Metrickle? client}) : _client = client {
    _all.add(WeakReference(this));
  }

  /// Returns a screen name for [route], or null to fall back to the default rule.
  final String? Function(Route<dynamic> route)? nameExtractor;
  final Metrickle? _client;

  static final _all = <WeakReference<MetrickleNavigatorObserver>>[];

  /// The navigator of the most recently created observer that is attached, for the survey sheet.
  static NavigatorState? get attachedNavigator {
    _all.removeWhere((r) => r.target == null);
    for (final r in _all.reversed) {
      final nav = r.target?.navigator;
      if (nav != null && nav.mounted) return nav;
    }
    return null;
  }

  /// The screen name reported for [route], or null to skip it.
  String? screenName(Route<dynamic> route) {
    final custom = nameExtractor?.call(route);
    if (custom != null) return custom;
    if (route is PopupRoute) return null;
    final name = route.settings.name;
    return name == null || name.isEmpty ? null : name;
  }

  void _report(Route<dynamic>? route) {
    final client = _client ?? Metrickle.maybeInstance;
    if (route == null || client == null) return;
    final name = screenName(route);
    // Closing a dialog reveals the same screen again: not a new view.
    if (name == null || name == client.currentScreen) return;
    client.screen(name);
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) => _report(route);

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) => _report(previousRoute);

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) => _report(newRoute);
}
