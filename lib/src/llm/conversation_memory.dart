import '../core/ai_logger.dart';
import 'llm_provider.dart';

/// Manages conversation history with compaction and smart trimming.
///
/// The memory works in two phases:
/// 1. **Compaction** — After each iteration, old verbose tool results
///    (especially `get_screen_content`) are replaced with short summaries.
///    This keeps token count low without losing message slots.
/// 2. **Trimming** — When message count exceeds [maxMessages], old messages
///    are removed from the middle (preserving the first user message and
///    injecting a summary of what was trimmed).
class ConversationMemory {
  /// Maximum number of messages to retain.
  final int maxMessages;

  /// Maximum character length for a single tool result before compaction.
  /// Results longer than this are compacted after they've been seen once.
  final int maxToolResultChars;

  final List<LlmMessage> _messages = [];

  /// Tracks which tool result messages have been sent to the LLM at least
  /// once (by index at the time of sending). After one round-trip, verbose
  /// results can be safely compacted.
  final Set<int> _sentToolResultIndices = {};

  /// [maxMessages] should be derived from the agent's max iterations.
  /// A good formula: `maxAgentIterations * 4 + 20` (each iteration uses
  /// ~3-4 messages, plus buffer for verification and system injections).
  ConversationMemory({
    required this.maxMessages,
    this.maxToolResultChars = 800,
  });

  /// Add a user message to the conversation.
  void addUserMessage(String text) {
    AiLogger.log(
      'Memory: +user message (${text.length} chars), total=${_messages.length + 1}',
      tag: 'Memory',
    );
    _messages.add(LlmMessage.user(text));
    _trimIfNeeded();
  }

  /// Add an assistant text response to the conversation.
  void addAssistantMessage(String text) {
    AiLogger.log(
      'Memory: +assistant message (${text.length} chars), total=${_messages.length + 1}',
      tag: 'Memory',
    );
    _messages.add(LlmMessage.assistant(text));
    _trimIfNeeded();
  }

  /// Add assistant tool calls to the conversation.
  ///
  /// [thought] is the LLM's reasoning/status text emitted alongside the tool
  /// calls. Preserved in conversation history so the LLM sees its own prior
  /// reasoning and the provider can reconstruct the full response.
  void addAssistantToolCalls(List<ToolCall> calls, {String? thought}) {
    AiLogger.log(
      'Memory: +assistant tool calls (${calls.length} calls), total=${_messages.length + 1}',
      tag: 'Memory',
    );
    _messages.add(LlmMessage.assistantToolCalls(calls, thought: thought));
    // Don't trim here — the tool results must follow immediately.
  }

  /// Add a tool result to the conversation.
  void addToolResult(String toolCallId, String content) {
    AiLogger.log(
      'Memory: +tool result for "$toolCallId" (${content.length} chars), total=${_messages.length + 1}',
      tag: 'Memory',
    );
    _messages.add(LlmMessage.toolResult(toolCallId, content));
    _trimIfNeeded();
  }

  /// Get all messages in the current window.
  ///
  /// Also marks current tool results as "sent" so they can be compacted
  /// on the next call (after the LLM has seen them once).
  List<LlmMessage> getMessages() {
    // Compact tool results that the LLM has already seen.
    _compactOldToolResults();

    // Mark all current tool result indices as sent.
    _sentToolResultIndices.clear();
    for (int i = 0; i < _messages.length; i++) {
      if (_messages[i].role == LlmRole.tool) {
        _sentToolResultIndices.add(i);
      }
    }

    return List.unmodifiable(_messages);
  }

  /// Number of messages currently stored.
  int get length => _messages.length;

  /// Whether the conversation is empty.
  bool get isEmpty => _messages.isEmpty;

  /// Clear all messages.
  void clear() {
    AiLogger.log(
      'Memory: cleared all ${_messages.length} messages',
      tag: 'Memory',
    );
    _messages.clear();
    _sentToolResultIndices.clear();
  }

  // ---------------------------------------------------------------------------
  // Compaction — shrink verbose tool results the LLM has already seen
  // ---------------------------------------------------------------------------

  /// Replace verbose tool results that have been sent to the LLM with
  /// compact summaries. This dramatically reduces token count for long
  /// multi-step flows where `get_screen_content` results are thousands of
  /// characters each but become stale after the next action.
  void _compactOldToolResults() {
    // Find the index of the LAST tool result message — we never compact
    // the most recent one since the LLM needs the full context for its
    // next decision.
    int lastToolIdx = -1;
    for (int i = _messages.length - 1; i >= 0; i--) {
      if (_messages[i].role == LlmRole.tool) {
        lastToolIdx = i;
        break;
      }
    }

    int compacted = 0;
    for (int i = 0; i < _messages.length; i++) {
      final msg = _messages[i];
      if (msg.role != LlmRole.tool) continue;
      if (i == lastToolIdx) continue; // Keep the most recent tool result full.
      if (!_sentToolResultIndices.contains(i)) continue; // Not yet seen by LLM.

      final content = msg.content ?? '';
      if (content.length <= maxToolResultChars) continue; // Already short.

      // Compact: extract the tool name from the preceding assistant message
      // and create a brief summary.
      final toolName = _findToolNameForResult(i);
      final summary = _compactResult(toolName, content);

      _messages[i] = LlmMessage.toolResult(msg.toolCallId ?? '', summary);
      compacted++;
    }

    if (compacted > 0) {
      AiLogger.log(
        'Memory: compacted $compacted old tool results',
        tag: 'Memory',
      );
    }
  }

