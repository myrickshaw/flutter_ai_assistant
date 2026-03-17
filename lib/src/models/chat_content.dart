import 'dart:typed_data';

import 'package:flutter/widgets.dart';

/// A block of rich content within a chat message.
///
/// Messages can contain multiple content blocks rendered in sequence:
/// text, images, buttons, and cards. This enables rich interactive
/// chat experiences beyond plain text.
sealed class ChatContent {
  const ChatContent();
}

/// Plain text content block.
class TextContent extends ChatContent {
  final String text;
  const TextContent(this.text);
}

/// An inline image content block.
class ImageContent extends ChatContent {
  /// Network URL for the image.
  final String? url;

  /// Raw image bytes (e.g. screenshot, locally generated).
  final Uint8List? bytes;

  /// Optional caption displayed below the image.
  final String? caption;

  /// Aspect ratio hint for layout (width / height). If null, intrinsic
  /// aspect ratio is used.
  final double? aspectRatio;

  const ImageContent({this.url, this.bytes, this.caption, this.aspectRatio});
}

/// A group of tappable quick-reply buttons.
///
/// Rendered as a flowing row of chips (or a vertical list for [ButtonLayout.column]).
/// Tapping a button sends its label as the user's message and disables
/// all buttons in the group to prevent double-taps.
class ButtonsContent extends ChatContent {
  final List<ChatButton> buttons;
  final ButtonLayout layout;

  const ButtonsContent({
    required this.buttons,
    this.layout = ButtonLayout.wrap,
  });
}

/// A rich card with optional image, title, subtitle, and action buttons.
///
/// Use for product cards, info cards, search results, etc.
class CardContent extends ChatContent {
  final String title;
  final String? subtitle;
  final String? imageUrl;
  final Uint8List? imageBytes;
  final List<ChatButton>? actions;

  const CardContent({
    required this.title,
    this.subtitle,
    this.imageUrl,
    this.imageBytes,
    this.actions,
  });
}

/// Layout options for button groups.
enum ButtonLayout {
  /// Buttons flow horizontally, wrapping to next line as needed.
  wrap,

  /// Buttons stacked vertically (full width).
  column,
}

/// A single tappable button in a chat message.
class ChatButton {
  /// Primary label text shown on the button.
  final String label;

  /// Optional secondary text (e.g. price, description) shown below the label.
  final String? subtitle;

  /// Visual style of the button.
  final ChatButtonStyle style;

  /// Optional leading icon.
  final IconData? icon;

  /// Optional small image (e.g. product thumbnail) shown in the button.
  final String? imageUrl;

  const ChatButton({
    required this.label,
    this.subtitle,
    this.style = ChatButtonStyle.outlined,
    this.icon,
    this.imageUrl,
  });
}

/// Visual style for chat buttons.
enum ChatButtonStyle {
  /// Accent-colored filled button (primary action).
  primary,

  /// Outlined button with accent border (default).
  outlined,

  /// Red-tinted button for destructive/cancel actions.
  destructive,

  /// Green-tinted button for confirm/success actions.
  success,
}
