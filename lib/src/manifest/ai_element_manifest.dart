/// A notable UI element the agent should know about.
///
/// Only include elements that are important for task completion — not every
/// widget on screen, just the ones the agent would need to interact with.
class AiElementManifest {
  /// The label text (what the semantics tree will call it).
  final String label;

  /// Element type hint (e.g., "button", "textField", "toggle", "list", "card").
  final String type;

  /// What this element does when interacted with.
  final String? behaviorDescription;

  const AiElementManifest({
    required this.label,
    required this.type,
    this.behaviorDescription,
  });
}
