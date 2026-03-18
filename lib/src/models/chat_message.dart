import 'agent_action.dart';
import 'chat_content.dart';

/// Role of a message in the AI chat conversation.
enum AiMessageRole { user, assistant, system }

/// Classification of an AI response for post-task UI behavior.
///
/// Determines whether the overlay auto-closes and what kind of popup to show.
enum AiResponseType {
  /// Agent performed screen-changing actions (tap, navigate, set_text, etc.)
  /// and completed successfully. Shows a brief popup that auto-dismisses.
  actionComplete,

  /// Agent returned informational text (no modifying actions).
  /// Shows a response card that stays until the user dismisses it.
  infoResponse,

  /// Agent encountered an error or needs user input.
  /// Overlay stays open — no auto-close.
  error,
}

/// A single message in the AI assistant chat conversation.
class AiChatMessage {
  final String id;
  final AiMessageRole role;

  /// Plain text content. Always present as the base message.
  final String content;

  final DateTime timestamp;

  /// Actions the AI performed as part of this response (for display purposes).
  final List<AgentAction>? actions;

  /// Whether this message originated from voice input.
  final bool isVoice;

  /// Rich content blocks (text, images, buttons, cards).
  ///
  /// When non-null and non-empty, the chat bubble renders these blocks
  /// instead of the plain [content] text. The [content] field still holds
  /// the full text for accessibility, search, and TTS.
  final List<ChatContent>? richContent;

  /// Whether interactive buttons in this message have been disabled
  /// (e.g. after the user tapped one). Mutable so the controller can
  /// disable buttons without recreating the message.
  bool buttonsDisabled;

  /// The index of the button that was tapped (for highlight styling).
  /// -1 means no button was tapped.
  int tappedButtonIndex;

  AiChatMessage({
    required this.id,
    required this.role,
    required this.content,
    required this.timestamp,
    this.actions,
    this.isVoice = false,
    this.richContent,
    this.buttonsDisabled = false,
    this.tappedButtonIndex = -1,
  });
}
