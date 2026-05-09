import 'dart:async';
import 'dart:convert';

import 'package:firebase_ai/firebase_ai.dart' as fai;

import '../../core/ai_logger.dart';
import '../../tools/tool_definition.dart';
import '../llm_provider.dart';
import '../llm_stream_event.dart';

/// LLM provider backed by Firebase AI Logic (`package:firebase_ai`).
///
/// This is the recommended way to call Gemini from a Flutter app. The
/// Gemini API key never ships in the binary — calls are proxied through
/// Firebase, which can additionally verify a Firebase App Check token
/// before forwarding the request.
///
/// ```dart
/// // Recommended: with App Check
/// final provider = FirebaseAiProvider(
///   firebaseAi: FirebaseAI.googleAI(
///     appCheck: FirebaseAppCheck.instance,
///     useLimitedUseAppCheckTokens: true,
///   ),
///   model: 'gemini-2.5-flash',
/// );
///
/// // Acceptable: Firebase without App Check (still keeps the API key
/// // off the device, but no per-request platform attestation).
/// final provider = FirebaseAiProvider(
///   firebaseAi: FirebaseAI.googleAI(),
/// );
/// ```
///
/// **Platform support:** `firebase_ai` supports Android, iOS, macOS, and
/// Web. Linux and Windows desktop builds are not supported by the
/// upstream plugin — use [ClaudeProvider] or [OpenAiProvider] (HTTP-based)
/// on those platforms.
///
/// Replaces the deprecated `GeminiProvider`. Keeps the same [LlmProvider]
/// contract used by the ReAct agent. Adds:
///
/// - [streamMessage] — incremental streaming for custom chat UIs.
/// - [generateStructured] — one-shot JSON output against a [fai.Schema].
class FirebaseAiProvider implements LlmProvider {
  /// The configured Firebase AI Logic entry point. Build it with
  /// `FirebaseAI.googleAI(...)` (Gemini Developer API, free tier) or
  /// `FirebaseAI.vertexAI(location: '...')` (Vertex AI, Blaze plan).
  final fai.FirebaseAI firebaseAi;

  /// The Gemini model to use. Defaults to `gemini-2.5-flash`.
  final String model;

  /// Sampling temperature. Lower = more deterministic. Default: 0.2.
  final double temperature;

  /// Maximum number of tokens to generate. `null` means provider default.
  final int? maxOutputTokens;

  /// Nucleus sampling (top-p). `null` means provider default.
  final double? topP;

  /// Top-K sampling. `null` means provider default.
  final int? topK;

  /// Sequences that, if generated, will stop output. `null` means none.
  final List<String>? stopSequences;

  /// Optional thinking budget for Gemini 2.5+ models. Wraps
  /// [fai.ThinkingConfig.withThinkingBudget].
  final fai.ThinkingConfig? thinkingConfig;

  /// Optional safety overrides.
  final List<fai.SafetySetting>? safetySettings;

  /// Optional tool-calling configuration. Use
  /// `ToolConfig(functionCallingConfig: FunctionCallingConfig.any({...}))`
  /// to force the model to call one of a specific set of tools, or
  /// `FunctionCallingConfig.none()` to disable tool calls.
  final fai.ToolConfig? toolConfig;

  /// Maximum time to wait for a non-streaming response, and the
  /// inter-event idle timeout for streaming responses.
  final Duration requestTimeout;

  FirebaseAiProvider({
    required this.firebaseAi,
    this.model = 'gemini-2.5-flash',
    this.temperature = 0.2,
    this.maxOutputTokens,
    this.topP,
    this.topK,
    this.stopSequences,
    this.thinkingConfig,
    this.safetySettings,
    this.toolConfig,
    this.requestTimeout = const Duration(seconds: 45),
  });

  @override
  void dispose() {
    // The `firebaseAi` instance is owned by the caller; nothing to release.
  }

  // ---------------------------------------------------------------------------
  // sendMessage — primary entry point used by the ReAct agent.
  // ---------------------------------------------------------------------------

  @override
  Future<LlmResponse> sendMessage({
    required List<LlmMessage> messages,
    required List<ToolDefinition> tools,
    String? systemPrompt,
  }) => retryOnRateLimit(
    () => _sendMessageInner(messages, tools, systemPrompt),
    tag: 'FirebaseAI',
  );

