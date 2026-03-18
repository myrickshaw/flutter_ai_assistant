import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/ai_assistant_controller.dart';
import 'action_feed_overlay.dart';
import 'chat_bubble.dart';

// ─── JARVIS-inspired dark AI palette ─────────────────────────────────────────
const _bgDeep = Color(0xFF040412);
const _bgMid = Color(0xFF0A0A20);
const _accent = Color(0xFF7C6AFF);
const _accentAlt = Color(0xFF9B8AFF);
const _glow = Color(0xFFAE9CFF);
const _cyan = Color(0xFF00E5FF);
const _textH = Color(0xFFF2F0FF);
const _textB = Color(0xFFB0ADCC);
const _textD = Color(0xFF6E6B8A);
const _glassBorder = Color(0x1AFFFFFF);
const _green = Color(0xFF5AE89E);
const _red = Color(0xFFFF6B8A);

/// Full-screen JARVIS-inspired chat overlay with holographic background,
/// rotating arc rings, floating particles, and glassmorphism effects.
class ChatOverlay extends StatefulWidget {
  final AiAssistantController controller;
  const ChatOverlay({super.key, required this.controller});

  @override
  State<ChatOverlay> createState() => _ChatOverlayState();
}

class _ChatOverlayState extends State<ChatOverlay>
    with TickerProviderStateMixin {
  final _textC = TextEditingController();
  final _scrollC = ScrollController();
  final _focus = FocusNode();

  late final AnimationController _fadeCtrl;
  late final AnimationController _bgCtrl;
  late final AnimationController _ringCtrl;
  late final AnimationController _pulseCtrl;
  late final AnimationController _actionModeCtrl;

  AiAssistantController get _ctrl => widget.controller;

  @override
  void initState() {
    super.initState();
    _fadeCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    )..forward();
    _bgCtrl = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 20),
    )..repeat();
    _ringCtrl = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 10),
    )..repeat();
    _pulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2500),
    )..repeat();
    _actionModeCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    );
    _ctrl.addListener(_onControllerChanged);
  }

  void _onControllerChanged() {
    // Auto-scroll chat to bottom on new messages.
    if (mounted && _scrollC.hasClients) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_scrollC.hasClients) return;
        _scrollC.animateTo(
          _scrollC.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      });
    }

    // Drive action mode animation based on controller state.
    if (_ctrl.isActionMode) {
      _actionModeCtrl.forward();
    } else {
      _actionModeCtrl.reverse();
    }
  }

  @override
  void dispose() {
    _ctrl.removeListener(_onControllerChanged);
    _fadeCtrl.dispose();
    _bgCtrl.dispose();
    _ringCtrl.dispose();
    _pulseCtrl.dispose();
    _actionModeCtrl.dispose();
    _textC.dispose();
    _scrollC.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _send() {
    final t = _textC.text.trim();
    if (t.isEmpty) return;
    _textC.clear();
    _ctrl.sendMessage(t);
  }

  Future<void> _close() async {
    // During any processing (including ask_user), stop the agent first.
    if (_ctrl.isProcessing) {
      _ctrl.requestStop();
    }
    await _fadeCtrl.reverse();
    if (mounted) _ctrl.hideOverlay();
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final kb = mq.viewInsets.bottom;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _close();
      },
      child: FadeTransition(
        opacity: CurvedAnimation(parent: _fadeCtrl, curve: Curves.easeOut),
        child: Material(
          color: Colors.transparent,
          child: SizedBox.expand(
            child: AnimatedBuilder(
              animation: _actionModeCtrl,
              builder: (_, _) {
                final actionT = Curves.easeInOut.transform(
                  _actionModeCtrl.value,
                );
                // In action mode, the background fades out to reveal the app.
                final bgOpacity = 1.0 - actionT;
                // Content slides to the bottom ~40% of the screen.
                final topFraction = actionT * 0.55;

                return Stack(
                  children: [
                    // Holographic background with animated opacity.
                    if (bgOpacity > 0.01)
                      Opacity(
                        opacity: bgOpacity,
                        child: RepaintBoundary(
                          child: AnimatedBuilder(
                            animation: _bgCtrl,
                            builder: (_, _) => CustomPaint(
                              painter: _HoloPainter(
                                _bgCtrl.value,
                                drawEffects: bgOpacity > 0.3,
                              ),
                              size: Size.infinite,
                            ),
                          ),
                        ),
                      ),

                    // Content: slides down in action mode to become a compact
                    // bottom-sheet, letting the user see the app above.
                    Positioned(
                      top: mq.size.height * topFraction,
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: Column(
                        children: [
                          // Semi-transparent scrim behind compact area for readability.
                          if (actionT > 0.01)
                            Container(
                              height: 1,
                              decoration: BoxDecoration(
                                boxShadow: [
                                  BoxShadow(
                                    color: _bgDeep.withValues(
                                      alpha: 0.7 * actionT,
                                    ),
                                    blurRadius: 20,
                                    spreadRadius: 10,
                                    offset: const Offset(0, -8),
                                  ),
                                ],
                              ),
                            ),
                          Expanded(
                            child: ClipRRect(
                              borderRadius: BorderRadius.vertical(
                                top: Radius.circular(20 * actionT),
                              ),
                              child: Container(
                                color: actionT > 0.01
                                    ? _bgDeep.withValues(
                                        alpha: 0.88 + 0.12 * (1 - actionT),
                                      )
                                    : Colors.transparent,
                                padding: EdgeInsets.only(
                                  top: actionT > 0.01 ? 0 : mq.padding.top,
                                  bottom: kb > 0 ? kb : mq.padding.bottom,
                                ),
                                child: Column(
                                  children: [
                                    _header(),
                                    Expanded(child: _messagesArea()),
                                    _inputBar(),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  // ── Header ─────────────────────────────────────────────────────────────────

  Widget _header() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: _bgDeep.withValues(alpha: 0.92),
        border: const Border(
          bottom: BorderSide(color: _glassBorder, width: 0.5),
        ),
      ),
      child: Row(
        children: [
          // Avatar with rotating arc ring.
          SizedBox(
            width: 42,
            height: 42,
            child: AnimatedBuilder(
              animation: _ringCtrl,
              builder: (_, _) => CustomPaint(
                painter: _ArcRingsPainter(
                  t: _ringCtrl.value,
                  ringRadius: 21,
                  ringCount: 2,
                ),
                child: Center(
                  child: Container(
                    width: 34,
                    height: 34,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: const LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [_accent, _glow],
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: _accent.withValues(alpha: 0.3),
                          blurRadius: 12,
                        ),
                      ],
                    ),
                    child: const Icon(
                      Icons.auto_awesome,
                      size: 16,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _ctrl.config.assistantName,
                  style: const TextStyle(
                    color: _textH,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.3,
                  ),
                ),
                const SizedBox(height: 2),
                ListenableBuilder(
                  listenable: _ctrl,
                  builder: (_, _) => _statusRow(),
                ),
              ],
            ),
          ),
          ListenableBuilder(
            listenable: _ctrl,
            builder: (_, _) => _headerActions(),
          ),
        ],
      ),
    );
  }

  Widget _statusRow() {
    final Color dotColor;
    final String label;

    if (_ctrl.isWaitingForUserResponse) {
      dotColor = _cyan;
      label = 'Waiting for you...';
    } else if (_ctrl.isProcessing) {
      dotColor = _accentAlt;
      label = 'Processing...';
    } else {
      dotColor = _green;
      label = 'Ready';
    }

    return Row(
      children: [
        _StatusDot(color: dotColor, animate: _ctrl.isProcessing),
        const SizedBox(width: 5),
        Text(
          label,
          style: TextStyle(
            color: dotColor,
            fontSize: 11,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }

  Widget _headerActions() {
    if (_ctrl.isProcessing && !_ctrl.isWaitingForUserResponse) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _hdrBtn(Icons.stop_rounded, _red, _ctrl.requestStop),
          _hdrBtn(Icons.keyboard_arrow_down_rounded, _textB, _close),
        ],
      );
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (_ctrl.messages.isNotEmpty)
          _hdrBtn(Icons.delete_outline, _textB, _ctrl.clearConversation),
        _hdrBtn(Icons.keyboard_arrow_down_rounded, _textB, _close),
      ],
    );
  }

  Widget _hdrBtn(IconData ic, Color c, VoidCallback? onTap) => IconButton(
    icon: Icon(ic, size: 22),
    color: onTap == null ? _textD.withValues(alpha: 0.3) : c,
    onPressed: onTap,
    visualDensity: VisualDensity.compact,
  );

  // ── Messages ───────────────────────────────────────────────────────────────

  Widget _messagesArea() {
    return ListenableBuilder(
      listenable: _ctrl,
      builder: (_, _) {
        final msgs = _ctrl.messages;
        if (msgs.isEmpty && !_ctrl.isProcessing) return _emptyState();

        return ListView.builder(
          controller: _scrollC,
          padding: const EdgeInsets.symmetric(vertical: 12),
          itemCount: msgs.length + (_ctrl.isProcessing ? 1 : 0),
          itemBuilder: (_, i) {
            if (i == msgs.length) {
              return _ctrl.isActionFeedVisible
                  ? ActionFeedOverlay(controller: _ctrl)
                  : _typing();
            }
            return _MessageEntrance(
              child: ChatBubble(
                message: msgs[i],
                onButtonTap: _ctrl.handleButtonTap,
              ),
            );
          },
        );
      },
    );
  }

  Widget _emptyState() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Central orb with rotating rings and pulse ripples.
          SizedBox(
            width: 130,
            height: 130,
            child: Stack(
              alignment: Alignment.center,
              children: [
                // Pulse ripples expanding outward.
                AnimatedBuilder(
                  animation: _pulseCtrl,
                  builder: (_, _) => CustomPaint(
                    painter: _PulseRipplePainter(
                      t: _pulseCtrl.value,
                      color: _accent,
                      maxRadius: 65,
                    ),
                    size: const Size(130, 130),
                  ),
                ),
                // Arc ring segments rotating.
                AnimatedBuilder(
                  animation: _ringCtrl,
                  builder: (_, _) => CustomPaint(
                    painter: _ArcRingsPainter(
                      t: _ringCtrl.value,
                      ringRadius: 56,
                      ringCount: 3,
                    ),
                    size: const Size(130, 130),
                  ),
                ),
                // Inner glowing orb.
                AnimatedBuilder(
                  animation: _pulseCtrl,
                  builder: (_, _) {
                    final v =
                        (math.sin(_pulseCtrl.value * math.pi * 2) + 1) / 2;
                    return Container(
                      width: 72,
                      height: 72,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: RadialGradient(
                          colors: [
                            _accent.withValues(alpha: 0.25 + v * 0.1),
                            _accent.withValues(alpha: 0.03),
                          ],
                        ),
                        border: Border.all(
                          color: _accent.withValues(alpha: 0.3 + v * 0.15),
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: _accent.withValues(alpha: 0.15 + v * 0.15),
                            blurRadius: 20 + v * 10,
                            spreadRadius: v * 4,
                          ),
                        ],
                      ),
                      child: const Icon(
                        Icons.auto_awesome,
                        size: 30,
                        color: _accentAlt,
                      ),
                    );
                  },
                ),
              ],
            ),
          ),
          const SizedBox(height: 28),
          const Text(
            'How can I help?',
            style: TextStyle(
              color: _textH,
              fontSize: 22,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.5,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'I can navigate, tap, type, and\nperform actions for you.',
            textAlign: TextAlign.center,
            style: TextStyle(color: _textD, fontSize: 13, height: 1.5),
          ),
          const SizedBox(height: 36),
          // Quick suggestion chips (configured by the app developer).
          if (_ctrl.config.initialSuggestions.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 28),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                alignment: WrapAlignment.center,
                children: _ctrl.config.initialSuggestions
                    .map(
                      (chip) => _SuggestionChip(
                        icon: chip.icon,
                        label: chip.label,
                        onTap: () =>
                            _ctrl.sendSuggestion(chip.label, chip.message),
                      ),
                    )
                    .toList(),
              ),
            ),
        ],
      ),
    );
  }

  Widget _typing() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Row(
        children: [
          _miniAvatar(),
          const SizedBox(width: 10),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            decoration: BoxDecoration(
              color: _bgMid,
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(18),
                topRight: Radius.circular(18),
                bottomRight: Radius.circular(18),
                bottomLeft: Radius.circular(4),
              ),
              border: Border.all(color: _glassBorder, width: 0.5),
            ),
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _TypingDot(delay: 0),
                SizedBox(width: 5),
                _TypingDot(delay: 150),
                SizedBox(width: 5),
                _TypingDot(delay: 300),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── Input bar ──────────────────────────────────────────────────────────────

  Widget _inputBar() {
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 10, 10, 10),
      decoration: BoxDecoration(
        color: _bgDeep.withValues(alpha: 0.92),
        border: const Border(top: BorderSide(color: _glassBorder, width: 0.5)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Live partial transcription display.
          ListenableBuilder(
            listenable: _ctrl,
            builder: (_, _) {
              final partial = _ctrl.partialTranscription;
              if (partial == null || partial.isEmpty) {
                return const SizedBox.shrink();
              }
              return Padding(
                padding: const EdgeInsets.only(bottom: 8, left: 8, right: 8),
                child: Row(
                  children: [
                    Icon(
                      Icons.mic,
                      size: 14,
                      color: _red.withValues(alpha: 0.7),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        partial,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: _textB.withValues(alpha: 0.7),
                          fontSize: 13,
                          fontStyle: FontStyle.italic,
                        ),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
          Row(
            children: [
              if (_ctrl.config.voiceEnabled)
                ListenableBuilder(
                  listenable: _ctrl,
                  builder: (_, _) => _circleBtn(
                    _ctrl.isListening ? Icons.mic : Icons.mic_none,
                    _ctrl.isListening ? _red : _textD,
                    (_ctrl.isProcessing && !_ctrl.isWaitingForUserResponse)
                        ? null
                        : _ctrl.toggleVoiceInput,
                  ),
                ),
              const SizedBox(width: 6),
              Expanded(child: _inputField()),
              const SizedBox(width: 6),
              ListenableBuilder(
                listenable: _ctrl,
                builder: (_, _) {
                  if (_ctrl.isProcessing && !_ctrl.isWaitingForUserResponse) {
                    return _stopButton();
                  }
                  return _sendButton();
                },
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _inputField() {
    return ListenableBuilder(
      listenable: Listenable.merge([_ctrl, _focus]),
      builder: (_, _) {
        final waiting = _ctrl.isWaitingForUserResponse;
        final focused = _focus.hasFocus;
        final showGlow = focused || waiting;

        // Always use the same widget structure to avoid reparenting the
        // TextField when focus changes. Switching between Container and
        // AnimatedBuilder caused Flutter to unmount/remount the field,
        // losing focus on the first tap.
        return AnimatedBuilder(
          animation: _ringCtrl,
          builder: (_, child) => Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(26),
              gradient: showGlow
                  ? SweepGradient(
                      colors: const [_accent, _cyan, _accent, _cyan, _accent],
                      transform: GradientRotation(
                        _ringCtrl.value * 2 * math.pi,
                      ),
                    )
                  : null,
              border: showGlow
                  ? null
                  : Border.all(color: _glassBorder, width: 0.5),
              color: showGlow ? null : _bgMid,
            ),
            child: Container(
              margin: showGlow ? const EdgeInsets.all(1.5) : EdgeInsets.zero,
              decoration: BoxDecoration(
                color: _bgMid,
                borderRadius: BorderRadius.circular(showGlow ? 24.5 : 26),
              ),
              child: child,
            ),
          ),
          child: TextField(
            controller: _textC,
            focusNode: _focus,
            textInputAction: TextInputAction.send,
            onSubmitted: (_) => _send(),
            enabled: !_ctrl.isProcessing || _ctrl.isWaitingForUserResponse,
            style: const TextStyle(color: _textH, fontSize: 14),
            cursorColor: _cyan,
            decoration: InputDecoration(
              hintText: waiting
                  ? 'Type your response...'
                  : 'Ask me to do something...',
              hintStyle: TextStyle(
                color: waiting
                    ? _cyan.withValues(alpha: 0.5)
                    : _textD.withValues(alpha: 0.6),
                fontSize: 14,
              ),
              border: InputBorder.none,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 18,
                vertical: 12,
              ),
              isDense: true,
            ),
          ),
        );
      },
    );
  }

  Widget _sendButton() {
    return GestureDetector(
      onTap: _send,
      child: Container(
        width: 42,
        height: 42,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [_accent, _glow],
          ),
          boxShadow: [
            BoxShadow(
              color: _accent.withValues(alpha: 0.35),
              blurRadius: 10,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: const Icon(
          Icons.arrow_upward_rounded,
          size: 20,
          color: Colors.white,
        ),
      ),
    );
  }

  Widget _stopButton() {
    return GestureDetector(
      onTap: _ctrl.requestStop,
      child: Container(
        width: 42,
        height: 42,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: _red.withValues(alpha: 0.15),
          border: Border.all(color: _red.withValues(alpha: 0.3)),
        ),
        child: Icon(
          Icons.stop_rounded,
          size: 20,
          color: _red.withValues(alpha: 0.8),
        ),
      ),
    );
  }

  Widget _circleBtn(IconData ic, Color c, VoidCallback? onTap) =>
      GestureDetector(
        onTap: onTap,
        child: Container(
          width: 38,
          height: 38,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: _bgMid,
            border: Border.all(color: _glassBorder, width: 0.5),
          ),
          child: Icon(
            ic,
            size: 20,
            color: onTap == null ? c.withValues(alpha: 0.3) : c,
          ),
        ),
      );

  static Widget _miniAvatar() => Container(
    width: 28,
    height: 28,
    decoration: const BoxDecoration(
      shape: BoxShape.circle,
      gradient: LinearGradient(colors: [_accent, _glow]),
    ),
    child: const Icon(Icons.auto_awesome, size: 12, color: Colors.white),
  );
}

// ═══════════════════════════════════════════════════════════════════════════════
// Status dot with pulse animation.
// ═══════════════════════════════════════════════════════════════════════════════

class _StatusDot extends StatefulWidget {
  final Color color;
  final bool animate;
  const _StatusDot({required this.color, this.animate = false});

  @override
  State<_StatusDot> createState() => _StatusDotState();
}

class _StatusDotState extends State<_StatusDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    );
    if (widget.animate) _c.repeat(reverse: true);
  }

  @override
  void didUpdateWidget(_StatusDot old) {
    super.didUpdateWidget(old);
    if (widget.animate && !_c.isAnimating) {
      _c.repeat(reverse: true);
    } else if (!widget.animate && _c.isAnimating) {
      _c.stop();
      _c.value = 0;
    }
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
          width: 6,
          height: 6,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: widget.color,
            boxShadow: widget.animate
                ? [
                    BoxShadow(
                      color: widget.color.withValues(alpha: 0.3 + v * 0.4),
                      blurRadius: 4 + v * 4,
                      spreadRadius: v * 2,
                    ),
                  ]
                : null,
          ),
        );
      },
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
// Holographic background: grid + particles + scan line (CustomPainter).
// ═══════════════════════════════════════════════════════════════════════════════

class _HoloPainter extends CustomPainter {
  final double t;

  /// When false, skip grid/particles/scanline for performance (used when
  /// the background is mostly transparent during action mode).
  final bool drawEffects;
  _HoloPainter(this.t, {this.drawEffects = true});

  static final _rngGrid = math.Random(7);
  static final _gridGlowPoints = List.generate(
    15,
    (_) => [_rngGrid.nextDouble(), _rngGrid.nextDouble()],
  );

  @override
  void paint(Canvas canvas, Size size) {
    // Solid deep background.
    canvas.drawRect(Offset.zero & size, Paint()..color = _bgDeep);

    // Subtle radial gradient glow in upper area.
    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..shader = RadialGradient(
          center: const Alignment(0, -0.3),
          radius: 1.2,
          colors: [
            const Color(0xFF0D0D28).withValues(alpha: 0.6),
            Colors.transparent,
          ],
        ).createShader(Offset.zero & size),
    );

    if (drawEffects) {
      _drawGrid(canvas, size);
      _drawParticles(canvas, size);
      _drawScanLine(canvas, size);
    }
  }

  void _drawGrid(Canvas canvas, Size size) {
    const spacing = 50.0;
    final paint = Paint()
      ..color = _cyan.withValues(alpha: 0.015)
      ..strokeWidth = 0.5;

    for (double x = 0; x < size.width; x += spacing) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    }
    for (double y = 0; y < size.height; y += spacing) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }

    // Glow dots at select grid intersections.
    final glowPaint = Paint()..color = _cyan.withValues(alpha: 0.06);
    for (final pt in _gridGlowPoints) {
      final ix = (pt[0] * (size.width / spacing)).floor() * spacing;
      final iy = (pt[1] * (size.height / spacing)).floor() * spacing;
      canvas.drawCircle(Offset(ix, iy), 2.0, glowPaint);
    }
  }

  void _drawParticles(Canvas canvas, Size size) {
    final rng = math.Random(42);
    for (int i = 0; i < 28; i++) {
      final baseX = rng.nextDouble() * size.width;
      final baseY = rng.nextDouble() * size.height;
      final speed = 0.2 + rng.nextDouble() * 0.8;
      final phase = rng.nextDouble() * math.pi * 2;

      final x = baseX + math.sin(t * speed * math.pi * 2 + phase) * 30;
      final y = baseY + math.cos(t * speed * math.pi * 2 * 0.7 + phase) * 20;
      final opacity =
          0.12 + math.sin(t * math.pi * 2 * speed + phase).abs() * 0.2;
      final radius = 1.0 + rng.nextDouble() * 2.0;
      final color = i % 3 == 0 ? _cyan : _accent;

      final pos = Offset(x % size.width, y % size.height);
      canvas.drawCircle(
        pos,
        radius,
        Paint()..color = color.withValues(alpha: opacity),
      );

      // Glow halo for larger particles.
      if (radius > 1.8) {
        canvas.drawCircle(
          pos,
          radius * 3.5,
          Paint()..color = color.withValues(alpha: opacity * 0.12),
        );
      }
    }
  }

  void _drawScanLine(Canvas canvas, Size size) {
    final scanPhase = (t * 3) % 1.0;
    final scanY = scanPhase * (size.height + 80) - 40;

    canvas.drawRect(
      Rect.fromLTWH(0, scanY, size.width, 40),
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Colors.transparent,
            _cyan.withValues(alpha: 0.035),
            Colors.transparent,
          ],
        ).createShader(Rect.fromLTWH(0, scanY, size.width, 40)),
    );
  }

  @override
  bool shouldRepaint(_HoloPainter old) => true;
}

// ═══════════════════════════════════════════════════════════════════════════════
// Rotating segmented arc rings around the avatar.
// ═══════════════════════════════════════════════════════════════════════════════

class _ArcRingsPainter extends CustomPainter {
  final double t;
  final double ringRadius;
  final int ringCount;

  _ArcRingsPainter({
    required this.t,
    required this.ringRadius,
    this.ringCount = 3,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);

    // [radiusOffset, speed, color, segments, opacity, strokeWidth]
    final configs = <List<Object>>[
      [0.0, 1.0, _cyan, 3, 0.3, 1.2],
      [-7.0, -0.7, _accent, 4, 0.45, 1.5],
      if (ringCount >= 3) [-14.0, 0.4, _glow, 2, 0.2, 1.0],
    ];

    for (final c in configs) {
      final radius = ringRadius + (c[0] as double);
      final speed = c[1] as double;
      final color = c[2] as Color;
      final segments = c[3] as int;
      final opacity = c[4] as double;
      final strokeW = c[5] as double;

      final paint = Paint()
        ..color = color.withValues(alpha: opacity)
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeW
        ..strokeCap = StrokeCap.round;

      final segArc = math.pi / (segments * 1.5);
      final gapArc = (2 * math.pi - segArc * segments) / segments;

      for (int i = 0; i < segments; i++) {
        final start = t * speed * 2 * math.pi + i * (segArc + gapArc);
        canvas.drawArc(
          Rect.fromCircle(center: center, radius: radius),
          start,
          segArc,
          false,
          paint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_ArcRingsPainter old) => old.t != t;
}

// ═══════════════════════════════════════════════════════════════════════════════
// Pulse ripple — expanding circles from center.
// ═══════════════════════════════════════════════════════════════════════════════

class _PulseRipplePainter extends CustomPainter {
  final double t;
  final Color color;
  final double maxRadius;

  _PulseRipplePainter({
    required this.t,
    required this.color,
    required this.maxRadius,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);

    for (int i = 0; i < 2; i++) {
      final phase = (t + i * 0.5) % 1.0;
      final radius = phase * maxRadius;
      final opacity = (1.0 - phase) * 0.12;

      canvas.drawCircle(
        center,
        radius,
        Paint()
          ..color = color.withValues(alpha: opacity)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5,
      );
    }
  }

  @override
  bool shouldRepaint(_PulseRipplePainter old) => old.t != t;
}

// ═══════════════════════════════════════════════════════════════════════════════
// Message entrance animation — scale + fade.
// ═══════════════════════════════════════════════════════════════════════════════

class _MessageEntrance extends StatefulWidget {
  final Widget child;
  const _MessageEntrance({required this.child});

  @override
  State<_MessageEntrance> createState() => _MessageEntranceState();
}

class _MessageEntranceState extends State<_MessageEntrance>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 350),
    )..forward();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final curve = CurvedAnimation(parent: _c, curve: Curves.easeOutBack);
    return FadeTransition(
      opacity: curve,
      child: ScaleTransition(
        scale: Tween<double>(begin: 0.92, end: 1.0).animate(curve),
        alignment: Alignment.bottomLeft,
        child: widget.child,
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
// Typing indicator dots.
// ═══════════════════════════════════════════════════════════════════════════════

class _TypingDot extends StatefulWidget {
  final int delay;
  const _TypingDot({required this.delay});

  @override
  State<_TypingDot> createState() => _TypingDotState();
}

class _TypingDotState extends State<_TypingDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    Future.delayed(Duration(milliseconds: widget.delay), () {
      if (mounted) _c.repeat(reverse: true);
    });
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
      builder: (_, _) => Transform.translate(
        offset: Offset(0, -3 * _c.value),
        child: Opacity(
          opacity: 0.3 + _c.value * 0.7,
          child: Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: const LinearGradient(colors: [_accent, _glow]),
              boxShadow: [
                BoxShadow(color: _accent.withValues(alpha: 0.3), blurRadius: 4),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
// Suggestion chip for empty state.
// ═══════════════════════════════════════════════════════════════════════════════

class _SuggestionChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _SuggestionChip({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: _accent.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: _accent.withValues(alpha: 0.2)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: _accentAlt),
            const SizedBox(width: 6),
            Text(
              label,
              style: const TextStyle(
                color: _textB,
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
