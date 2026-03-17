import 'package:flutter/material.dart';

import '../models/agent_action.dart';
import '../models/chat_content.dart';
import '../models/chat_message.dart';

// Same JARVIS palette as chat_overlay.dart.
const _bgMid = Color(0xFF0A0A20);
const _bgDeep = Color(0xFF040412);
const _accent = Color(0xFF7C6AFF);
const _glow = Color(0xFFAE9CFF);
const _glassBorder = Color(0x1AFFFFFF);
const _textH = Color(0xFFF2F0FF);
const _textB = Color(0xFFB0ADCC);
const _textD = Color(0xFF6E6B8A);
const _green = Color(0xFF5AE89E);
const _red = Color(0xFFFF6B8A);

/// Callback for when a chat button is tapped.
typedef OnChatButtonTap = void Function(
  AiChatMessage message,
  ChatButton button,
  int buttonIndex,
);

/// Single chat bubble styled for the JARVIS-themed AI overlay.
///
/// Supports rich content: text, images, interactive buttons, and cards.
/// When [message.richContent] is non-null, renders the content blocks
/// instead of plain text.
class ChatBubble extends StatelessWidget {
  final AiChatMessage message;
  final OnChatButtonTap? onButtonTap;

  const ChatBubble({super.key, required this.message, this.onButtonTap});

