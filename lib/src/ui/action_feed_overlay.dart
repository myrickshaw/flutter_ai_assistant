import 'package:flutter/material.dart';

import '../core/ai_assistant_controller.dart';
import '../models/action_step.dart';

// Same JARVIS palette as chat_overlay.dart.
const _bgMid = Color(0xFF0A0A20);
const _accent = Color(0xFF7C6AFF);
const _glow = Color(0xFFAE9CFF);
const _cyan = Color(0xFF00E5FF);
const _glassBorder = Color(0x1AFFFFFF);
const _textH = Color(0xFFF2F0FF);
const _textD = Color(0xFF6E6B8A);
const _green = Color(0xFF5AE89E);

/// Futuristic action feed showing progressive AI status with animated visuals.
class ActionFeedOverlay extends StatefulWidget {
  final AiAssistantController controller;
  const ActionFeedOverlay({super.key, required this.controller});

  @override
  State<ActionFeedOverlay> createState() => _ActionFeedOverlayState();
}

class _ActionFeedOverlayState extends State<ActionFeedOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _entryC;

  @override
  void initState() {
    super.initState();
    _entryC = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 500))
      ..forward();
  }

  @override
  void dispose() {
    _entryC.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final curve =
        CurvedAnimation(parent: _entryC, curve: Curves.easeOutCubic);
    return FadeTransition(
      opacity: curve,
      child: SlideTransition(
        position: Tween<Offset>(
                begin: const Offset(0, 0.1), end: Offset.zero)
            .animate(curve),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _avatar(),
              const SizedBox(width: 10),
              Flexible(child: _feedCard()),
              const SizedBox(width: 36),
            ],
          ),
        ),
      ),
    );
  }

  Widget _avatar() => Container(
        width: 28, height: 28,
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

  Widget _feedCard() {
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (_, _) {
        final progressText = widget.controller.progressText;
        final finalText = widget.controller.finalResponseText;
        final steps = widget.controller.actionSteps;
        final done =
            steps.where((s) => s.status == ActionStepStatus.completed).length;
        final total = steps.length;
        final waiting = widget.controller.isWaitingForUserResponse;

        return Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: _bgMid,
            borderRadius: const BorderRadius.only(
              topLeft: Radius.circular(18),
              topRight: Radius.circular(18),
              bottomRight: Radius.circular(18),
              bottomLeft: Radius.circular(4),
            ),
            border: Border.all(color: _glassBorder, width: 0.5),
            boxShadow: [
              BoxShadow(
                  color: _accent.withValues(alpha: 0.06), blurRadius: 24),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (waiting)
                _waitingForUser()
              else
                _status(progressText),
              if (total > 0 && finalText == null && !waiting) ...[
                const SizedBox(height: 10),
                _progressDots(done, total),
              ],
              if (finalText != null) ...[
                const SizedBox(height: 12),
                _done(finalText),
              ],
              if (finalText == null && !waiting) ...[
                const SizedBox(height: 12),
                _shimmerBar(),
              ],
            ],
          ),
        );
      },
    );
  }

  Widget _waitingForUser() {
    return Row(
      children: [
        _PulsingDot(color: _cyan),
        const SizedBox(width: 10),
        const Expanded(
          child: Text(
            'Waiting for your response...',
            style: TextStyle(
              color: _cyan,
              fontSize: 13,
              fontWeight: FontWeight.w500,
              height: 1.4,
            ),
          ),
        ),
      ],
    );
  }

  Widget _status(String? text) {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 350),
      switchInCurve: Curves.easeOut,
      switchOutCurve: Curves.easeIn,
      transitionBuilder: (child, anim) => FadeTransition(
        opacity: anim,
        child: SlideTransition(
          position: Tween<Offset>(
                  begin: const Offset(0, 0.15), end: Offset.zero)
              .animate(anim),
          child: child,
        ),
      ),
      child: Row(
        key: ValueKey(text),
        children: [
          const _PulsingOrb(),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text ?? 'Working on your request...',
              style: const TextStyle(
                color: _textH,
                fontSize: 13,
                fontWeight: FontWeight.w500,
                height: 1.4,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  Widget _progressDots(int done, int total) {
    final show = total > 8 ? 8 : total;
    return Row(
      children: [
        ...List.generate(show, (i) {
          final filled = i < done;
          final current = i == done;
          return AnimatedContainer(
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeOut,
            width: current ? 16 : 6,
            height: 6,
            margin: const EdgeInsets.only(right: 4),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(3),
              color: filled
                  ? _accent
                  : current
                      ? _accent.withValues(alpha: 0.5)
                      : _glassBorder,
            ),
          );
        }),
        if (total > 8)
          Text('+${total - 8}',
              style: TextStyle(
                  color: _textD.withValues(alpha: 0.5), fontSize: 9)),
        const Spacer(),
      ],
    );
  }

  Widget _done(String text) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 400),
      curve: Curves.easeOut,
      builder: (_, v, child) => Opacity(
          opacity: v,
          child: Transform.scale(scale: 0.95 + v * 0.05, child: child)),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: _green.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: _green.withValues(alpha: 0.2)),
        ),
        child: Row(
          children: [
            const Icon(Icons.check_circle, size: 14, color: _green),
            const SizedBox(width: 8),
            Expanded(
              child: Text(text,
                  style: const TextStyle(
                      color: _textH, fontSize: 12, fontWeight: FontWeight.w500),
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis),
            ),
          ],
        ),
      ),
    );
  }

  Widget _shimmerBar() {
    return ClipRRect(
      borderRadius: BorderRadius.circular(3),
      child: SizedBox(
        height: 3,
        child: LinearProgressIndicator(
          backgroundColor: _glassBorder,
          valueColor: const AlwaysStoppedAnimation(_accent),
        ),
      ),
    );
  }
}

/// Pulsing orb with glow — the "heartbeat" of the AI status indicator.
class _PulsingOrb extends StatefulWidget {
  const _PulsingOrb();

  @override
  State<_PulsingOrb> createState() => _PulsingOrbState();
}

class _PulsingOrbState extends State<_PulsingOrb>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 1400))
      ..repeat(reverse: true);
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (_, _) {
        final v = _c.value;
        return Container(
          width: 10, height: 10,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: RadialGradient(colors: [
              _accent.withValues(alpha: 0.5 + v * 0.5),
              _glow.withValues(alpha: 0.2 + v * 0.3),
            ]),
            boxShadow: [
              BoxShadow(
                color: _accent.withValues(alpha: 0.15 + v * 0.3),
                blurRadius: 8 + v * 6,
                spreadRadius: v * 2,
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Pulsing dot — simpler than PulsingOrb, for the "waiting for user" state.
class _PulsingDot extends StatefulWidget {
  final Color color;
  const _PulsingDot({required this.color});

  @override
  State<_PulsingDot> createState() => _PulsingDotState();
}

class _PulsingDotState extends State<_PulsingDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 1000))
      ..repeat(reverse: true);
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (_, _) {
        final v = _c.value;
        return Container(
          width: 10, height: 10,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: widget.color.withValues(alpha: 0.5 + v * 0.5),
            boxShadow: [
              BoxShadow(
                color: widget.color.withValues(alpha: 0.2 + v * 0.3),
                blurRadius: 6 + v * 4,
                spreadRadius: v * 1.5,
              ),
            ],
          ),
        );
      },
    );
  }
}
