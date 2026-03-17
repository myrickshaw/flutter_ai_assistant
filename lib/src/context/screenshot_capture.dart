import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import '../core/ai_logger.dart';

/// Captures screenshots of the app content for visual LLM context.
///
/// Uses a [RepaintBoundary] key to capture only the app content
/// (excluding the AI overlay), then downscales to [targetWidth] to
/// keep the payload manageable for LLM APIs (~100-200KB PNG).
class ScreenshotCapture {
  /// Key of the [RepaintBoundary] wrapping the app content.
  final GlobalKey appContentKey;

  /// Target width in pixels. Height is scaled proportionally.
  /// 720px gives good readability while keeping payload small.
  final int targetWidth;

  const ScreenshotCapture({
    required this.appContentKey,
    this.targetWidth = 720,
  });

  /// Capture the app content as PNG bytes.
  ///
  /// Returns null if capture fails (e.g. widget not mounted, no render object).
  Future<Uint8List?> capture() async {
    try {
      final renderObject = appContentKey.currentContext?.findRenderObject();
      if (renderObject == null || renderObject is! RenderRepaintBoundary) {
        AiLogger.warn(
          'Screenshot capture: no RenderRepaintBoundary found',
          tag: 'Screenshot',
        );
        return null;
      }

      final boundary = renderObject;
      final logicalWidth = boundary.size.width;
      if (logicalWidth <= 0) return null;

      final pixelRatio = targetWidth / logicalWidth;
      final image = await boundary.toImage(pixelRatio: pixelRatio);
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();

      if (byteData == null) return null;

      final bytes = byteData.buffer.asUint8List();
      AiLogger.log(
        'Screenshot captured: ${bytes.length} bytes '
        '(${image.width}x${image.height})',
        tag: 'Screenshot',
      );
      return bytes;
    } catch (e) {
      AiLogger.warn('Screenshot capture failed: $e', tag: 'Screenshot');
      return null;
    }
  }
}
