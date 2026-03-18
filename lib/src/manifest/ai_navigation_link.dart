/// Describes a navigation link from one screen to another.
///
/// This forms an edge in the screen graph, telling the agent how to
/// get from screen A to screen B.
class AiNavigationLink {
  /// The target route (e.g., "/buyCoins").
  final String targetRoute;

  /// How to trigger this navigation (e.g., "Tap 'Buy Coins' button").
  final String trigger;

  const AiNavigationLink({required this.targetRoute, required this.trigger});
}
