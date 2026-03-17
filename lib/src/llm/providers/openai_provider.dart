import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../core/ai_logger.dart';
import '../../tools/tool_definition.dart';
import '../llm_provider.dart';

/// LLM provider implementation for OpenAI (GPT-4, GPT-4o, etc.).
///
/// Uses the OpenAI Chat Completions API with function calling.
/// Communicates via HTTP — no additional SDK dependency needed.
///
/// ```dart
/// final provider = OpenAiProvider(apiKey: 'sk-...');
/// ```
class OpenAiProvider implements LlmProvider {
  /// Your OpenAI API key.
  final String apiKey;

  /// The model to use. Defaults to `gpt-4o`.
  final String model;

  /// Base URL for the API. Override for Azure OpenAI or proxies.
  final String baseUrl;

  /// Sampling temperature. Lower = more deterministic. Default: 0.2.
  final double temperature;

  /// Maximum time to wait for a provider response before failing fast.
  final Duration requestTimeout;

  final http.Client _client;
  final bool _ownsClient;

  OpenAiProvider({
    required this.apiKey,
    this.model = 'gpt-4o',
    this.baseUrl = 'https://api.openai.com/v1',
    this.temperature = 0.2,
    this.requestTimeout = const Duration(seconds: 45),
    http.Client? httpClient,
  }) : _client = httpClient ?? http.Client(),
       _ownsClient = httpClient == null;

  /// Close the internal HTTP client. Only needed if no custom client was provided.
  @override
  void dispose() {
    if (_ownsClient) _client.close();
  }

  @override
  Future<LlmResponse> sendMessage({
    required List<LlmMessage> messages,
    required List<ToolDefinition> tools,
    String? systemPrompt,
  }) =>
      retryOnRateLimit(
        () => _sendMessageInner(messages, tools, systemPrompt),
        tag: 'OpenAI',
      );

  Future<LlmResponse> _sendMessageInner(
    List<LlmMessage> messages,
    List<ToolDefinition> tools,
    String? systemPrompt,
  ) async {
    final body = <String, dynamic>{
      'model': model,
      'messages': _buildMessages(messages, systemPrompt),
      'temperature': temperature,
    };

    if (tools.isNotEmpty) {
      body['tools'] = tools.map(_toOpenAiTool).toList();
      body['tool_choice'] = 'auto';
    }

    AiLogger.log(
      'OpenAI request: model=$model, ${messages.length} messages, '
      '${tools.isEmpty ? 'no tools' : '${tools.length} tools'}',
      tag: 'OpenAI',
    );
    final response = await _client
        .post(
          Uri.parse('$baseUrl/chat/completions'),
          headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer $apiKey',
          },
          body: jsonEncode(body),
        )
        .timeout(requestTimeout);

    if (response.statusCode != 200) {
      AiLogger.error(
        'OpenAI error ${response.statusCode}: ${response.body}',
        tag: 'OpenAI',
      );
      throwForHttpStatus(response.statusCode, response.body, 'OpenAI');
    }