  Future<LlmResponse> _sendMessageInner(
    List<LlmMessage> messages,
    List<ToolDefinition> tools,
    String? systemPrompt,
  ) async {
    final faiTools = _buildTools(tools);
    final configuredModel = _buildModel(
      tools: faiTools,
      systemPrompt: systemPrompt,
    );

    final faiContents = _convertMessages(messages);

    AiLogger.log(
      'FirebaseAI request: model=$model, ${faiContents.length} content(s), '
      '${faiTools.isEmpty ? 'no tools' : '${tools.length} tools'}',
      tag: 'FirebaseAI',
    );

    try {
      final response = await configuredModel
          .generateContent(faiContents)
          .timeout(requestTimeout);

      final cached = response.usageMetadata?.cachedContentTokenCount;
      if (cached != null && cached > 0) {
        AiLogger.log(
          'FirebaseAI cached $cached prompt tokens (implicit cache)',
          tag: 'FirebaseAI',
        );
      }

      final parsed = _parseResponse(response);
      AiLogger.log(
        'FirebaseAI response: ${parsed.isToolCall ? '${parsed.toolCalls!.length} tool call(s)' : 'text (${parsed.textContent?.length ?? 0} chars)'}',
        tag: 'FirebaseAI',
      );
      return parsed;
    } on fai.FirebaseAIException catch (e) {
      throw _mapException(e);
    } on fai.FirebaseAISdkException catch (e) {
      AiLogger.warn(
        'FirebaseAI SDK exception (likely stale package version): ${e.message}',
        tag: 'FirebaseAI',
      );
      rethrow;
    }
  }

  // ---------------------------------------------------------------------------
  // streamMessage — provider-only streaming for custom UIs (not used by the
  // ReAct agent today; the agent loop still uses sendMessage).
  // ---------------------------------------------------------------------------

  /// Stream the model's response as it is produced. Yields
  /// [LlmStreamText] for each text delta, [LlmStreamToolCall] for any
  /// tool calls, and a final [LlmStreamDone] with usage metadata on
  /// successful completion. On error the stream terminates with the
  /// error and [LlmStreamDone] is **not** emitted.
  ///
  /// [requestTimeout] is applied as an inter-event idle timeout — if no
  /// chunk arrives for that long, the stream throws [TimeoutException].
  Stream<LlmStreamEvent> streamMessage({
    required List<LlmMessage> messages,
    required List<ToolDefinition> tools,
    String? systemPrompt,
  }) async* {
    final faiTools = _buildTools(tools);
    final configuredModel = _buildModel(
      tools: faiTools,
      systemPrompt: systemPrompt,
    );

    final faiContents = _convertMessages(messages);

    AiLogger.log(
      'FirebaseAI stream request: model=$model, ${faiContents.length} content(s)',
      tag: 'FirebaseAI',
    );

    var toolCallOrdinal = 0;
    final emittedToolCallIds = <String>{};
    int? cached;
    int? prompt;
    int? candidate;

    try {
      final stream = configuredModel
          .generateContentStream(faiContents)
          .timeout(requestTimeout);
      await for (final chunk in stream) {
        final candidateContent = chunk.candidates.firstOrNull?.content;
        if (candidateContent != null) {
          for (final part in candidateContent.parts) {
            if (part is fai.TextPart) {
              if (part.text.isNotEmpty) yield LlmStreamText(part.text);
            } else if (part is fai.FunctionCall) {
              toolCallOrdinal++;
              final id = part.id ?? '${part.name}#$toolCallOrdinal';
              if (emittedToolCallIds.add(id)) {
                yield LlmStreamToolCall(
                  ToolCall(
                    id: id,
                    name: part.name,
                    arguments: part.args.cast<String, dynamic>(),
                  ),
                );
              }
            }
          }
        }
        final usage = chunk.usageMetadata;
        if (usage != null) {
          cached = usage.cachedContentTokenCount ?? cached;
          prompt = usage.promptTokenCount ?? prompt;
          candidate = usage.candidatesTokenCount ?? candidate;
        }
      }
    } on fai.FirebaseAIException catch (e) {
      throw _mapException(e);
    }

    yield LlmStreamDone(
      cachedTokenCount: cached,
      promptTokenCount: prompt,
      candidatesTokenCount: candidate,
    );
  }

  // ---------------------------------------------------------------------------
  // generateStructured — one-shot call with JSON schema enforcement.
  // ---------------------------------------------------------------------------

