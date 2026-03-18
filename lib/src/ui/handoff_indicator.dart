import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/ai_assistant_controller.dart';

// ─── Reuse the JARVIS palette from chat_overlay ─────────────────────────────
const _bgDeep = Color(0xFF040412);
const _accent = Color(0xFF7C6AFF);
const _glow = Color(0xFFAE9CFF);
const _textB = Color(0xFFB0ADCC);
const _textD = Color(0xFF6E6B8A);
const _green = Color(0xFF5AE89E);
const _red = Color(0xFFFF6B8A);

/// Compact floating indicator shown at the TOP of the screen during handoff.
///
/// When the agent has completed all preparatory steps and the final action
/// button is on screen, this indicator tells the user which button to tap.
/// Positioned at the top so it NEVER covers bottom action buttons
/// (Book Ride, Place Order, Pay, etc.).
///
/// Resolution paths:
/// - Auto: route change detected (user tapped the button → app navigated)
/// - Manual: user taps "Done" checkmark (fallback for same-screen confirmations)
/// - Cancel: user taps "X" to abort
class HandoffIndicator extends StatefulWidget {
  final AiAssistantController controller;

  const HandoffIndicator({super.key, required this.controller});

  @override
  State<HandoffIndicator> createState() => _HandoffIndicatorState();
}

class _HandoffIndicatorState extends State<HandoffIndicator>
    with TickerProviderStateMixin {
  late final AnimationController _slideCtrl;
  late final AnimationController _glowCtrl;
  late final AnimationController _arrowCtrl;

  @override
  void initState() {
    super.initState();
    // Slide down from top with spring-like overshoot.
    _slideCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 500),
    )..forward();
    // Breathing green border glow.
    _glowCtrl = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 3),
    )..repeat();
    // Cascading down-arrows that guide the eye toward the app.
    _arrowCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2000),
    )..repeat();
  }

  @override
  void dispose() {
    _slideCtrl.dispose();
    _glowCtrl.dispose();
    _arrowCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final buttonLabel = widget.controller.handoffButtonLabel ?? 'Confirm';
    final summary = widget.controller.handoffSummary ?? '';

    return SafeArea(
      bottom: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
        child: SlideTransition(
          position:
              Tween<Offset>(
                begin: const Offset(0, -1.5),
                end: Offset.zero,
              ).animate(
                CurvedAnimation(parent: _slideCtrl, curve: Curves.easeOutBack),
              ),
          child: FadeTransition(
            opacity: CurvedAnimation(parent: _slideCtrl, curve: Curves.easeOut),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _buildCard(buttonLabel, summary),
                const SizedBox(height: 2),
                _buildCascadingArrows(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ── Card ──────────────────────────────────────────────────────────────────

  Widget _buildCard(String buttonLabel, String summary) {
    return AnimatedBuilder(
      animation: _glowCtrl,
      builder: (_, child) {
        final phase = _glowCtrl.value * 2 * math.pi;
        return Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            boxShadow: [
              BoxShadow(
                color: _green.withValues(
                  alpha: 0.10 + 0.08 * math.sin(phase).abs(),
                ),
                blurRadius: 20,
                spreadRadius: 1,
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
            border: Border.all(color: _green.withValues(alpha: 0.25), width: 1),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          // DefaultTextStyle removes the yellow underline that appears when
          // text is rendered outside a Material/Scaffold ancestor.
          child: DefaultTextStyle(
            style: const TextStyle(decoration: TextDecoration.none),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Row 1: AI icon + CTA + Cancel/Done buttons
                Row(
                  children: [
                    // Gradient AI avatar
                    Container(
                      width: 30,
                      height: 30,
                      decoration: const BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: LinearGradient(colors: [_accent, _glow]),
                      ),
                      child: const Icon(
                        Icons.auto_awesome,
                        size: 14,
                        color: Colors.white,
                      ),
                    ),
                    const SizedBox(width: 10),
                    // CTA: Tap "Book Ride" to confirm
                    Expanded(
                      child: RichText(
                        text: TextSpan(
                          style: const TextStyle(
                            color: _textB,
                            fontSize: 14,
                            height: 1.3,
                          ),
                          children: [
                            const TextSpan(text: 'Tap '),
                            TextSpan(
                              text: '"$buttonLabel"',
                              style: const TextStyle(
                                color: _green,
                                fontWeight: FontWeight.w700,
                                fontSize: 15,
                              ),
                            ),
                            const TextSpan(text: ' to confirm'),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    // Cancel (red circle) — stops agent and closes overlay.
                    _CircleIconButton(
                      icon: Icons.close_rounded,
                      color: _red,
                      onTap: widget.controller.requestStop,
                    ),
                    const SizedBox(width: 6),
                    // Done (green circle, filled)
                    _CircleIconButton(
                      icon: Icons.check_rounded,
                      color: _green,
                      filled: true,
                      onTap: widget.controller.resolveHandoff,
                    ),
                  ],
                ),
                // Row 2: Summary (indented to align with CTA text)
                if (summary.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(left: 40, top: 4),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        summary,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: _textD,
                          fontSize: 12,
                          height: 1.3,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ── Cascading down-arrows ─────────────────────────────────────────────────
  //
  // Three chevrons stacked vertically with staggered opacity animation,
  // creating a "flowing down" effect that guides the user's eye toward
  // the app's action button below.

  Widget _buildCascadingArrows() {
    return AnimatedBuilder(
      animation: _arrowCtrl,
      builder: (_, _) {
        return SizedBox(
          height: 36,
          child: Stack(
            alignment: Alignment.topCenter,
            children: List.generate(3, (i) {
              // Each arrow peaks at a staggered time in the animation cycle.
              final peakT = 0.15 + i * 0.2;
              final dist = ((_arrowCtrl.value - peakT) % 1.0);
              // Sine curve for smooth in-out, clamped to a narrow window.
              final alpha = (math.sin(dist.clamp(0.0, 0.5) * math.pi) * 0.55)
                  .clamp(0.05, 0.55);
              return Positioned(
                top: i * 10.0,
                child: Icon(
                  Icons.keyboard_arrow_down_rounded,
                  size: 20,
                  color: _green.withValues(alpha: alpha),
                ),
              );
            }),
          ),
        );
      },
    );
  }
}

/// Small circular icon button used for Cancel/Done in the handoff card.
class _CircleIconButton extends StatelessWidget {
  final IconData icon;
  final Color color;
  final bool filled;
  final VoidCallback onTap;

  const _CircleIconButton({
    required this.icon,
    required this.color,
    this.filled = false,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 32,
        height: 32,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: filled ? color.withValues(alpha: 0.15) : Colors.transparent,
          border: Border.all(
            color: color.withValues(alpha: filled ? 0.4 : 0.2),
            width: 1,
          ),
        ),
        child: Icon(icon, size: 16, color: color),
      ),
    );
  }
}