    final json = jsonDecode(response.body) as Map<String, dynamic>;
    final parsed = _parseResponse(json);
    AiLogger.log(
      'OpenAI response: ${parsed.isToolCall ? '${parsed.toolCalls!.length} tool call(s)' : 'text (${parsed.textContent?.length ?? 0} chars)'}',
      tag: 'OpenAI',
    );
    return parsed;
  }

  /// Build OpenAI messages array.
  List<Map<String, dynamic>> _buildMessages(
    List<LlmMessage> messages,
    String? systemPrompt,
  ) {
    final result = <Map<String, dynamic>>[];

    if (systemPrompt != null) {
      result.add({'role': 'system', 'content': systemPrompt});
    }

    for (final msg in messages) {
      switch (msg.role) {
        case LlmRole.system:
          result.add({'role': 'system', 'content': msg.content ?? ''});

        case LlmRole.user:
          if (msg.images != null && msg.images!.isNotEmpty) {
            result.add({
              'role': 'user',
              'content': [
                {'type': 'text', 'text': msg.content ?? ''},
                for (final img in msg.images!)
                  {
                    'type': 'image_url',
                    'image_url': {
                      'url':
                          'data:${img.mimeType};base64,${base64Encode(img.bytes)}',
                      'detail': 'low',
                    },
                  },
              ],
            });
          } else {
            result.add({'role': 'user', 'content': msg.content ?? ''});
          }

        case LlmRole.assistant:
          if (msg.toolCalls != null && msg.toolCalls!.isNotEmpty) {
            result.add({
              'role': 'assistant',
              'tool_calls': msg.toolCalls!
                  .map(
                    (tc) => {
                      'id': tc.id,
                      'type': 'function',
                      'function': {
                        'name': tc.name,
                        'arguments': jsonEncode(tc.arguments),
                      },
                    },
                  )
                  .toList(),
            });
          } else {
            result.add({'role': 'assistant', 'content': msg.content ?? ''});
          }

        case LlmRole.tool:
          result.add({
            'role': 'tool',
            'tool_call_id': msg.toolCallId ?? '',
            'content': msg.content ?? '',
          });
      }
    }

    return result;
  }

  /// Convert a [ToolDefinition] to OpenAI's tool format.
  Map<String, dynamic> _toOpenAiTool(ToolDefinition tool) {
    return {
      'type': 'function',
      'function': {
        'name': tool.name,
        'description': tool.description,
        'parameters': _buildParametersSchema(tool),
      },
    };
  }

  /// Build JSON Schema for tool parameters.
  Map<String, dynamic> _buildParametersSchema(ToolDefinition tool) {
    if (tool.parameters.isEmpty) {
      return {'type': 'object', 'properties': {}};
    }

    final properties = <String, dynamic>{};
    for (final entry in tool.parameters.entries) {
      properties[entry.key] = _parameterToSchema(entry.value);
    }

    return {
      'type': 'object',
      'properties': properties,
      if (tool.required.isNotEmpty) 'required': tool.required,
    };
  }

  Map<String, dynamic> _parameterToSchema(ToolParameter param) {
    return {
      'type': param.type,
      'description': param.description,
      if (param.enumValues != null) 'enum': param.enumValues,
    };
  }

  /// Parse OpenAI response JSON.
  LlmResponse _parseResponse(Map<String, dynamic> json) {
    final choices = json['choices'] as List<dynamic>?;
    if (choices == null || choices.isEmpty) {
      return const LlmResponse(textContent: 'No response from OpenAI.');
    }

    final firstChoice = choices.first;
    if (firstChoice is! Map<String, dynamic>) {
      return const LlmResponse(textContent: 'No response from OpenAI.');
    }
    final message = firstChoice['message'] as Map<String, dynamic>?;
    if (message == null) {
      return const LlmResponse(textContent: 'No response from OpenAI.');
    }

    // Check for tool calls.
    final toolCallsJson = message['tool_calls'] as List<dynamic>?;
    if (toolCallsJson != null && toolCallsJson.isNotEmpty) {
      final parsedCalls = <ToolCall>[];
      for (int i = 0; i < toolCallsJson.length; i++) {
        final tc = toolCallsJson[i];
        if (tc is! Map<String, dynamic>) continue;
        final fn = tc['function'] as Map<String, dynamic>?;
        if (fn == null) continue;
        final toolName = fn['name']?.toString().trim();
        if (toolName == null || toolName.isEmpty) continue;

        final rawId = tc['id']?.toString();
        final toolId = (rawId != null && rawId.isNotEmpty)
            ? rawId
            : 'openai_$toolName#${i + 1}';
        parsedCalls.add(
          ToolCall(
            id: toolId,
            name: toolName,
            arguments: _parseToolArguments(fn['arguments'], toolName: toolName),
          ),
        );
      }
      if (parsedCalls.isNotEmpty) {
        return LlmResponse(toolCalls: parsedCalls);
      }

      return LlmResponse(textContent: message['content'] as String?);
    }

    // Text response.
    final content = message['content'] as String?;
    return LlmResponse(textContent: content);
  }

  Map<String, dynamic> _parseToolArguments(
    Object? rawArguments, {
    required String toolName,
  }) {
    if (rawArguments is Map<String, dynamic>) return rawArguments;
    if (rawArguments is Map) {
      return Map<String, dynamic>.from(rawArguments);
    }
    if (rawArguments is String) {
      if (rawArguments.trim().isEmpty) return const <String, dynamic>{};
      try {
        final decoded = jsonDecode(rawArguments);
        if (decoded is Map<String, dynamic>) return decoded;
        if (decoded is Map) return Map<String, dynamic>.from(decoded);
      } catch (_) {
        AiLogger.warn(
          'OpenAI returned invalid tool arguments for "$toolName"',
          tag: 'OpenAI',
        );
      }
    }
    return const <String, dynamic>{};
  }
}
