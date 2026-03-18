import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/ai_assistant_controller.dart';
import '../models/chat_message.dart';

// ─── JARVIS palette (reuse from chat_overlay) ────────────────────────────────
const _bgDeep = Color(0xFF040412);
const _accent = Color(0xFF7C6AFF);
const _glow = Color(0xFFAE9CFF);
const _textH = Color(0xFFF2F0FF);
const _textD = Color(0xFF6E6B8A);
const _green = Color(0xFF5AE89E);

/// Compact floating popup shown above the FAB after the AI completes a task
/// and the overlay auto-closes.
///
/// Two visual modes:
/// - [AiResponseType.actionComplete]: brief confirmation with green accent,
///   auto-dismisses after 8 seconds with a visible countdown ring.
/// - [AiResponseType.infoResponse]: larger card with full response text,
///   stays until the user dismisses it.
///
/// Interactions:
/// - Tap → re-opens the full chat overlay
/// - Swipe down → dismisses
/// - Auto-dismiss → only for action confirmations
class ResponsePopup extends StatefulWidget {
  final AiAssistantController controller;

  const ResponsePopup({super.key, required this.controller});

  @override
  State<ResponsePopup> createState() => _ResponsePopupState();
}

class _ResponsePopupState extends State<ResponsePopup>
    with TickerProviderStateMixin {
  late final AnimationController _entryCtrl;
  late final AnimationController _countdownCtrl;
  late final AnimationController _glowCtrl;

  // Gesture tracking for swipe-to-dismiss.
  double _dragY = 0;
  bool _isDismissing = false;

  AiAssistantController get _ctrl => widget.controller;
  bool get _isAction =>
      _ctrl.responsePopupType == AiResponseType.actionComplete;

  @override
  void initState() {
    super.initState();

    // Entry animation: scale + fade + slide up from FAB.
    _entryCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    )..forward();

    // Auto-dismiss countdown (action confirmations only).
    _countdownCtrl = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 8),
    );
    if (_isAction) _countdownCtrl.forward();
    _countdownCtrl.addStatusListener((status) {
      if (status == AnimationStatus.completed && !_isDismissing) {
        _dismiss();
      }
    });

    // Breathing glow on the card border.
    _glowCtrl = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 3),
    )..repeat();
  }

  @override
  void dispose() {
    _entryCtrl.dispose();
    _countdownCtrl.dispose();
    _glowCtrl.dispose();
    super.dispose();
  }

  Future<void> _dismiss() async {
    if (_isDismissing) return;
    _isDismissing = true;
    await _entryCtrl.reverse();
    if (mounted) _ctrl.dismissResponsePopup();
  }

  void _expand() {
    _countdownCtrl.stop();
    _ctrl.expandResponsePopup();
  }

  @override
  Widget build(BuildContext context) {
    final text = _ctrl.responsePopupText ?? '';
    final screenWidth = MediaQuery.of(context).size.width;
    final maxWidth = math.min(screenWidth - 32, 320).toDouble();
    final maxLines = _isAction ? 2 : 4;

    // Combined animations: scale, fade, slide.
    final scaleAnim = Tween<double>(
      begin: 0.0,
      end: 1.0,
    ).animate(CurvedAnimation(parent: _entryCtrl, curve: Curves.easeOutBack));
    final fadeAnim = CurvedAnimation(parent: _entryCtrl, curve: Curves.easeOut);
    final slideAnim = Tween<Offset>(
      begin: const Offset(0, 0.3),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _entryCtrl, curve: Curves.easeOutCubic));

    return DefaultTextStyle(
      style: const TextStyle(decoration: TextDecoration.none),
      child: SlideTransition(
        position: slideAnim,
        child: FadeTransition(
          opacity: fadeAnim,
          child: ScaleTransition(
            scale: scaleAnim,
            alignment: Alignment.bottomRight,
            child: Transform.translate(
              offset: Offset(0, _dragY),
              child: Opacity(
                opacity: (1.0 - (_dragY / 150)).clamp(0.3, 1.0),
                child: GestureDetector(
                  onTap: _expand,
                  onVerticalDragUpdate: (d) {
                    if (d.delta.dy > 0 || _dragY > 0) {
                      setState(
                        () => _dragY = (_dragY + d.delta.dy).clamp(0, 200),
                      );
                    }
                  },
                  onVerticalDragEnd: (d) {
                    if (_dragY > 60 || d.velocity.pixelsPerSecond.dy > 300) {
                      _dismiss();
                    } else {
                      setState(() => _dragY = 0);
                    }
                  },
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      maxWidth: maxWidth,
                      minWidth: 160,
                    ),
                    child: _buildCard(text, maxLines),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCard(String text, int maxLines) {
    final accentColor = _isAction ? _green : _accent;

    return AnimatedBuilder(
      animation: _glowCtrl,
      builder: (_, child) {
        final phase = _glowCtrl.value * 2 * math.pi;
        final glowAlpha = 0.08 + 0.06 * math.sin(phase).abs();

        return Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            boxShadow: [
              BoxShadow(
                color: accentColor.withValues(alpha: glowAlpha),
                blurRadius: 20,
                spreadRadius: 1,
              ),
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.4),
                blurRadius: 30,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: child,
        );
      },
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: Container(
          decoration: BoxDecoration(
            color: _bgDeep,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: accentColor.withValues(alpha: 0.2),
              width: 0.5,
            ),
          ),
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Main content row: avatar + text.
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // AI avatar with optional green checkmark for actions.
                  _buildAvatar(accentColor),
                  const SizedBox(width: 10),
                  // Response text.
                  Expanded(
                    child: Text(
                      text,
                      maxLines: maxLines,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: _textH,
                        fontSize: 13.5,
                        height: 1.45,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              // Footer: "Tap to see more" + countdown ring.
              Row(
                children: [
                  const SizedBox(width: 34), // Align with text above avatar.
                  Text(
                    _isAction ? 'Tap to view chat' : 'Tap to see more',
                    style: TextStyle(
                      color: accentColor.withValues(alpha: 0.7),
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const Spacer(),
                  if (_isAction) _buildCountdownRing(),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildAvatar(Color accentColor) {
    return Stack(
      alignment: Alignment.center,
      children: [
        // Base gradient circle.
        Container(
          width: 24,
          height: 24,
          decoration: const BoxDecoration(
            shape: BoxShape.circle,
            gradient: LinearGradient(colors: [_accent, _glow]),
          ),
          child: Icon(
            _isAction ? Icons.check_rounded : Icons.auto_awesome,
            size: 12,
            color: Colors.white,
          ),
        ),
        // Green ring for action confirmations.
        if (_isAction)
          Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(
                color: _green.withValues(alpha: 0.4),
                width: 1.5,
              ),
            ),
          ),
      ],
    );
  }

  /// Circular countdown ring for auto-dismiss timer.
  Widget _buildCountdownRing() {
    return AnimatedBuilder(
      animation: _countdownCtrl,
      builder: (_, _) {
        return SizedBox(
          width: 16,
          height: 16,
          child: CustomPaint(
            painter: _CountdownRingPainter(
              progress: 1.0 - _countdownCtrl.value,
              color: _textD.withValues(alpha: 0.5),
            ),
          ),
        );
      },
    );
  }
}

/// Draws a circular arc that shrinks as the countdown progresses.
class _CountdownRingPainter extends CustomPainter {
  final double progress; // 1.0 = full circle, 0.0 = empty
  final Color color;

  _CountdownRingPainter({required this.progress, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2 - 1;
    final rect = Rect.fromCircle(center: center, radius: radius);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..strokeCap = StrokeCap.round
      ..color = color;

    // Background ring (faint).
    paint.color = color.withValues(alpha: 0.15);
    canvas.drawCircle(center, radius, paint);

    // Progress arc (sweeps from top, clockwise).
    paint.color = color;
    canvas.drawArc(rect, -math.pi / 2, 2 * math.pi * progress, false, paint);
  }

  @override
  bool shouldRepaint(_CountdownRingPainter old) =>
      old.progress != progress || old.color != color;
}
