import 'dart:typed_data';

import '../context/screen_context.dart';
import '../manifest/ai_app_manifest.dart';

/// Information about a named route in the app.
class RouteInfo {
  /// The route name (e.g., "/home", "/settings").
  final String name;

  /// Optional human-readable description of what this screen does.
  final String? description;

  /// Cached screen context from the last time this screen was visited
  /// (progressive learning).
  final ScreenContext? cachedContext;

  const RouteInfo({
    required this.name,
    this.description,
    this.cachedContext,
  });
}

/// Complete snapshot of the app's state sent to the LLM for context.
class AppContextSnapshot {
  /// The current route name.
  final String? currentRoute;

  /// Full navigation stack (bottom to top).
  final List<String> navigationStack;

  /// Semantics snapshot of the current screen.
  final ScreenContext screenContext;

  /// All known routes in the app.
  final List<RouteInfo> availableRoutes;

  /// Optional app-level state provided by the developer.
  final Map<String, dynamic>? globalState;

  /// Cached knowledge of previously visited screens.
  final Map<String, ScreenContext> screenKnowledge;

  /// Rich hierarchical app manifest (null if not configured).
  final AiAppManifest? appManifest;

  /// Screenshot of the current screen (PNG bytes), if available.
  final Uint8List? screenshot;

  const AppContextSnapshot({
    this.currentRoute,
    this.navigationStack = const [],
    required this.screenContext,
    this.availableRoutes = const [],
    this.globalState,
    this.screenKnowledge = const {},
    this.appManifest,
    this.screenshot,
  });

  /// Formats the entire context as a system prompt section for the LLM.
  String toSystemPrompt() {
    final buffer = StringBuffer();

    // Current location
    buffer.writeln('CURRENT SCREEN: ${currentRoute ?? "unknown"}');
    buffer.writeln('NAVIGATION STACK: [${navigationStack.join(' → ')}]');
    buffer.writeln();

    // What's on screen
    buffer.writeln('WHAT\'S ON SCREEN:');
    buffer.writeln(screenContext.toPromptString());
    buffer.writeln();

    // All available routes
    if (availableRoutes.isNotEmpty) {
      buffer.writeln('ALL APP SCREENS (you can navigate to any of these):');
      for (final route in availableRoutes) {
        if (route.description != null) {
          buffer.writeln('- ${route.name}: ${route.description}');
        } else {
          buffer.writeln('- ${route.name}');
        }
      }
      buffer.writeln();
    }

    // Progressive knowledge of previously visited screens
    if (screenKnowledge.isNotEmpty) {
      buffer.writeln('SCREENS YOU\'VE SEEN BEFORE:');
      for (final entry in screenKnowledge.entries) {
        final elements = entry.value.elements;
        if (elements.isNotEmpty) {
          final summary = elements
              .take(5)
              .map((e) => e.label)
              .where((l) => l.isNotEmpty)
              .join(', ');
          buffer.writeln('- ${entry.key}: contains [$summary${elements.length > 5 ? ', ...' : ''}]');
        }
      }
      buffer.writeln();
    }

    // Global state
    if (globalState != null && globalState!.isNotEmpty) {
      buffer.writeln('APP STATE:');
      for (final entry in globalState!.entries) {
        buffer.writeln('- ${entry.key}: ${entry.value}');
      }
      buffer.writeln();
    }

    return buffer.toString();
  }
}
