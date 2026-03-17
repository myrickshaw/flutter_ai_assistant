import 'ai_action_manifest.dart';
import 'ai_navigation_link.dart';
import 'ai_section_manifest.dart';

/// Rich description of a single screen in the app.
///
/// This gives the agent a complete understanding of what a screen contains
/// and what can be done on it, without needing to visit it first.
class AiScreenManifest {
  /// The route name (e.g., "/wallet"). Must match the actual route constant.
  final String route;

  /// Human-readable screen title (e.g., "Wallet").
  final String title;

  /// 1-3 sentence description of what this screen does.
  final String description;

  /// Logical sections visible on this screen, ordered top-to-bottom.
  final List<AiSectionManifest> sections;

  /// Actions the user can take on this screen.
  final List<AiActionManifest> actions;

  /// Routes that are directly reachable FROM this screen.
  final List<AiNavigationLink> linksTo;

  /// Important notes or caveats about this screen.
  /// E.g., "Requires login", "Only visible to riders".
  final List<String> notes;

  const AiScreenManifest({
    required this.route,
    required this.title,
    required this.description,
    this.sections = const [],
    this.actions = const [],
    this.linksTo = const [],
    this.notes = const [],
  });
}
