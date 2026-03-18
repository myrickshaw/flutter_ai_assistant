import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../core/ai_logger.dart';
import '../../tools/tool_definition.dart';
import '../llm_provider.dart';

/// LLM provider implementation for Anthropic Claude.
///
/// Uses the Anthropic Messages API with tool use.
/// Communicates via HTTP — no additional SDK dependency needed.
///
/// ```dart
/// final provider = ClaudeProvider(apiKey: 'sk-ant-...');
/// ```
class ClaudeProvider implements LlmProvider {
  /// Your Anthropic API key.
  final String apiKey;

  /// The model to use. Defaults to `claude-sonnet-4-20250514`.
  final String model;

  /// Maximum tokens in the response.
  final int maxTokens;

  /// Base URL for the API.
  final String baseUrl;

  /// Sampling temperature. Lower = more deterministic. Default: 0.2.
  final double temperature;

  /// Maximum time to wait for a provider response before failing fast.
  final Duration requestTimeout;

  final http.Client _client;
  final bool _ownsClient;

  ClaudeProvider({
    required this.apiKey,
    this.model = 'claude-sonnet-4-20250514',
    this.maxTokens = 4096,
    this.baseUrl = 'https://api.anthropic.com/v1',
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
  }) => retryOnRateLimit(
    () => _sendMessageInner(messages, tools, systemPrompt),
    tag: 'Claude',
  );

  Future<LlmResponse> _sendMessageInner(
    List<LlmMessage> messages,
    List<ToolDefinition> tools,
    String? systemPrompt,
  ) async {
    final body = <String, dynamic>{
      'model': model,
      'max_tokens': maxTokens,
      'messages': _buildMessages(messages),
      'temperature': temperature,
    };

    if (systemPrompt != null) {
      body['system'] = systemPrompt;
    }

    if (tools.isNotEmpty) {
      body['tools'] = tools.map(_toClaudeTool).toList();
    }

    AiLogger.log(
      'Claude request: model=$model, ${messages.length} messages, '
      '${tools.isEmpty ? 'no tools' : '${tools.length} tools'}',
      tag: 'Claude',
    );
    final response = await _client
        .post(
          Uri.parse('$baseUrl/messages'),
          headers: {
            'Content-Type': 'application/json',
            'x-api-key': apiKey,
            'anthropic-version': '2023-06-01',
          },
          body: jsonEncode(body),
        )
        .timeout(requestTimeout);

    if (response.statusCode != 200) {
      AiLogger.error(
        'Claude error ${response.statusCode}: ${response.body}',
        tag: 'Claude',
      );
      throwForHttpStatus(response.statusCode, response.body, 'Claude');
    }

    final json = jsonDecode(response.body) as Map<String, dynamic>;
    final parsed = _parseResponse(json);
    AiLogger.log(
      'Claude response: ${parsed.isToolCall ? '${parsed.toolCalls!.length} tool call(s)' : 'text (${parsed.textContent?.length ?? 0} chars)'}',
      tag: 'Claude',
    );
    return parsed;
  }

  /// Build Claude messages array.
  List<Map<String, dynamic>> _buildMessages(List<LlmMessage> messages) {
    final result = <Map<String, dynamic>>[];

    for (final msg in messages) {
      switch (msg.role) {
        case LlmRole.system:
          // System messages are handled via the top-level 'system' field.
          break;

        case LlmRole.user:
          if (msg.images != null && msg.images!.isNotEmpty) {
            result.add({
              'role': 'user',
              'content': [
                {'type': 'text', 'text': msg.content ?? ''},
                for (final img in msg.images!)
                  {
                    'type': 'image',
                    'source': {
                      'type': 'base64',
                      'media_type': img.mimeType,
                      'data': base64Encode(img.bytes),
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
              'content': msg.toolCalls!
                  .map(
                    (tc) => {
                      'type': 'tool_use',
                      'id': tc.id,
                      'name': tc.name,
                      'input': tc.arguments,
                    },
                  )
                  .toList(),
            });
          } else {
            result.add({'role': 'assistant', 'content': msg.content ?? ''});
          }

        case LlmRole.tool:
          result.add({
            'role': 'user',
            'content': [
              {
                'type': 'tool_result',
                'tool_use_id': msg.toolCallId ?? '',
                'content': msg.content ?? '',
              },
            ],
          });
      }
    }

    return result;
  }

  /// Convert a [ToolDefinition] to Claude's tool format.
  Map<String, dynamic> _toClaudeTool(ToolDefinition tool) {
    return {
      'name': tool.name,
      'description': tool.description,
      'input_schema': _buildInputSchema(tool),
    };
  }

  /// Build JSON Schema for tool input.
  Map<String, dynamic> _buildInputSchema(ToolDefinition tool) {
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

  /// Parse Claude response JSON.
  LlmResponse _parseResponse(Map<String, dynamic> json) {
    final content = json['content'] as List<dynamic>?;
    if (content == null || content.isEmpty) {
      return const LlmResponse(textContent: 'No response from Claude.');
    }

    final toolCalls = <ToolCall>[];
    int toolIndex = 0;
    for (final block in content) {
      if (block is! Map<String, dynamic>) continue;
      if (block['type'] != 'tool_use') continue;

      toolIndex++;
      final toolName = block['name']?.toString().trim();
      if (toolName == null || toolName.isEmpty) continue;

      final rawId = block['id']?.toString();
      final toolId = (rawId != null && rawId.isNotEmpty)
          ? rawId
          : 'claude_$toolName#$toolIndex';
      final rawInput = block['input'];
      final args = rawInput is Map
          ? Map<String, dynamic>.from(rawInput)
          : const <String, dynamic>{};
      if (rawInput != null && rawInput is! Map) {
        AiLogger.warn(
          'Claude returned invalid tool input for "$toolName"',
          tag: 'Claude',
        );
      }
      toolCalls.add(ToolCall(id: toolId, name: toolName, arguments: args));
    }

    if (toolCalls.isNotEmpty) {
      return LlmResponse(toolCalls: toolCalls);
    }

    // Collect text blocks.
    final textBlocks = content
        .whereType<Map<String, dynamic>>()
        .where((block) => block['type'] == 'text')
        .map((block) => block['text']?.toString() ?? '')
        .join();

    return LlmResponse(textContent: textBlocks.isNotEmpty ? textBlocks : null);
  }
}
