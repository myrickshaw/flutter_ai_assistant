import 'dart:async';
import 'dart:typed_data';

import '../core/ai_logger.dart';
import '../tools/tool_definition.dart';

/// Role of a message in the LLM conversation.
enum LlmRole { system, user, assistant, tool }

/// Binary image data for multimodal LLM messages.
class LlmImageContent {
  /// Raw image bytes (e.g. PNG).
  final Uint8List bytes;

  /// MIME type of the image.
  final String mimeType;

  const LlmImageContent({required this.bytes, this.mimeType = 'image/png'});
}

/// A message in the LLM conversation history.
class LlmMessage {
  final LlmRole role;

  /// Text content (for user/assistant/system messages).
  final String? content;

  /// Tool calls returned by the assistant.
  final List<ToolCall>? toolCalls;

  /// For tool-role messages: the ID of the tool call this responds to.
  final String? toolCallId;

  /// Optional image attachments for multimodal messages.
  final List<LlmImageContent>? images;

  const LlmMessage({
    required this.role,
    this.content,
    this.toolCalls,
    this.toolCallId,
    this.images,
  });

  factory LlmMessage.system(String content) =>
      LlmMessage(role: LlmRole.system, content: content);

  factory LlmMessage.user(String content) =>
      LlmMessage(role: LlmRole.user, content: content);

  factory LlmMessage.userMultimodal(
    String content,
    List<LlmImageContent> images,
  ) => LlmMessage(role: LlmRole.user, content: content, images: images);

  factory LlmMessage.assistant(String content) =>
      LlmMessage(role: LlmRole.assistant, content: content);

  factory LlmMessage.assistantToolCalls(
    List<ToolCall> calls, {
    String? thought,
  }) => LlmMessage(role: LlmRole.assistant, toolCalls: calls, content: thought);

  factory LlmMessage.toolResult(String toolCallId, String content) =>
      LlmMessage(role: LlmRole.tool, toolCallId: toolCallId, content: content);
}

/// A structured function call returned by the LLM.
class ToolCall {
  /// Unique ID for this call (used to match results).
  final String id;

  /// The tool/function name to call.
  final String name;

  /// The arguments to pass to the tool.
  final Map<String, dynamic> arguments;

  const ToolCall({
    required this.id,
    required this.name,
    required this.arguments,
  });

  @override
  String toString() => 'ToolCall($name, $arguments)';
}

/// Response from an LLM provider.
class LlmResponse {
  /// Natural language text response (null if tool call).
  final String? textContent;

  /// Structured tool calls (null if text response).
  final List<ToolCall>? toolCalls;

  const LlmResponse({this.textContent, this.toolCalls});

  /// Whether this response contains tool calls.
  bool get isToolCall => toolCalls != null && toolCalls!.isNotEmpty;
}

/// Abstract interface for LLM providers.
///
/// Implementations must convert between the common message/tool format
/// and the provider-specific API format.
abstract class LlmProvider {
  /// Send a conversation to the LLM and get a response.
  ///
  /// [messages] is the conversation history.
  /// [tools] are the available tools the LLM can call.
  /// [systemPrompt] is prepended as a system message if provided.
  Future<LlmResponse> sendMessage({
    required List<LlmMessage> messages,
    required List<ToolDefinition> tools,
    String? systemPrompt,
  });

  /// Optional lifecycle hook for providers that hold resources
  /// (for example, HTTP clients).
  ///
  /// Implementations that do not allocate resources can ignore this.
  void dispose() {}
}

// ---------------------------------------------------------------------------
// Provider exception types — allow the agent to distinguish error categories
// ---------------------------------------------------------------------------

/// Thrown when the API returns a rate-limit response (HTTP 429).
class RateLimitException implements Exception {
  final Duration? retryAfter;
  final String message;
  const RateLimitException(this.message, {this.retryAfter});
  @override
  String toString() => 'RateLimitException: $message';
}

/// Thrown when the conversation exceeds the model's context window.
class ContextOverflowException implements Exception {
  final String message;
  const ContextOverflowException(this.message);
  @override
  String toString() => 'ContextOverflowException: $message';
}

/// Thrown when the API rejects the request due to content safety filters.
class ContentFilteredException implements Exception {
  final String message;
  const ContentFilteredException(this.message);
  @override
  String toString() => 'ContentFilteredException: $message';
}

/// Thrown when the API key is invalid or expired (HTTP 401/403).
class AuthenticationException implements Exception {
  final String message;
  const AuthenticationException(this.message);
  @override
  String toString() => 'AuthenticationException: $message';
}

// ---------------------------------------------------------------------------
// Retry helper — shared by HTTP-based providers (Claude, OpenAI)
// ---------------------------------------------------------------------------

/// Checks an HTTP status code and throws typed exceptions for known errors.
///
/// Call this in providers before the generic `throw Exception(...)` fallback.
Never throwForHttpStatus(int statusCode, String body, String providerName) {
  if (statusCode == 401 || statusCode == 403) {
    throw AuthenticationException(
      '$providerName: Invalid or expired API key (HTTP $statusCode).',
    );
  }
  if (statusCode == 429) {
    // Try to parse Retry-After header value from the body (some providers
    // include it). Fall back to a default backoff.
    throw RateLimitException(
      '$providerName: Rate limited (HTTP 429). Slow down.',
    );
  }
  // Token/context overflow typically returns 400 with a specific message.
  final lowerBody = body.toLowerCase();
  if (statusCode == 400 &&
      (lowerBody.contains('context') ||
          lowerBody.contains('token') ||
          lowerBody.contains('too long') ||
          lowerBody.contains('maximum'))) {
    throw ContextOverflowException(
      '$providerName: Conversation too long for model context window.',
    );
  }
  if (statusCode == 529) {
    throw RateLimitException(
      '$providerName: API overloaded (HTTP $statusCode). Retry shortly.',
    );
  }
  // Server errors (5xx) — retryable.
  if (statusCode >= 500) {
    throw RateLimitException(
      '$providerName: Server error (HTTP $statusCode). Retry shortly.',
    );
  }
  throw Exception('$providerName API error (HTTP $statusCode): $body');
}

/// Executes [action] with up to [maxRetries] retries on [RateLimitException].
/// Uses exponential backoff starting at [initialDelay].
Future<T> retryOnRateLimit<T>(
  Future<T> Function() action, {
  int maxRetries = 2,
  Duration initialDelay = const Duration(seconds: 2),
  String tag = 'LLM',
}) async {
  int attempt = 0;
  Duration delay = initialDelay;
  while (true) {
    try {
      return await action();
    } on RateLimitException catch (e) {
      attempt++;
      if (attempt > maxRetries) rethrow;
      AiLogger.warn(
        '$tag: ${e.message} — retry $attempt/$maxRetries in ${delay.inSeconds}s',
        tag: tag,
      );
      await Future.delayed(delay);
      delay *= 2; // Exponential backoff.
    }
  }
}
