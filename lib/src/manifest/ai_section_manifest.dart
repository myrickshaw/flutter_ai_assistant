import 'ai_element_manifest.dart';

/// A logical section within a screen (e.g., "Balance Card", "Transaction List").
///
/// Screens are typically composed of visual sections — a header area, a list,
/// a form, etc. This class describes one such section so the agent understands
/// the screen's layout without needing to visit it.
class AiSectionManifest {
  /// Section heading as it appears on screen.
  final String title;

  /// What this section shows or does.
  final String description;

  /// Key elements within this section that the agent may need to interact with.
  final List<AiElementManifest> elements;

  const AiSectionManifest({
    required this.title,
    required this.description,
    this.elements = const [],
  });
}
