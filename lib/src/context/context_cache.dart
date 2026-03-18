import 'dart:collection';

import '../core/ai_logger.dart';
import 'ai_navigator_observer.dart';
import 'screen_context.dart';

/// Entry in the cache with a timestamp for TTL validation.
class _CacheEntry<T> {
  final T value;
  final DateTime cachedAt;

  _CacheEntry(this.value) : cachedAt = DateTime.now();

  bool isExpired(Duration ttl) {
    return DateTime.now().difference(cachedAt) > ttl;
  }
}

/// Multi-level LRU cache for app context.
///
/// Three cache levels with independent TTLs:
/// - L1 (Global): user auth state, app config — TTL 5 minutes
/// - L2 (Session): navigation stack, visited routes — TTL 30 seconds
/// - L3 (Screen): current screen semantics snapshot — TTL configurable (default 10s)
class ContextCache {
  /// TTL for screen-level context (L3). Configurable.
  final Duration screenTtl;

  static const _globalTtl = Duration(minutes: 5);
  static const _sessionTtl = Duration(seconds: 30);
  static const _maxScreenEntries = 10;

  _CacheEntry<Map<String, dynamic>>? _globalCache;
  _CacheEntry<Map<String, dynamic>>? _sessionCache;

  /// LRU cache for screen contexts keyed by route name.
  final LinkedHashMap<String, _CacheEntry<ScreenContext>> _screenCache =
      LinkedHashMap<String, _CacheEntry<ScreenContext>>();

  /// Dirty flags for lazy rebuilding.
  bool _screenDirty = true;
  bool _sessionDirty = true;
  bool _globalDirty = true;

  /// Whether the last [getScreenContext] call triggered a rebuild (was dirty).
  /// Used by the controller to decide if screen stabilization is needed.
  bool _wasDirty = false;
  bool get wasDirty => _wasDirty;

  /// Callback to capture fresh screen context.
  final ScreenContext Function()? onCaptureScreen;

  /// Callback to capture fresh global context.
  final Future<Map<String, dynamic>> Function()? onCaptureGlobal;

  ContextCache({
    this.screenTtl = const Duration(seconds: 10),
    this.onCaptureScreen,
    this.onCaptureGlobal,
  });

  /// Get or rebuild the screen context for the current route.
  ScreenContext getScreenContext(String? currentRoute) {
    if (currentRoute != null && !_screenDirty) {
      final entry = _screenCache[currentRoute];
      if (entry != null && !entry.isExpired(screenTtl)) {
        // Move to end (most recently used).
        _screenCache.remove(currentRoute);
        _screenCache[currentRoute] = entry;
        AiLogger.log(
          'Screen cache HIT for route "$currentRoute"',
          tag: 'Cache',
        );
        _wasDirty = false;
        return entry.value;
      }
    }

    // Rebuild.
    _wasDirty = true;
    AiLogger.log(
      'Screen cache MISS for route "$currentRoute" — rebuilding',
      tag: 'Cache',
    );
    final context = onCaptureScreen?.call() ?? ScreenContext.empty();
    if (currentRoute != null) {
      _screenCache[currentRoute] = _CacheEntry(context);
      // Evict LRU if over capacity.
      while (_screenCache.length > _maxScreenEntries) {
        final evicted = _screenCache.keys.first;
        _screenCache.remove(evicted);
        AiLogger.log('Screen cache evicted LRU entry "$evicted"', tag: 'Cache');
      }
      // Store in progressive knowledge.
      AiNavigatorObserver.cacheScreenKnowledge(currentRoute, context);
    }
    _screenDirty = false;
    return context;
  }

  /// Get or rebuild the global context.
  Future<Map<String, dynamic>> getGlobalContext() async {
    if (!_globalDirty &&
        _globalCache != null &&
        !_globalCache!.isExpired(_globalTtl)) {
      AiLogger.log(
        'Global cache HIT (${_globalCache!.value.length} keys)',
        tag: 'Cache',
      );
      return _globalCache!.value;
    }

    AiLogger.log('Global cache MISS — rebuilding', tag: 'Cache');
    final context = await onCaptureGlobal?.call() ?? {};
    _globalCache = _CacheEntry(context);
    _globalDirty = false;
    AiLogger.log(
      'Global cache rebuilt with ${context.length} keys',
      tag: 'Cache',
    );
    return context;
  }

  /// Build the session context (nav stack + discovered routes).
  Map<String, dynamic> getSessionContext() {
    if (!_sessionDirty &&
        _sessionCache != null &&
        !_sessionCache!.isExpired(_sessionTtl)) {
      AiLogger.log('Session cache HIT', tag: 'Cache');
      return _sessionCache!.value;
    }

    AiLogger.log('Session cache MISS — rebuilding', tag: 'Cache');
    final context = {
      'currentRoute': AiNavigatorObserver.currentRoute,
      'navigationStack': AiNavigatorObserver.routeStack,
      'discoveredRoutes': AiNavigatorObserver.discoveredRoutes.toList(),
    };
    _sessionCache = _CacheEntry(context);
    _sessionDirty = false;
    AiLogger.log(
      'Session cache rebuilt: route=${context['currentRoute']}, '
      'stack=${(context['navigationStack'] as List).length} entries, '
      'discovered=${(context['discoveredRoutes'] as List).length} routes',
      tag: 'Cache',
    );
    return context;
  }

  /// Mark the screen context as stale (e.g., after a route change or UI update).
  void invalidateScreen() {
    AiLogger.log('Screen cache invalidated', tag: 'Cache');
    _screenDirty = true;
  }

  /// Mark session context as stale (e.g., after app resume).
  void invalidateSession() {
    AiLogger.log('Session + screen cache invalidated', tag: 'Cache');
    _sessionDirty = true;
    _screenDirty = true;
  }

  /// Mark everything as stale (e.g., after login/logout).
  void invalidateAll() {
    AiLogger.log(
      'All caches invalidated (global + session + screen)',
      tag: 'Cache',
    );
    _globalDirty = true;
    _sessionDirty = true;
    _screenDirty = true;
  }

  /// Get all cached screen knowledge for progressive learning.
  Map<String, ScreenContext> get screenKnowledge {
    return AiNavigatorObserver.screenKnowledge;
  }

  /// Clear all caches.
  void clear() {
    AiLogger.log('All caches cleared', tag: 'Cache');
    _globalCache = null;
    _sessionCache = null;
    _screenCache.clear();
    _globalDirty = true;
    _sessionDirty = true;
    _screenDirty = true;
  }
}