  /// Issue a one-shot prompt and return the model's JSON response parsed
  /// against [schema]. Throws:
  ///
  /// - [ContentFilteredException] if the prompt or response is blocked.
  /// - [FormatException] if the response is empty, truncated by
  ///   `maxOutputTokens`, or not valid JSON.
  /// - [AuthenticationException] / [RateLimitException] /
  ///   [ContextOverflowException] mapped from `firebase_ai` exceptions.
  Future<Object?> generateStructured({
    required String prompt,
    required fai.Schema schema,
    String? systemPrompt,
  }) async {
    final configuredModel = _buildModel(
      tools: const [],
      systemPrompt: systemPrompt,
      responseSchema: schema,
    );
    try {
      final response = await configuredModel
          .generateContent([fai.Content.text(prompt)])
          .timeout(requestTimeout);

      final candidate = response.candidates.firstOrNull;
      if (candidate == null) {
        final blockReason = response.promptFeedback?.blockReason;
        if (blockReason != null) {
          throw ContentFilteredException(
            'FirebaseAI: structured request blocked by safety filter ($blockReason).',
          );
        }
        throw const FormatException(
          'FirebaseAI: empty response — no candidates returned.',
        );
      }
      final finishReason = candidate.finishReason;
      if (_isContentFiltered(finishReason)) {
        throw ContentFilteredException(
          'FirebaseAI: structured response blocked by safety filter ($finishReason).',
        );
      }
      final text = candidate.content.parts
          .whereType<fai.TextPart>()
          .map((p) => p.text)
          .join();
      if (text.isEmpty) {
        if (finishReason == fai.FinishReason.maxTokens) {
          throw const FormatException(
            'FirebaseAI: structured response truncated by maxOutputTokens — '
            'increase the limit or simplify the schema.',
          );
        }
        throw FormatException(
          'FirebaseAI: empty structured response (finishReason=$finishReason).',
        );
      }
      return jsonDecode(text);
    } on fai.FirebaseAIException catch (e) {
      throw _mapException(e);
    }
  }

  // ---------------------------------------------------------------------------
  // Internals
  // ---------------------------------------------------------------------------

  /// Builds a fresh [fai.GenerativeModel] for each request.
  ///
  /// `firebase_ai`'s `GenerativeModel` is a thin stateless wrapper, so
  /// per-request construction is cheap. Subclasses with stable
  /// (tools, systemPrompt, schema) signatures can override this method
  /// to cache the instance if they measure overhead.
  fai.GenerativeModel _buildModel({
    required List<fai.Tool> tools,
    String? systemPrompt,
    fai.Schema? responseSchema,
  }) {
    return firebaseAi.generativeModel(
      model: model,
      tools: tools.isEmpty ? null : tools,
      toolConfig: toolConfig,
      systemInstruction: systemPrompt == null
          ? null
          : fai.Content.system(systemPrompt),
      safetySettings: safetySettings,
      generationConfig: fai.GenerationConfig(
        temperature: temperature,
        maxOutputTokens: maxOutputTokens,
        topP: topP,
        topK: topK,
        stopSequences: stopSequences,
        thinkingConfig: thinkingConfig,
        responseMimeType: responseSchema == null ? null : 'application/json',
        responseSchema: responseSchema,
      ),
    );
  }

  List<fai.Tool> _buildTools(List<ToolDefinition> tools) {
    if (tools.isEmpty) return const [];
    return [
      fai.Tool.functionDeclarations(tools.map(_toFunctionDeclaration).toList()),
    ];
  }

  /// Convert a [ToolDefinition] to firebase_ai's [fai.FunctionDeclaration].
  fai.FunctionDeclaration _toFunctionDeclaration(ToolDefinition tool) {
    final properties = <String, fai.Schema>{
      for (final entry in tool.parameters.entries)
        entry.key: _parameterToSchema(entry.value),
    };
    final optional = tool.parameters.keys
        .where((k) => !tool.required.contains(k))
        .toList(growable: false);
    return fai.FunctionDeclaration(
      tool.name,
      tool.description,
      parameters: properties,
      optionalParameters: optional,
    );
  }

  /// Convert a [ToolParameter] to a firebase_ai [fai.Schema].
  ///
  /// Notes / known limitations:
  /// - `enumValues` is honoured only when [ToolParameter.type] is
  ///   `'string'`. Enums on integer/number/boolean parameters fall
  ///   through to the typed schema (matching how the deprecated
  ///   GeminiProvider behaved on the wire when paired with newer
  ///   server validation).
  /// - `'array'` parameters use `string` items by default since
  ///   [ToolParameter] does not currently expose an item type.
  /// - `'object'` parameters become an empty-properties object schema;
  ///   server validation may reject this for some tool definitions.
  fai.Schema _parameterToSchema(ToolParameter param) {
    final hasEnum = param.enumValues != null && param.enumValues!.isNotEmpty;
    if (hasEnum && param.type == 'string') {
      return fai.Schema.enumString(
        enumValues: param.enumValues!,
        description: param.description,
      );
    }
    switch (param.type) {
      case 'string':
        return fai.Schema.string(description: param.description);
      case 'integer':
        return fai.Schema.integer(description: param.description);
      case 'number':
        return fai.Schema.number(description: param.description);
      case 'boolean':
        return fai.Schema.boolean(description: param.description);
      case 'array':
        return fai.Schema.array(
          items: fai.Schema.string(),
          description: param.description,
        );
      case 'object':
        return fai.Schema.object(
          properties: const {},
          description: param.description,
        );
      default:
        return fai.Schema.string(description: param.description);
    }
  }

