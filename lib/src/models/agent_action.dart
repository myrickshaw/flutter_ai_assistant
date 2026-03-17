import '../tools/tool_result.dart';

/// Record of a single action executed by the AI agent.
class AgentAction {
  /// The tool name that was called (e.g., "tap_element", "navigate_to_route").
  final String toolName;

  /// The arguments passed to the tool.
  final Map<String, dynamic> arguments;

  /// The result returned by the tool execution.
  final ToolResult result;

  /// When this action was executed.
  final DateTime executedAt;

  const AgentAction({
    required this.toolName,
    required this.arguments,
    required this.result,
    required this.executedAt,
  });

  /// Human-readable summary for display in chat bubbles.
  String toDisplayString() {
    return switch (toolName) {
      'tap_element' => 'Tapped "${arguments['label']}"',
      'set_text' => 'Entered "${arguments['text']}" in "${arguments['label']}"',
      'scroll' => 'Scrolled ${arguments['direction']}',
      'navigate_to_route' => 'Navigated to ${arguments['routeName']}',
      'go_back' => 'Went back',
      'get_screen_content' => 'Refreshed screen view',
      'long_press_element' => 'Long pressed "${arguments['label']}"',
      'increase_value' => 'Increased "${arguments['label']}"',
      'decrease_value' => 'Decreased "${arguments['label']}"',
      _ => 'Executed $toolName',
    };
  }
}