  bool get _isUser => message.role == AiMessageRole.user;
  bool get _hasRichContent =>
      message.richContent != null && message.richContent!.isNotEmpty;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Row(
        mainAxisAlignment:
            _isUser ? MainAxisAlignment.end : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (!_isUser) _aiAvatar(),
          if (!_isUser) const SizedBox(width: 8),
          Flexible(
            child: Column(
              crossAxisAlignment:
                  _isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start,
              children: [
                _bubble(),
                // Buttons rendered OUTSIDE the bubble for better tap targets.
                if (_hasRichContent) _richButtonsOutside(),
                if (message.actions != null && message.actions!.isNotEmpty)
                  _actions(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _aiAvatar() => Container(
        width: 26,
        height: 26,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: const LinearGradient(colors: [_accent, _glow]),
          boxShadow: [
            BoxShadow(
                color: _accent.withValues(alpha: 0.25), blurRadius: 8),
          ],
        ),
        child: const Icon(Icons.auto_awesome, size: 12, color: Colors.white),
      );

  Widget _bubble() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      constraints: const BoxConstraints(maxWidth: 300),
      decoration: BoxDecoration(
        gradient: _isUser
            ? const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [_accent, Color(0xFF6B5CE7)],
              )
            : LinearGradient(
                begin: Alignment.centerLeft,
                end: const Alignment(0.5, 0),
                colors: [
                  _accent.withValues(alpha: 0.06),
                  _bgMid,
                ],
              ),
        borderRadius: BorderRadius.only(
          topLeft: const Radius.circular(18),
          topRight: const Radius.circular(18),
          bottomLeft:
              _isUser ? const Radius.circular(18) : const Radius.circular(4),
          bottomRight:
              _isUser ? const Radius.circular(4) : const Radius.circular(18),
        ),
        border: _isUser ? null : Border.all(color: _glassBorder, width: 0.5),
        boxShadow: [
          if (_isUser)
            BoxShadow(
                color: _accent.withValues(alpha: 0.2),
                blurRadius: 12,
                offset: const Offset(0, 3)),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (message.isVoice)
            Padding(
              padding: const EdgeInsets.only(bottom: 3),
              child: Icon(Icons.mic,
                  size: 11,
                  color: _isUser
                      ? Colors.white54
                      : _textD.withValues(alpha: 0.5)),
            ),
          if (_hasRichContent)
            _richContentInBubble()
          else
            Text(
              message.content,
              style: TextStyle(
                color: _isUser ? Colors.white : _textH,
                fontSize: 13.5,
                height: 1.45,
              ),
            ),
        ],
      ),
    );
  }

  // ── Rich content rendering (inside bubble) ────────────────────────────────

  /// Renders rich content blocks that belong INSIDE the bubble (text, images, cards).
  /// Buttons are rendered outside the bubble via [_richButtonsOutside].
  Widget _richContentInBubble() {
    final blocks = message.richContent!
        .where((c) => c is! ButtonsContent)
        .toList();

    if (blocks.isEmpty) {
      // Only buttons — show the plain text content as fallback.
      return Text(
        message.content,
        style: TextStyle(
          color: _isUser ? Colors.white : _textH,
          fontSize: 13.5,
          height: 1.45,
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (int i = 0; i < blocks.length; i++) ...[
          if (i > 0) const SizedBox(height: 8),
          _renderBlock(blocks[i]),
        ],
      ],
    );
  }

  /// Renders ButtonsContent blocks that appear OUTSIDE the bubble for
  /// better tap targets and visual separation.
  Widget _richButtonsOutside() {
    final buttonBlocks = message.richContent!
        .whereType<ButtonsContent>()
        .toList();

    if (buttonBlocks.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final block in buttonBlocks) _renderButtons(block),
        ],
      ),
    );
  }

  Widget _renderBlock(ChatContent block) {
    return switch (block) {
      TextContent(:final text) => Text(
          text,
          style: TextStyle(
            color: _isUser ? Colors.white : _textH,
            fontSize: 13.5,
            height: 1.45,
          ),
        ),
      ImageContent() => _renderImage(block),
      CardContent() => _renderCard(block),
      ButtonsContent() => _renderButtons(block),
    };
  }

  // ── Image ─────────────────────────────────────────────────────────────────

  Widget _renderImage(ImageContent image) {
    Widget imageWidget;

    if (image.bytes != null) {
      imageWidget = Image.memory(
        image.bytes!,
        fit: BoxFit.cover,
        width: double.infinity,
      );
    } else if (image.url != null) {
      imageWidget = Image.network(
        image.url!,
        fit: BoxFit.cover,
        width: double.infinity,
        loadingBuilder: (_, child, progress) {
          if (progress == null) return child;
          return SizedBox(
            height: 120,
            child: Center(
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: _accent,
                value: progress.expectedTotalBytes != null
                    ? progress.cumulativeBytesLoaded /
                        progress.expectedTotalBytes!
                    : null,
              ),
            ),
          );
        },
        errorBuilder: (_, _, _) => Container(
          height: 80,
          color: _bgDeep,
          child: const Center(
            child: Icon(Icons.broken_image_outlined, color: _textD, size: 28),
          ),
        ),
      );
    } else {
      return const SizedBox.shrink();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 200),
            child: imageWidget,
          ),
        ),
        if (image.caption != null) ...[
          const SizedBox(height: 4),
          Text(
            image.caption!,
            style: TextStyle(
              color: _textD.withValues(alpha: 0.8),
              fontSize: 11,
              fontStyle: FontStyle.italic,
            ),
          ),
        ],
      ],
    );
  }

  // ── Buttons ───────────────────────────────────────────────────────────────

  Widget _renderButtons(ButtonsContent block) {
    final disabled = message.buttonsDisabled;
    final tappedIdx = message.tappedButtonIndex;

    // Track global button index across all ButtonsContent blocks.
    int globalStartIndex = 0;
    for (final c in message.richContent!) {
      if (identical(c, block)) break;
      if (c is ButtonsContent) globalStartIndex += c.buttons.length;
    }

    if (block.layout == ButtonLayout.column) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (int i = 0; i < block.buttons.length; i++) ...[
            if (i > 0) const SizedBox(height: 6),
            _buttonWidget(
              block.buttons[i],
              globalIndex: globalStartIndex + i,
              disabled: disabled,
              isTapped: tappedIdx == globalStartIndex + i,
            ),
          ],
        ],
      );
    }

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (int i = 0; i < block.buttons.length; i++)
          _buttonWidget(
            block.buttons[i],
            globalIndex: globalStartIndex + i,
            disabled: disabled,
            isTapped: tappedIdx == globalStartIndex + i,
          ),
      ],
    );
  }

  Widget _buttonWidget(
    ChatButton button, {
    required int globalIndex,
    required bool disabled,
    required bool isTapped,
  }) {
    final colors = _buttonColors(button.style, disabled: disabled, isTapped: isTapped);

    return GestureDetector(
      onTap: disabled ? null : () => onButtonTap?.call(message, button, globalIndex),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: EdgeInsets.symmetric(
          horizontal: button.subtitle != null ? 14 : 12,
          vertical: button.subtitle != null ? 10 : 8,
        ),
        decoration: BoxDecoration(
          color: colors.bg,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: colors.border, width: isTapped ? 1.5 : 1),
          boxShadow: isTapped
              ? [BoxShadow(color: colors.border.withValues(alpha: 0.3), blurRadius: 8)]
              : null,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (button.icon != null) ...[
              Icon(button.icon, size: 16, color: colors.text),
              const SizedBox(width: 6),
            ],
            Flexible(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    button.label,
                    style: TextStyle(
                      color: colors.text,
                      fontSize: 13,
                      fontWeight: isTapped ? FontWeight.w600 : FontWeight.w500,
                    ),
                  ),
                  if (button.subtitle != null)
                    Text(
                      button.subtitle!,
                      style: TextStyle(
                        color: colors.text.withValues(alpha: 0.6),
                        fontSize: 11,
                      ),
                    ),
                ],
              ),
            ),
            if (isTapped) ...[
              const SizedBox(width: 6),
              Icon(Icons.check_circle, size: 14, color: colors.border),
            ],
          ],
        ),
      ),
    );
  }

  _ButtonColors _buttonColors(
    ChatButtonStyle style, {
    required bool disabled,
    required bool isTapped,
  }) {
    if (disabled && !isTapped) {
      return _ButtonColors(
        bg: _bgMid.withValues(alpha: 0.3),
        border: _glassBorder.withValues(alpha: 0.1),
        text: _textD.withValues(alpha: 0.4),
      );
    }

    return switch (style) {
      ChatButtonStyle.primary => _ButtonColors(
          bg: isTapped ? _accent.withValues(alpha: 0.25) : _accent.withValues(alpha: 0.12),
          border: _accent.withValues(alpha: isTapped ? 0.8 : 0.4),
          text: isTapped ? _textH : _glow,
        ),
      ChatButtonStyle.outlined => _ButtonColors(
          bg: isTapped ? _accent.withValues(alpha: 0.15) : _bgMid.withValues(alpha: 0.5),
          border: isTapped ? _accent.withValues(alpha: 0.7) : _glassBorder.withValues(alpha: 0.4),
          text: isTapped ? _textH : _textB,
        ),
      ChatButtonStyle.success => _ButtonColors(
          bg: isTapped ? _green.withValues(alpha: 0.2) : _green.withValues(alpha: 0.08),
          border: _green.withValues(alpha: isTapped ? 0.7 : 0.3),
          text: isTapped ? _textH : _green,
        ),
      ChatButtonStyle.destructive => _ButtonColors(
          bg: isTapped ? _red.withValues(alpha: 0.2) : _red.withValues(alpha: 0.08),
          border: _red.withValues(alpha: isTapped ? 0.7 : 0.3),
          text: isTapped ? _textH : _red,
        ),
    };
  }

  // ── Card ───────────────────────────────────────────────────────────────────

  Widget _renderCard(CardContent card) {
    final hasImage = card.imageUrl != null || card.imageBytes != null;

    return Container(
      constraints: const BoxConstraints(maxWidth: 260),
      decoration: BoxDecoration(
        color: _bgDeep,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _glassBorder, width: 0.5),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (hasImage)
            SizedBox(
              height: 120,
              width: double.infinity,
              child: card.imageBytes != null
                  ? Image.memory(card.imageBytes!, fit: BoxFit.cover)
                  : Image.network(
                      card.imageUrl!,
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) => Container(
                        color: _bgMid,
                        child: const Center(
                          child: Icon(Icons.image_outlined,
                              color: _textD, size: 32),
                        ),
                      ),
                    ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  card.title,
                  style: const TextStyle(
                    color: _textH,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (card.subtitle != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    card.subtitle!,
                    style: TextStyle(
                      color: _textD.withValues(alpha: 0.8),
                      fontSize: 12,
                      height: 1.3,
                    ),
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
                if (card.actions != null && card.actions!.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final action in card.actions!)
                        _cardActionButton(action),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _cardActionButton(ChatButton button) {
    final disabled = message.buttonsDisabled;
    final colors = _buttonColors(
      button.style,
      disabled: disabled,
      isTapped: false,
    );

    return GestureDetector(
      onTap: disabled ? null : () => onButtonTap?.call(message, button, -1),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: colors.bg,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: colors.border, width: 0.5),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (button.icon != null) ...[
              Icon(button.icon, size: 13, color: colors.text),
              const SizedBox(width: 4),
            ],
            Text(
              button.label,
              style: TextStyle(
                color: colors.text,
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Action chips (tool execution history) ─────────────────────────────────

  Widget _actions() {
    final visible =
        message.actions!.where((a) => a.toolName != 'get_screen_content').toList();
    if (visible.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 5),
      child: Wrap(
        spacing: 4,
        runSpacing: 4,
        children: [for (final a in visible) _chip(a)],
      ),
    );
  }

  Widget _chip(AgentAction a) {
    final ok = a.result.success;
    final c = ok ? _green : _red;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: c.withValues(alpha: 0.2)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(ok ? Icons.check_circle_outline : Icons.error_outline,
              size: 10, color: c.withValues(alpha: 0.8)),
          const SizedBox(width: 3),
          Flexible(
            child: Text(a.toDisplayString(),
                style: TextStyle(
                    fontSize: 10, color: _textD.withValues(alpha: 0.7))),
          ),
        ],
      ),
    );
  }
}

/// Color scheme for a button.
class _ButtonColors {
  final Color bg;
  final Color border;
  final Color text;
  const _ButtonColors({required this.bg, required this.border, required this.text});
}
