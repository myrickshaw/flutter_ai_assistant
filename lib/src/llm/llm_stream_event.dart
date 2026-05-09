import 'llm_provider.dart';

/// An event emitted by a streaming LLM provider.
///
/// Streaming providers emit a sequence of [LlmStreamText] (and possibly
/// [LlmStreamToolCall]) events as the model produces output, ending with
/// [LlmStreamDone] on successful completion. On error the stream
/// terminates with the error and [LlmStreamDone] is **not** emitted —
/// listen via the stream subscription's `onError` instead.
sealed class LlmStreamEvent {
  const LlmStreamEvent();
}

/// A text delta in the streamed response. Concatenate the [delta] values
/// across events to build the full text.
class LlmStreamText extends LlmStreamEvent {
  /// The incremental text added since the previous [LlmStreamText] event.
  final String delta;
  const LlmStreamText(this.delta);
}

/// A complete tool call surfaced during streaming.
///
/// Tool calls are emitted atomically — there is no partial-tool-call
/// event. The [call] carries the same `id`, `name`, and `arguments`
/// shape returned by the non-streaming `sendMessage` path.
class LlmStreamToolCall extends LlmStreamEvent {
  /// The tool call returned by the model.
  final ToolCall call;
  const LlmStreamToolCall(this.call);
}

/// Successful end of the stream, carrying any usage metadata reported
/// by the provider.
///
/// On stream error, this event is **not** emitted — the stream
/// terminates with the error.
class LlmStreamDone extends LlmStreamEvent {
  /// Number of prompt tokens served from the implicit prompt cache
  /// (Gemini 2.5+ via Firebase AI Logic). Null if not reported by the
  /// provider; 0 if no tokens were served from cache.
  final int? cachedTokenCount;

  /// Total prompt tokens for this request. Null if the provider does
  /// not report it.
  final int? promptTokenCount;

  /// Total candidate (response) tokens for this request. Null if the
  /// provider does not report it.
  final int? candidatesTokenCount;

  const LlmStreamDone({
    this.cachedTokenCount,
    this.promptTokenCount,
    this.candidatesTokenCount,
  });
}
