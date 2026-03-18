import 'package:google_generative_ai/google_generative_ai.dart' as gemini;

import '../../core/ai_logger.dart';
import '../../tools/tool_definition.dart';
import '../llm_provider.dart';

/// LLM provider implementation for Google Gemini.
///
/// Uses the `google_generative_ai` package to communicate with
/// Gemini models. Supports function calling (tool use).
///
/// ```dart
/// final provider = GeminiProvider(apiKey: 'your-api-key');
/// ```
class GeminiProvider implements LlmProvider {
  /// Your Google AI API key.
  final String apiKey;

  /// The Gemini model to use. Defaults to `gemini-2.0-flash`.
  final String model;

  /// Sampling temperature. Lower = more deterministic. Default: 0.2.
  final double temperature;

  /// Maximum time to wait for a provider response before failing fast.
  final Duration requestTimeout;

  GeminiProvider({
    required this.apiKey,
    this.model = 'gemini-2.0-flash',
    this.temperature = 0.2,
    this.requestTimeout = const Duration(seconds: 45),
  });

  @override
  void dispose() {}

  @override
  Future<LlmResponse> sendMessage({
    required List<LlmMessage> messages,
    required List<ToolDefinition> tools,
    String? systemPrompt,
  }) => retryOnRateLimit(
    () => _sendMessageInner(messages, tools, systemPrompt),
    tag: 'Gemini',
  );

  Future<LlmResponse> _sendMessageInner(
    List<LlmMessage> messages,
    List<ToolDefinition> tools,
    String? systemPrompt,
  ) async {
    // Build Gemini tool declarations from our common format.
    final geminiTools = tools.isNotEmpty
        ? [
            gemini.Tool(
              functionDeclarations: tools.map(_toFunctionDeclaration).toList(),
            ),
          ]
        : <gemini.Tool>[];

    // Create model with tools and system instruction for this request.
    final configuredModel = gemini.GenerativeModel(
      model: model,
      apiKey: apiKey,
      tools: geminiTools,
      systemInstruction: systemPrompt != null
          ? gemini.Content.system(systemPrompt)
          : null,
      generationConfig: gemini.GenerationConfig(temperature: temperature),
    );

    // Convert our messages to Gemini Content format.
    final geminiContents = _convertMessages(messages);

    // Send to Gemini.
    AiLogger.log(
      'Gemini request: model=$model, ${geminiContents.length} content(s), '
      '${geminiTools.isEmpty ? 'no tools' : '${tools.length} tools'}',
      tag: 'Gemini',
    );
    final response = await configuredModel
        .generateContent(geminiContents)
        .timeout(requestTimeout);

    // Parse the response.
    final parsed = _parseResponse(response);
    AiLogger.log(
      'Gemini response: ${parsed.isToolCall ? '${parsed.toolCalls!.length} tool call(s)' : 'text (${parsed.textContent?.length ?? 0} chars)'}',
      tag: 'Gemini',
    );
    return parsed;
  }

  /// Convert a [ToolDefinition] to Gemini's [FunctionDeclaration].
  gemini.FunctionDeclaration _toFunctionDeclaration(ToolDefinition tool) {
    return gemini.FunctionDeclaration(
      tool.name,
      tool.description,
      _buildSchema(tool),
    );
  }

  /// Build a Gemini Schema from our tool parameters.
  gemini.Schema _buildSchema(ToolDefinition tool) {
    if (tool.parameters.isEmpty) {
      return gemini.Schema(gemini.SchemaType.object);
    }

    final properties = <String, gemini.Schema>{};
    for (final entry in tool.parameters.entries) {
      properties[entry.key] = _parameterToSchema(entry.value);
    }

    return gemini.Schema(
      gemini.SchemaType.object,
      properties: properties,
      requiredProperties: tool.required.isNotEmpty ? tool.required : null,
    );
  }

  /// Convert a [ToolParameter] to a Gemini [Schema].
  gemini.Schema _parameterToSchema(ToolParameter param) {
    final schemaType = switch (param.type) {
      'string' => gemini.SchemaType.string,
      'integer' => gemini.SchemaType.integer,
      'number' => gemini.SchemaType.number,
      'boolean' => gemini.SchemaType.boolean,
      'array' => gemini.SchemaType.array,
      _ => gemini.SchemaType.string,
    };

    return gemini.Schema(
      schemaType,
      description: param.description,
      enumValues: param.enumValues,
    );
  }

