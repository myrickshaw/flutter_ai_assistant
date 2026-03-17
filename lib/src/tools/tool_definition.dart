/// A parameter definition for a tool.
class ToolParameter {
  /// JSON Schema type: "string", "integer", "number", "boolean", "object", "array".
  final String type;

  /// Human-readable description of what this parameter does.
  final String description;

  /// If set, restricts the value to one of these options.
  final List<String>? enumValues;

  const ToolParameter({
    required this.type,
    required this.description,
    this.enumValues,
  });

  /// Convert to JSON Schema representation.
  Map<String, dynamic> toJsonSchema() {
    final schema = <String, dynamic>{
      'type': type,
      'description': description,
    };
    if (enumValues != null) {
      schema['enum'] = enumValues;
    }
    return schema;
  }
}

/// Definition of a tool that the LLM can call.
class ToolDefinition {
  /// Unique name for this tool (e.g., "tap_element", "navigate_to_route").
  final String name;

  /// Human-readable description the LLM uses to decide when to call this tool.
  final String description;

  /// Parameter definitions keyed by parameter name.
  final Map<String, ToolParameter> parameters;

  /// Which parameters are required.
  final List<String> required;

  const ToolDefinition({
    required this.name,
    required this.description,
    this.parameters = const {},
    this.required = const [],
  });

  /// Convert to JSON Schema format used by LLM function calling APIs.
  Map<String, dynamic> toFunctionSchema() {
    return {
      'name': name,
      'description': description,
      'parameters': {
        'type': 'object',
        'properties': parameters.map((key, param) => MapEntry(key, param.toJsonSchema())),
        'required': required,
      },
    };
  }
}

/// A developer-facing tool that can be registered with the AI assistant.
/// Combines a [ToolDefinition] with an executable handler function.
class AiTool {
  final String name;
  final String description;
  final Map<String, ToolParameter> parameters;
  final List<String> required;
  final Future<Map<String, dynamic>> Function(Map<String, dynamic> args) handler;

  const AiTool({
    required this.name,
    required this.description,
    this.parameters = const {},
    this.required = const [],
    required this.handler,
  });

  /// Convert to a [ToolDefinition] (without the handler).
  ToolDefinition toDefinition() {
    return ToolDefinition(
      name: name,
      description: description,
      parameters: parameters,
      required: required,
    );
  }
}