  /// Convert our [LlmMessage] list to firebase_ai's [fai.Content] list.
  ///
  /// Roles map to: `'user'` for user messages, `'model'` for assistant
  /// messages, and a single grouped function-response Content for any
  /// run of consecutive tool-result messages (firebase_ai requires
  /// multiple tool results from a single turn to be grouped together).
  ///
  /// `FunctionCall.id` and `FunctionResponse.id` are wired to the
  /// [ToolCall.id] / [LlmMessage.toolCallId] so the model can correlate
  /// parallel tool calls reliably.
  List<fai.Content> _convertMessages(List<LlmMessage> messages) {
    final contents = <fai.Content>[];
    final toolCallNameById = <String, String>{};

    for (var i = 0; i < messages.length; i++) {
      final message = messages[i];
      switch (message.role) {
        case LlmRole.system:
          // Handled via systemInstruction on the model — skip here.
          break;

        case LlmRole.user:
          final parts = <fai.Part>[fai.TextPart(message.content ?? '')];
          if (message.images != null) {
            for (final img in message.images!) {
              parts.add(fai.InlineDataPart(img.mimeType, img.bytes));
            }
          }
          contents.add(fai.Content('user', parts));

        case LlmRole.assistant:
          if (message.toolCalls != null && message.toolCalls!.isNotEmpty) {
            for (final call in message.toolCalls!) {
              toolCallNameById[call.id] = call.name;
            }
            contents.add(
              fai.Content('model', [
                if (message.content != null && message.content!.isNotEmpty)
                  fai.TextPart(message.content!),
                for (final call in message.toolCalls!)
                  fai.FunctionCall(call.name, call.arguments, id: call.id),
              ]),
            );
          } else {
            contents.add(
              fai.Content('model', [fai.TextPart(message.content ?? '')]),
            );
          }

        case LlmRole.tool:
          // Group consecutive tool results into a single Content.
          // firebase_ai requires multi-call tool responses to be grouped.
          final responses = <fai.FunctionResponse>[];
          while (i < messages.length && messages[i].role == LlmRole.tool) {
            final toolCallId = messages[i].toolCallId ?? '';
            final functionName = toolCallNameById[toolCallId] ?? toolCallId;
            responses.add(
              fai.FunctionResponse(
                functionName,
                _toolResultPayload(messages[i].content ?? ''),
                id: toolCallId.isEmpty ? null : toolCallId,
              ),
            );
            i++;
          }
          // The inner while loop already advanced past the last tool message;
          // step back so the for-loop's increment lands on the next message.
          i--;
          contents.add(fai.Content.functionResponses(responses));
      }
    }
    return contents;
  }

  /// Pack a tool result `String` into a JSON-object payload suitable for
  /// `fai.FunctionResponse(response: ...)`. If the content is itself a
  /// JSON object, pass it through. If it's a JSON primitive (number,
  /// bool, list), wrap as `{result: <decoded>}`. Otherwise wrap the raw
  /// string as `{result: <string>}`.
  Map<String, Object?> _toolResultPayload(String content) {
    try {
      final decoded = jsonDecode(content);
      if (decoded is Map<String, dynamic>) {
        return decoded.cast<String, Object?>();
      }
      return {'result': decoded};
    } on FormatException {
      return {'result': content};
    }
  }