  /// Convert our [LlmMessage] list to Gemini [Content] list.
  ///
  /// Gemini uses a different conversation structure:
  /// - 'user' role for user messages
  /// - 'model' role for assistant messages
  /// - Function calls and results are inline as Parts
  List<gemini.Content> _convertMessages(List<LlmMessage> messages) {
    final contents = <gemini.Content>[];
    final toolCallNameById = <String, String>{};

    for (int i = 0; i < messages.length; i++) {
      final message = messages[i];
      switch (message.role) {
        case LlmRole.system:
          // System messages are handled via systemInstruction, skip here.
          break;

        case LlmRole.user:
          final userParts = <gemini.Part>[
            gemini.TextPart(message.content ?? ''),
          ];
          if (message.images != null) {
            for (final img in message.images!) {
              userParts.add(gemini.DataPart(img.mimeType, img.bytes));
            }
          }
          contents.add(gemini.Content('user', userParts));

        case LlmRole.assistant:
          if (message.toolCalls != null && message.toolCalls!.isNotEmpty) {
            for (final call in message.toolCalls!) {
              toolCallNameById[call.id] = call.name;
            }
            // Assistant made tool calls (may also include reasoning text).
            contents.add(
              gemini.Content('model', [
                if (message.content != null && message.content!.isNotEmpty)
                  gemini.TextPart(message.content!),
                for (final call in message.toolCalls!)
                  gemini.FunctionCall(call.name, call.arguments),
              ]),
            );
          } else {
            contents.add(
              gemini.Content('model', [gemini.TextPart(message.content ?? '')]),
            );
          }

        case LlmRole.tool:
          // Batch all consecutive tool results into a single Content.
          // Gemini requires function responses for a multi-call turn to be
          // grouped in one Content, not sent as separate messages.
          final responses = <gemini.FunctionResponse>[];
          while (i < messages.length && messages[i].role == LlmRole.tool) {
            final toolCallId = messages[i].toolCallId ?? '';
            final functionName = toolCallNameById[toolCallId] ?? toolCallId;
            responses.add(
              gemini.FunctionResponse(functionName, {
                'result': messages[i].content ?? '',
              }),
            );
            i++;
          }
          i--; // Adjust for the for-loop increment.
          contents.add(gemini.Content.functionResponses(responses));
      }
    }

    return contents;
  }

  /// Parse a Gemini [GenerateContentResponse] into our [LlmResponse].
  LlmResponse _parseResponse(gemini.GenerateContentResponse response) {
    final candidate = response.candidates.firstOrNull;
    if (candidate == null) {
      // Check prompt-level block reason (applies when ALL candidates are blocked).
      final blockReason = response.promptFeedback?.blockReason;
      if (blockReason != null) {
        AiLogger.warn('Gemini blocked request: $blockReason', tag: 'Gemini');
        throw ContentFilteredException(
          'Gemini: Request blocked by safety filter ($blockReason).',
        );
      }
      AiLogger.warn('Gemini returned no candidates', tag: 'Gemini');
      return const LlmResponse(); // Empty — triggers retry in agent loop.
    }

    // Check candidate-level finish reason for safety blocks.
    final finishReason = candidate.finishReason;
    if (finishReason == gemini.FinishReason.safety) {
      AiLogger.warn('Gemini response blocked by safety filter', tag: 'Gemini');
      throw ContentFilteredException(
        'Gemini: Response blocked by safety filter.',
      );
    }
    if (finishReason == gemini.FinishReason.maxTokens) {
      AiLogger.warn('Gemini response truncated (max tokens)', tag: 'Gemini');
      // Don't throw — partial response is still useful. Fall through to parse.
    }

    final parts = candidate.content.parts;

    // Check for function calls.
    final functionCalls = parts.whereType<gemini.FunctionCall>().toList();
    if (functionCalls.isNotEmpty) {
      // Also capture any text parts (LLM's reasoning/thought alongside tool calls).
      // This text is used as user-facing progressive status in the action feed.
      final textParts = parts.whereType<gemini.TextPart>();
      final thought = textParts.map((p) => p.text).join().trim();
      return LlmResponse(
        textContent: thought.isNotEmpty ? thought : null,
        toolCalls: functionCalls.asMap().entries.map((entry) {
          final index = entry.key;
          final fc = entry.value;
          return ToolCall(
            id: '${fc.name}#${index + 1}',
            name: fc.name,
            arguments: fc.args,
          );
        }).toList(),
      );
    }

    // Otherwise, collect text parts.
    final textParts = parts.whereType<gemini.TextPart>();
    final text = textParts.map((p) => p.text).join();

    return LlmResponse(textContent: text.isNotEmpty ? text : null);
  }
}
