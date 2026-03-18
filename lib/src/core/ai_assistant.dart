import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../ui/chat_overlay.dart';
import '../ui/handoff_indicator.dart';
import '../ui/response_popup.dart';
import 'ai_assistant_config.dart';
import 'ai_assistant_controller.dart';

/// InheritedWidget to provide the controller down the tree.
class _AiAssistantScope extends InheritedNotifier<AiAssistantController> {
  const _AiAssistantScope({
    required AiAssistantController controller,
    required super.child,
  }) : super(notifier: controller);
}

/// Drop-in widget that AI-enables any Flutter app.
///
/// Wrap your app's root (or any subtree) with [AiAssistant] to get:
/// - Floating chat button
/// - Chat overlay for text/voice commands
/// - Automatic screen context extraction via Semantics tree
/// - LLM-powered action execution
///
/// ```dart
/// AiAssistant(
///   config: AiAssistantConfig(
///     provider: GeminiProvider(apiKey: 'your-key'),
///   ),
///   child: MaterialApp(...),
/// )
/// ```
class AiAssistant extends StatefulWidget {
  /// Configuration for the AI assistant.
  final AiAssistantConfig config;

  /// The app widget tree to wrap.
  final Widget child;

  const AiAssistant({super.key, required this.config, required this.child});

  /// Access the controller from anywhere in the widget tree.
  static AiAssistantController of(BuildContext context) {
    final scope = context
        .dependOnInheritedWidgetOfExactType<_AiAssistantScope>();
    assert(
      scope != null,
      'AiAssistant.of() called outside of AiAssistant widget tree.',
    );
    return scope!.notifier!;
  }

  /// Access the controller without listening to changes.
  static AiAssistantController read(BuildContext context) {
    final scope = context.getInheritedWidgetOfExactType<_AiAssistantScope>();
    assert(
      scope != null,
      'AiAssistant.read() called outside of AiAssistant widget tree.',
    );
    return scope!.notifier!;
  }

  @override
  State<AiAssistant> createState() => _AiAssistantState();
}

class _AiAssistantState extends State<AiAssistant> {
  late AiAssistantController _controller;

