import 'package:uuid/uuid.dart';

const _uuid = Uuid();

/// Status of a single step in the agent's action feed.
enum ActionStepStatus { pending, inProgress, completed, failed }

/// A single step shown in the real-time action feed overlay.
///
/// Each tool call in the ReAct loop becomes one [ActionStep]. The controller
/// streams these to the UI as they happen, so the user sees live progress.
class ActionStep {
  final String id;

  /// User-friendly description, e.g. "Navigating to booking screen".
  final String description;

  final String toolName;
  final Map<String, dynamic> arguments;
  final ActionStepStatus status;
  final String? error;
  final DateTime startedAt;
  final DateTime? completedAt;

  const ActionStep({
    required this.id,
    required this.description,
    required this.toolName,
    required this.arguments,
    required this.status,
    this.error,
    required this.startedAt,
    this.completedAt,
  });

  /// Create a new in-progress step for a tool call.
  factory ActionStep.started({
    required String toolName,
    required Map<String, dynamic> arguments,
  }) {
    return ActionStep(
      id: _uuid.v4(),
      description: descriptionForTool(toolName, arguments),
      toolName: toolName,
      arguments: arguments,
      status: ActionStepStatus.inProgress,
      startedAt: DateTime.now(),
    );
  }

  ActionStep copyWith({
    ActionStepStatus? status,
    String? error,
    DateTime? completedAt,
  }) {
    return ActionStep(
      id: id,
      description: description,
      toolName: toolName,
      arguments: arguments,
      status: status ?? this.status,
      error: error ?? this.error,
      startedAt: startedAt,
      completedAt: completedAt ?? this.completedAt,
    );
  }

  /// Generate a user-friendly present-tense description for a tool call.
  static String descriptionForTool(String toolName, Map<String, dynamic> args) {
    return switch (toolName) {
      'tap_element' => 'Tapping "${args['label'] ?? 'element'}"',
      'set_text' =>
        'Entering "${args['text'] ?? '...'}" in "${args['label'] ?? 'field'}"',
      'scroll' => 'Scrolling ${args['direction'] ?? 'down'}',
      'navigate_to_route' => 'Navigating to ${args['routeName'] ?? 'screen'}',
      'go_back' => 'Going back',
      'get_screen_content' => 'Reading screen content',
      'long_press_element' => 'Long pressing "${args['label'] ?? 'element'}"',
      'increase_value' => 'Increasing "${args['label'] ?? 'value'}"',
      'decrease_value' => 'Decreasing "${args['label'] ?? 'value'}"',
      _ => 'Running $toolName',
    };
  }
}
