/// An entry in the app's global navigation (bottom nav bar, side menu, etc.).
///
/// Describes the persistent navigation structure so the agent knows the
/// primary screens accessible from any point in the app.
class AiNavEntry {
  /// Label shown in the nav bar/menu (e.g., "Home", "Wallet").
  final String label;

  /// Route it navigates to (e.g., "/home").
  final String route;

  /// Optional description of the icon for additional context.
  final String? iconDescription;

  const AiNavEntry({
    required this.label,
    required this.route,
    this.iconDescription,
  });
}
