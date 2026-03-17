import 'package:flutter/widgets.dart';

import 'context_cache.dart';

/// WidgetsBindingObserver that triggers cache invalidation on system events.
///
/// Automatically invalidates the appropriate cache level when:
/// - App resumes from background → invalidates session + screen
/// - Screen metrics change → invalidates screen
/// - System navigation events → invalidates screen
class ContextInvalidator with WidgetsBindingObserver {
  final ContextCache cache;

  ContextInvalidator({required this.cache});

  /// Register this observer with the Flutter binding.
  void attach() {
    WidgetsBinding.instance.addObserver(this);
  }

  /// Unregister this observer.
  void detach() {
    WidgetsBinding.instance.removeObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // App returned from background — state may have changed.
      cache.invalidateSession();
    }
  }

  @override
  void didChangeMetrics() {
    // Screen size/orientation changed — layout may differ.
    cache.invalidateScreen();
  }

  @override
  Future<bool> didPushRouteInformation(RouteInformation routeInformation) async {
    // System-level navigation (deep link).
    cache.invalidateScreen();
    return false;
  }

  @override
  Future<bool> didPopRoute() async {
    cache.invalidateScreen();
    return false;
  }
}