  /// Parse a firebase_ai [fai.GenerateContentResponse] into our [LlmResponse].
  LlmResponse _parseResponse(fai.GenerateContentResponse response) {
    final candidate = response.candidates.firstOrNull;
    if (candidate == null) {
      final blockReason = response.promptFeedback?.blockReason;
      if (blockReason != null) {
        AiLogger.warn(
          'FirebaseAI blocked request: $blockReason',
          tag: 'FirebaseAI',
        );
        throw ContentFilteredException(
          'FirebaseAI: Request blocked by safety filter ($blockReason).',
        );
      }
      AiLogger.warn('FirebaseAI returned no candidates', tag: 'FirebaseAI');
      return const LlmResponse();
    }

    final finishReason = candidate.finishReason;
    if (_isContentFiltered(finishReason)) {
      AiLogger.warn(
        'FirebaseAI response blocked: $finishReason',
        tag: 'FirebaseAI',
      );
      throw ContentFilteredException(
        'FirebaseAI: Response blocked by safety filter ($finishReason).',
      );
    }
    if (finishReason == fai.FinishReason.maxTokens) {
      AiLogger.warn(
        'FirebaseAI response truncated (max tokens)',
        tag: 'FirebaseAI',
      );
      // Don't throw — partial response is still useful. Fall through.
    }

    final parts = candidate.content.parts;

    final functionCalls = parts.whereType<fai.FunctionCall>().toList();
    if (functionCalls.isNotEmpty) {
      final textParts = parts.whereType<fai.TextPart>();
      final thought = textParts.map((p) => p.text).join().trim();
      return LlmResponse(
        textContent: thought.isNotEmpty ? thought : null,
        toolCalls: functionCalls.asMap().entries.map((entry) {
          final index = entry.key;
          final fc = entry.value;
          return ToolCall(
            id: fc.id ?? '${fc.name}#${index + 1}',
            name: fc.name,
            arguments: fc.args.cast<String, dynamic>(),
          );
        }).toList(),
      );
    }

    final textParts = parts.whereType<fai.TextPart>();
    final text = textParts.map((p) => p.text).join();
    return LlmResponse(textContent: text.isNotEmpty ? text : null);
  }

  /// Whether [reason] indicates the model's response was blocked or
  /// withheld for content-policy reasons.
  ///
  /// Only `safety` and `recitation` are surfaced by `firebase_ai`
  /// 3.11.0; future versions may add more (e.g. `prohibitedContent`,
  /// `spii`, `blocklist`) — adjust this helper as the SDK evolves.
  bool _isContentFiltered(fai.FinishReason? reason) {
    return reason == fai.FinishReason.safety ||
        reason == fai.FinishReason.recitation;
  }

  /// Map a `firebase_ai` exception to our typed exception hierarchy so
  /// the agent's existing retry / safety / auth handling kicks in.
  ///
  /// Pattern-matches concrete subclasses where firebase_ai exposes them
  /// (`InvalidApiKey`, `QuotaExceeded`, `ServerException`,
  /// `ServiceApiNotEnabled`, `UnsupportedUserLocation`) and falls back
  /// to keyword matching for any future / unknown subclass.
  Exception _mapException(fai.FirebaseAIException e) {
    if (e is fai.InvalidApiKey) {
      return AuthenticationException('FirebaseAI: ${e.message}');
    }
    if (e is fai.ServiceApiNotEnabled) {
      return AuthenticationException(
        'FirebaseAI: AI Logic API not enabled for this Firebase project — '
        'enable it in the Firebase Console. (${e.message})',
      );
    }
    if (e is fai.UnsupportedUserLocation) {
      return AuthenticationException('FirebaseAI: ${e.message}');
    }
    if (e is fai.QuotaExceeded) {
      return RateLimitException('FirebaseAI: ${e.message}');
    }
    if (e is fai.ServerException) {
      // 5xx-style failures are transient — surface as RateLimitException
      // so retryOnRateLimit kicks in.
      return RateLimitException('FirebaseAI: ${e.message}');
    }

    // Fallback: keyword sniffing on the message for SDK versions that
    // surface unrecognised subclasses or wrap errors generically.
    final msg = e.message.toLowerCase();
    if (msg.contains('api key') ||
        msg.contains('api_key') ||
        msg.contains('unauthorized') ||
        msg.contains('permission') ||
        msg.contains('forbidden') ||
        msg.contains('401') ||
        msg.contains('403')) {
      return AuthenticationException('FirebaseAI: ${e.message}');
    }
    if (msg.contains('quota') ||
        msg.contains('rate') ||
        msg.contains('overloaded') ||
        msg.contains('429') ||
        msg.contains('503')) {
      return RateLimitException('FirebaseAI: ${e.message}');
    }
    if (msg.contains('context') ||
        msg.contains('token') ||
        msg.contains('too long') ||
        msg.contains('maximum')) {
      return ContextOverflowException('FirebaseAI: ${e.message}');
    }
    if (msg.contains('safety') || msg.contains('blocked')) {
      return ContentFilteredException('FirebaseAI: ${e.message}');
    }
    return e;
  }
}
