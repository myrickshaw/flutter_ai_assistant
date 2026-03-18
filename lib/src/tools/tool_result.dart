/// Result of executing a tool/action.
class ToolResult {
  /// Whether the tool execution succeeded.
  final bool success;

  /// Data returned by the tool (varies per tool).
  final Map<String, dynamic> data;

  /// Error message if the tool failed.
  final String? error;

  const ToolResult({required this.success, this.data = const {}, this.error});

  factory ToolResult.ok([Map<String, dynamic> data = const {}]) {
    return ToolResult(success: true, data: data);
  }

  factory ToolResult.fail(String error) {
    return ToolResult(success: false, error: error);
  }

  /// Format for LLM consumption as a tool result message.
  String toPromptString() {
    if (success) {
      if (data.isEmpty) return 'Success.';
      return 'Success: ${data.entries.map((e) => '${e.key}=${e.value}').join(', ')}';
    }
    return 'Error: ${error ?? "Unknown error"}';
  }

  @override
  String toString() =>
      success ? 'ToolResult.ok($data)' : 'ToolResult.fail($error)';
}