  /// Key for the RepaintBoundary wrapping app content. Used by
  /// [ScreenshotCapture] to capture only the app (not the overlay).
  final _appContentKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    _controller = AiAssistantController(
      config: widget.config,
      appContentKey: _appContentKey,
    );
  }

  @override
  void didUpdateWidget(AiAssistant oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Never recreate the controller during a parent rebuild — doing so
    // disposes the existing controller, resets overlay visibility, and
    // kills any in-progress agent execution. The controller is created
    // once in initState and persists for the widget's lifetime.
    //
    // Typical rebuilds happen when the outer ViewModelBuilder notifies
    // listeners, which creates a fresh AiAssistantConfig with a new
    // provider instance each time. Comparing by identity would always
    // be true, causing the overlay to close mid-conversation.
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return _AiAssistantScope(
      controller: _controller,
      child: Stack(
        children: [
          // The actual app content, wrapped in RepaintBoundary for
          // screenshot capture (only the app, not the AI overlay).
          RepaintBoundary(key: _appContentKey, child: widget.child),

          // Chat overlay / Handoff indicator (shown/hidden by controller state).
          // Wrapped in ExcludeSemantics so the AI doesn't read its own UI
          // when walking the semantics tree.
          ListenableBuilder(
            listenable: _controller,
            builder: (context, _) {
              if (!_controller.isOverlayVisible) return const SizedBox.shrink();

              // In handoff mode, show only the compact floating indicator
              // at the TOP of the screen so the user can see and interact
              // with the full app screen (action buttons are typically at
              // the bottom). Align does NOT block taps in its empty area —
              // only the indicator card itself absorbs touch events.
              if (_controller.isHandoffMode) {
                return Align(
                  alignment: Alignment.topCenter,
                  child: ExcludeSemantics(
                    child: HandoffIndicator(controller: _controller),
                  ),
                );
              }

              // Full-screen overlay — SizedBox.expand guarantees it fills
              // the Stack regardless of layout.
              return SizedBox.expand(
                child: ExcludeSemantics(
                  child: ChatOverlay(controller: _controller),
                ),
              );
            },
          ),

          // FAB + response popup — positioned together so the popup
          // follows the FAB when dragged.
          if (widget.config.showFloatingButton)
            ExcludeSemantics(
              child: _DraggableFabArea(
                controller: _controller,
                config: widget.config,
              ),
            ),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
// Draggable FAB area — positions the FAB + response popup, supports drag-to-
// reposition with horizontal edge-snapping (iOS AssistiveTouch pattern).
// ═══════════════════════════════════════════════════════════════════════════════

/// Size of the FAB button (outer diameter including glow ring).
const _fabSize = 58.0;

/// Horizontal margin from screen edge.
const _fabEdgeMargin = 16.0;

class _DraggableFabArea extends StatefulWidget {
  final AiAssistantController controller;
  final AiAssistantConfig config;

  const _DraggableFabArea({required this.controller, required this.config});

  @override
  State<_DraggableFabArea> createState() => _DraggableFabAreaState();
}

class _DraggableFabAreaState extends State<_DraggableFabArea>
    with SingleTickerProviderStateMixin {
  /// Current FAB center position. Initialized in didChangeDependencies
  /// to default bottom-right.
  Offset? _position;

  /// Whether the FAB is currently being dragged.
  bool _isDragging = false;

  /// Total drag distance — used to distinguish tap from drag.
  double _totalDragDistance = 0;

  /// Animation controller for edge-snap spring animation.
  late final AnimationController _snapCtrl;
  Animation<Offset>? _snapAnimation;

  bool get _draggable => widget.config.fabDraggable;

  @override
  void initState() {
    super.initState();
    _snapCtrl =
        AnimationController(
          vsync: this,
          duration: const Duration(milliseconds: 350),
        )..addListener(() {
          if (_snapAnimation != null) {
            setState(() => _position = _snapAnimation!.value);
          }
        });
  }

  @override
  void dispose() {
    _snapCtrl.dispose();
    super.dispose();
  }

  /// Initialize default position (bottom-right) once we know the screen size.
  Offset _defaultPosition(Size screenSize) {
    return Offset(
      screenSize.width - _fabEdgeMargin - _fabSize / 2,
      screenSize.height -
          widget.config.fabBottomPadding -
          _fabSize / 2 -
          MediaQuery.of(context).padding.bottom,
    );
  }

  void _onPanStart(DragStartDetails _) {
    _snapCtrl.stop();
    _totalDragDistance = 0;
    setState(() => _isDragging = true);
  }

  void _onPanUpdate(DragUpdateDetails details) {
    if (!_draggable) return;
    _totalDragDistance += details.delta.distance;
    final size = MediaQuery.of(context).size;
    final padding = MediaQuery.of(context).padding;
    final half = _fabSize / 2;

    setState(() {
      _position = Offset(
        (_position!.dx + details.delta.dx).clamp(
          half + _fabEdgeMargin,
          size.width - half - _fabEdgeMargin,
        ),
        (_position!.dy + details.delta.dy).clamp(
          half + padding.top + 8,
          size.height - half - padding.bottom - 8,
        ),
      );
    });
  }

  void _onPanEnd(DragEndDetails details) {
    if (!_draggable) return;

    // If total drag distance was tiny, treat it as a tap.
    if (_totalDragDistance < 10) {
      setState(() => _isDragging = false);
      widget.controller.toggleOverlay();
      return;
    }

    final size = MediaQuery.of(context).size;
    final half = _fabSize / 2;

    // Snap to nearest horizontal edge.
    final snapRight = _position!.dx > size.width / 2;
    final targetX = snapRight
        ? size.width - _fabEdgeMargin - half
        : _fabEdgeMargin + half;

    _snapAnimation = Tween<Offset>(
      begin: _position!,
      end: Offset(targetX, _position!.dy),
    ).animate(CurvedAnimation(parent: _snapCtrl, curve: Curves.easeOutCubic));

    _snapCtrl.forward(from: 0);
    setState(() => _isDragging = false);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        if (widget.controller.isOverlayVisible) {
          return const SizedBox.shrink();
        }

        final size = MediaQuery.of(context).size;
        _position ??= _defaultPosition(size);

        final pos = _position!;
        final half = _fabSize / 2;
        final isOnRight = pos.dx > size.width / 2;

        return Stack(
          children: [
            // Response popup — positioned above the FAB.
            if (widget.controller.isResponsePopupVisible)
              Positioned(
                bottom: size.height - pos.dy + half + 8,
                right: isOnRight ? size.width - pos.dx - half : null,
                left: isOnRight ? null : pos.dx - half,
                child: ResponsePopup(controller: widget.controller),
              ),

            // FAB — draggable or static.
            Positioned(
              left: pos.dx - half,
              top: pos.dy - half,
              child: GestureDetector(
                onTap: _draggable ? null : widget.controller.toggleOverlay,
                onPanStart: _draggable ? _onPanStart : null,
                onPanUpdate: _draggable ? _onPanUpdate : null,
                onPanEnd: _draggable ? _onPanEnd : null,
                child: AnimatedScale(
                  scale: _isDragging ? 1.1 : 1.0,
                  duration: const Duration(milliseconds: 150),
                  child: _FloatingAssistantButton(
                    controller: widget.controller,
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

// ─── JARVIS palette (subset for FAB) ────────────────────────────────────────
const _fabAccent = Color(0xFF7C6AFF);
const _fabGlow = Color(0xFFAE9CFF);
const _fabGreen = Color(0xFF5AE89E);

/// JARVIS-themed floating assistant button with:
/// - Gradient background (accent → glow)
/// - Breathing glow shadow
/// - Rotating arc ring during processing
/// - Green dot badge for unread responses
class _FloatingAssistantButton extends StatefulWidget {
  final AiAssistantController controller;
  const _FloatingAssistantButton({required this.controller});

  @override
  State<_FloatingAssistantButton> createState() =>
      _FloatingAssistantButtonState();
}

class _FloatingAssistantButtonState extends State<_FloatingAssistantButton>
    with TickerProviderStateMixin {
  late final AnimationController _glowCtrl;
  late final AnimationController _ringCtrl;

  @override
  void initState() {
    super.initState();
    _glowCtrl = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 3),
    )..repeat();
    _ringCtrl = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat();
  }

  @override
  void dispose() {
    _glowCtrl.dispose();
    _ringCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ctrl = widget.controller;
    return ListenableBuilder(
      listenable: ctrl,
      builder: (_, _) {
        final isProcessing = ctrl.isProcessing;
        final hasUnread = ctrl.hasUnreadResponse;

        return AnimatedBuilder(
          animation: Listenable.merge([_glowCtrl, _ringCtrl]),
          builder: (_, _) {
            final glowPhase = _glowCtrl.value * 2 * math.pi;
            final glowAlpha = 0.25 + 0.15 * math.sin(glowPhase).abs();

            return SizedBox(
              width: 58,
              height: 58,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  // Outer glow shadow
                  Container(
                    width: 58,
                    height: 58,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                          color: _fabAccent.withValues(alpha: glowAlpha),
                          blurRadius: 18,
                          spreadRadius: 2,
                        ),
                      ],
                    ),
                  ),

                  // Rotating arc ring (processing indicator)
                  if (isProcessing)
                    CustomPaint(
                      size: const Size(58, 58),
                      painter: _FabRingPainter(t: _ringCtrl.value),
                    ),

                  // Main button circle
                  Container(
                    width: 50,
                    height: 50,
                    decoration: const BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [_fabAccent, _fabGlow],
                      ),
                    ),
                    child: Center(
                      child: isProcessing
                          ? const SizedBox(
                              width: 22,
                              height: 22,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Icon(
                              Icons.auto_awesome,
                              size: 22,
                              color: Colors.white,
                            ),
                    ),
                  ),

                  // Unread badge (green dot)
                  if (hasUnread)
                    Positioned(
                      right: 2,
                      top: 2,
                      child: Container(
                        width: 14,
                        height: 14,
                        decoration: BoxDecoration(
                          color: _fabGreen,
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white, width: 2),
                          boxShadow: [
                            BoxShadow(
                              color: _fabGreen.withValues(alpha: 0.4),
                              blurRadius: 6,
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            );
          },
        );
      },
    );
  }
}

/// Rotating arc ring painted around the FAB during agent processing.
class _FabRingPainter extends CustomPainter {
  final double t;
  _FabRingPainter({required this.t});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2 - 1;
    final rect = Rect.fromCircle(center: center, radius: radius);
    final startAngle = t * 2 * math.pi;

    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round
      ..color = _fabGlow;

    // Draw a ~130° arc that rotates
    canvas.drawArc(rect, startAngle, math.pi * 0.72, false, paint);

    // Second, fainter arc offset by 180°
    paint.color = _fabAccent.withValues(alpha: 0.4);
    canvas.drawArc(rect, startAngle + math.pi, math.pi * 0.5, false, paint);
  }

  @override
  bool shouldRepaint(_FabRingPainter old) => old.t != t;
}
