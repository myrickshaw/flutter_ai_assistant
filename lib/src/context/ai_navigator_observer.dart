import 'package:flutter/widgets.dart';

import 'screen_context.dart';

/// NavigatorObserver that tracks the full route stack for the AI assistant.
///
/// Attach this to your MaterialApp's navigatorObservers list.
/// The AI assistant uses this to know which screen the user is on
/// and what navigation history exists.
class AiNavigatorObserver extends NavigatorObserver {
  static final List<String> _routeStack = [];
  static final Map<String, ScreenContext> _screenKnowledge = {};

  /// Callback fired when the route changes, used for cache invalidation.
  /// Mutable so the controller can temporarily swap it during handoff mode
  /// to also listen for route changes that indicate user action.
  void Function(String? newRoute)? onRouteChanged;

  AiNavigatorObserver({this.onRouteChanged});

  /// The name of the currently active route.
  static String? get currentRoute =>
      _routeStack.isNotEmpty ? _routeStack.last : null;

  /// Unmodifiable copy of the full navigation stack.
  static List<String> get routeStack => List.unmodifiable(_routeStack);

  /// All unique route names seen during this session.
  /// Cached to avoid recomputation on every access.
  static Set<String>? _discoveredRoutesCache;
  static Set<String> get discoveredRoutes {
    return _discoveredRoutesCache ??= {
      ..._routeStack,
      ..._screenKnowledge.keys,
    };
  }

  /// Cached screen knowledge from previously visited routes.
  static Map<String, ScreenContext> get screenKnowledge =>
      Map.unmodifiable(_screenKnowledge);

  /// Store a screen context snapshot for a route (progressive learning).
  static void cacheScreenKnowledge(String route, ScreenContext context) {
    _screenKnowledge[route] = context;
    _discoveredRoutesCache = null; // Invalidate cache
  }

  /// Reset all tracking state (e.g., on logout or hot restart).
  static void reset() {
    _routeStack.clear();
    _screenKnowledge.clear();
    _discoveredRoutesCache = null;
  }

  static void _removeLastRouteByName(String name) {
    for (int i = _routeStack.length - 1; i >= 0; i--) {
      if (_routeStack[i] == name) {
        _routeStack.removeAt(i);
        return;
      }
    }
  }

  static bool _replaceLastRouteName(String oldName, String newName) {
    for (int i = _routeStack.length - 1; i >= 0; i--) {
      if (_routeStack[i] == oldName) {
        _routeStack[i] = newName;
        return true;
      }
    }
    return false;
  }

  @override
  void didPush(Route route, Route? previousRoute) {
    super.didPush(route, previousRoute);
    final name = route.settings.name;
    if (name != null) {
      _routeStack.add(name);
      _discoveredRoutesCache = null;
      onRouteChanged?.call(name);
    }
  }

  @override
  void didPop(Route route, Route? previousRoute) {
    super.didPop(route, previousRoute);
    final name = route.settings.name;
    if (name != null) {
      _removeLastRouteByName(name);
      _discoveredRoutesCache = null;
    }
    onRouteChanged?.call(_routeStack.isNotEmpty ? _routeStack.last : null);
  }

  @override
  void didReplace({Route? newRoute, Route? oldRoute}) {
    super.didReplace(newRoute: newRoute, oldRoute: oldRoute);
    final oldName = oldRoute?.settings.name;
    final newName = newRoute?.settings.name;

    if (oldName != null && newName != null) {
      final replaced = _replaceLastRouteName(oldName, newName);
      if (!replaced) {
        _routeStack.add(newName);
      }
      _discoveredRoutesCache = null;
    } else if (oldName != null) {
      _removeLastRouteByName(oldName);
      _discoveredRoutesCache = null;
    } else if (newName != null) {
      _routeStack.add(newName);
      _discoveredRoutesCache = null;
    }
    onRouteChanged?.call(_routeStack.isNotEmpty ? _routeStack.last : null);
  }

  @override
  void didRemove(Route route, Route? previousRoute) {
    super.didRemove(route, previousRoute);
    final name = route.settings.name;
    if (name != null) {
      _removeLastRouteByName(name);
      _discoveredRoutesCache = null;
    }
    onRouteChanged?.call(_routeStack.isNotEmpty ? _routeStack.last : null);
  }
}
