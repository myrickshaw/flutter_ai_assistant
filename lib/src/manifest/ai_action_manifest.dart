/// A meaningful action available on a screen.
///
/// Actions describe what the user can accomplish on a screen, along with
/// how to perform them. This helps the agent plan tasks without needing
/// to explore the screen first.
class AiActionManifest {
  /// Short name (e.g., "Buy Coins", "Apply Coupon").
  final String name;

  /// How to perform this action (which elements to interact with).
  final String howTo;

  /// Whether this action is destructive (purchase, deletion, send).
  /// Destructive actions require user confirmation before execution.
  final bool isDestructive;

  const AiActionManifest({
    required this.name,
    required this.howTo,
    this.isDestructive = false,
  });
}
