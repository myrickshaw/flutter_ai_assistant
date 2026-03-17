/// A multi-step user task that spans multiple screens.
///
/// Flows describe common user journeys (e.g., "Purchase a product") as a
/// sequence of steps across screens. This helps the agent plan and execute
/// complex tasks that require navigating between screens.
class AiFlowManifest {
  /// Flow name (e.g., "Purchase a product").
  final String name;

  /// One-line description.
  final String description;

  /// Ordered steps to complete this flow.
  final List<AiFlowStep> steps;

  const AiFlowManifest({
    required this.name,
    required this.description,
    required this.steps,
  });
}

/// A single step in a multi-screen flow.
class AiFlowStep {
  /// Which screen this step happens on (route name).
  final String route;

  /// What the agent needs to do on this screen.
  final String instruction;

  /// Expected outcome after this step completes.
  final String? expectedOutcome;

  const AiFlowStep({
    required this.route,
    required this.instruction,
    this.expectedOutcome,
  });
}
