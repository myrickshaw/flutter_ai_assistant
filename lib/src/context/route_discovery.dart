import '../models/app_context_snapshot.dart';
import 'ai_navigator_observer.dart';

/// Discovers and maintains a list of all available routes in the app.
///
/// Routes are discovered through three sources:
/// 1. Developer-provided [knownRoutes] (most complete, optional)
/// 2. Routes observed via [AiNavigatorObserver] (progressive, automatic)
/// 3. Route descriptions provided by the developer (optional enrichment)
class RouteDiscovery {
  /// Developer-provided route names.
  final List<String> _knownRoutes;

  /// Developer-provided descriptions for routes.
  final Map<String, String> _routeDescriptions;

  RouteDiscovery({
    List<String> knownRoutes = const [],
    Map<String, String> routeDescriptions = const {},
  }) : _knownRoutes = knownRoutes,
       _routeDescriptions = routeDescriptions;

  /// Get all known routes, combining developer-provided and discovered routes.
  List<RouteInfo> getAvailableRoutes() {
    // Merge developer-provided routes with discovered routes.
    final allRouteNames = <String>{
      ..._knownRoutes,
      ...AiNavigatorObserver.discoveredRoutes,
    };

    return allRouteNames.map((name) {
      return RouteInfo(
        name: name,
        description: _routeDescriptions[name] ?? _inferDescription(name),
        cachedContext: AiNavigatorObserver.screenKnowledge[name],
      );
    }).toList()..sort((a, b) => a.name.compareTo(b.name));
  }

  /// Try to infer a human-readable description from the route name.
  /// Converts "riderHomeScreen" → "Rider home screen".
  String? _inferDescription(String routeName) {
    // Remove leading slash if present.
    var name = routeName.startsWith('/') ? routeName.substring(1) : routeName;
    if (name.isEmpty) return 'Home screen';

    // Split camelCase and PascalCase.
    final words = name
        .replaceAllMapped(RegExp(r'([a-z])([A-Z])'), (m) => '${m[1]} ${m[2]}')
        .replaceAll(RegExp(r'[_-]'), ' ')
        .trim();

    if (words.isEmpty) return null;

    // Capitalize first letter.
    return words[0].toUpperCase() + words.substring(1).toLowerCase();
  }
}