  /// Find the tool name for a tool result at [resultIndex] by looking
  /// at the preceding assistant tool-call message.
  String _findToolNameForResult(int resultIndex) {
    final resultMsg = _messages[resultIndex];
    final targetId = resultMsg.toolCallId;

    // Walk backwards to find the assistant message with matching tool call.
    for (int j = resultIndex - 1; j >= 0; j--) {
      final msg = _messages[j];
      if (msg.role == LlmRole.assistant && msg.toolCalls != null) {
        for (final tc in msg.toolCalls!) {
          if (tc.id == targetId) return tc.name;
        }
      }
    }
    return 'unknown';
  }

  /// Create a compact summary of a tool result based on the tool type.
  static String _compactResult(String toolName, String content) {
    switch (toolName) {
      case 'get_screen_content':
        // Extract just the route and a brief element summary.
        final routeMatch = RegExp(r'CURRENT ROUTE:\s*(\S+)').firstMatch(content);
        final route = routeMatch?.group(1) ?? '?';
        return '[Screen captured: $route — details compacted, call get_screen_content for fresh view]';

      case 'tap_element':
      case 'long_press_element':
        // Keep the full result — these are usually short and contain
        // important feedback like screenChanged and snackbar text.
        if (content.length > 500) {
          return content.substring(0, 500);
        }
        return content;

      case 'set_text':
        // Keep short — these confirm text entry.
        if (content.length > 300) {
          return content.substring(0, 300);
        }
        return content;

      default:
        // Generic: keep first 300 chars.
        if (content.length > 300) {
          return '${content.substring(0, 300)}… [compacted]';
        }
        return content;
    }
  }

  // ---------------------------------------------------------------------------
  // Trimming — drop old messages when count exceeds maxMessages
  // ---------------------------------------------------------------------------

  /// Trim old messages to stay within the max window size.
  ///
  /// Always preserves:
  /// - The FIRST user message (the original request — never trimmed)
  /// - The most recent messages (priority)
  /// - Complete tool call/result pairs (never split them)
  ///
  /// Injects a summary of trimmed actions so the LLM knows what happened.
  void _trimIfNeeded() {
    if (_messages.length <= maxMessages) return;

    AiLogger.log(
      'Memory: trimming — ${_messages.length} messages exceeds max $maxMessages',
      tag: 'Memory',
    );

    // Never trim the first user message — it's the original request and
    // losing it causes the LLM to lose context of the task entirely.
    int trimFrom = 1;

    // Find a safe trim point — don't split tool call/result pairs.
    int trimTo = _messages.length - maxMessages;

    // Must keep at least the first message.
    if (trimTo <= trimFrom) return;

    // If the trim point would land between a tool call and its result,
    // move forward past the result.
    while (trimTo < _messages.length && _messages[trimTo].role == LlmRole.tool) {
      trimTo++;
    }

    // Also don't start on an assistant message with tool calls
    // without the following tool results.
    if (trimTo > 0 && trimTo < _messages.length) {
      final prev = _messages[trimTo - 1];
      if (prev.role == LlmRole.assistant &&
          prev.toolCalls != null &&
          prev.toolCalls!.isNotEmpty) {
        trimTo++;
        while (
            trimTo < _messages.length && _messages[trimTo].role == LlmRole.tool) {
          trimTo++;
        }
      }
    }

    if (trimTo > trimFrom) {
      // Build a summary of what's being trimmed so the LLM doesn't lose
      // track of actions already performed.
      final summary = _summarizeTrimmedMessages(trimFrom, trimTo);

      final trimCount = trimTo - trimFrom;
      _messages.removeRange(trimFrom, trimTo);

      // Inject the summary right after the first user message so the LLM
      // sees: [original request] → [summary of prior actions] → [recent messages].
      if (summary.isNotEmpty) {
        _messages.insert(
          1,
          LlmMessage.user(
            '[SYSTEM — CONTEXT SUMMARY]\n'
            'The following actions were performed earlier in this task '
            '(messages compacted to save space):\n$summary\n'
            'Continue from where you left off. Do NOT repeat these actions.',
          ),
        );
      }

      // Clear sent-indices since positions shifted.
      _sentToolResultIndices.clear();

      AiLogger.log(
        'Memory: trimmed $trimCount messages, injected summary, '
        '${_messages.length} remaining',
        tag: 'Memory',
      );
    }
  }

  /// Build a human-readable summary of the messages being trimmed.
  String _summarizeTrimmedMessages(int from, int to) {
    final actions = <String>[];
    for (int i = from; i < to; i++) {
      final msg = _messages[i];
      if (msg.role == LlmRole.assistant && msg.toolCalls != null) {
        for (final tc in msg.toolCalls!) {
          final args = tc.arguments.values.take(2).join(', ');
          actions.add('• ${tc.name}($args)');
        }
      }
    }
    return actions.take(15).join('\n');
  }
}
