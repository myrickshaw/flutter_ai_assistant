import '../core/ai_logger.dart';
import '../llm/llm_provider.dart';
import 'tool_definition.dart';
import 'tool_result.dart';

/// Registry of all available tools (built-in + developer-registered).
///
/// The registry is the single source of truth for what tools the LLM
/// can call. It holds both the tool definitions (sent to the LLM) and
/// the executable handlers (called when the LLM invokes a tool).
class ToolRegistry {
  final Map<String, AiTool> _tools = {};

  /// Register a tool. Replaces any existing tool with the same name.
  void register(AiTool tool) {
    AiLogger.log('Registered tool: ${tool.name}', tag: 'Tools');
    _tools[tool.name] = tool;
  }

  /// Register multiple tools at once.
  void registerAll(Iterable<AiTool> tools) {
    for (final tool in tools) {
      _tools[tool.name] = tool;
    }
  }

  /// Unregister a tool by name.
  void unregister(String name) {
    _tools.remove(name);
  }

  /// Whether a tool with the given name is registered.
  bool has(String name) => _tools.containsKey(name);

  /// Get all tool definitions (for sending to the LLM).
  List<ToolDefinition> getToolDefinitions() {
    return _tools.values.map((t) => t.toDefinition()).toList();
  }

  /// Execute a tool call returned by the LLM.
  ///
  /// Looks up the tool by name and calls its handler with the provided arguments.
  /// Returns a [ToolResult] with success/failure and data.
  Future<ToolResult> executeTool(ToolCall call) async {
    final tool = _tools[call.name];
    if (tool == null) {
      return ToolResult.fail('Unknown tool: ${call.name}');
    }

    try {
      final data = await tool.handler(call.arguments);
      AiLogger.log('Tool "${call.name}" succeeded', tag: 'Tools');
      return ToolResult.ok(data);
    } catch (e) {
      AiLogger.error('Tool "${call.name}" failed: $e', tag: 'Tools');
      return ToolResult.fail('Tool "${call.name}" failed: $e');
    }
  }

  /// Clear all registered tools.
  void clear() {
    _tools.clear();
  }

  /// Number of registered tools.
  int get length => _tools.length;

  /// Names of all registered tools.
  Iterable<String> get toolNames => _tools.keys;
}
