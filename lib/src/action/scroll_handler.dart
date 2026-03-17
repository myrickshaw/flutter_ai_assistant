import 'dart:async';

import 'package:flutter/semantics.dart';
import 'package:flutter/widgets.dart';

import '../context/semantics_walker.dart';

/// Handles scrolling to find off-screen elements.
///
/// When the AI tries to tap or interact with an element that isn't
/// currently visible, this handler will scroll the nearest scrollable
/// container to search for it.
class ScrollHandler {
  final SemanticsWalker _walker;

  /// Maximum number of scroll attempts before giving up.
  static const int _maxScrollAttempts = 20;

  /// Delay between scrolls to let animations settle.
  static const Duration _scrollSettleDelay = Duration(milliseconds: 200);

  ScrollHandler({required SemanticsWalker walker}) : _walker = walker;

  /// Scroll to find an element with the given label.
  ///
  /// Tries scrolling down first (most common), then scrolling up if
  /// not found. Returns the [SemanticsNode] if found, null otherwise.
  Future<SemanticsNode?> scrollToFind({
    required String label,
    int maxScrolls = _maxScrollAttempts,
  }) async {
    // First, find the nearest scrollable on screen.
    final context = _walker.captureScreenContext();
    final scrollable = context.firstScrollable;
    if (scrollable == null) return null;

    final scrollableNode = _walker.findNodeById(scrollable.nodeId);
    if (scrollableNode == null) return null;
    final scrollableNodeId = scrollableNode.id;

    // Try scrolling down.
    final downResult = await _scrollAndSearch(
      label: label,
      scrollableNodeId: scrollableNodeId,
      action: SemanticsAction.scrollDown,
      maxScrolls: maxScrolls ~/ 2,
    );
    if (downResult != null) return downResult;

    // Scroll back up to where we started, then try scrolling up.
    final upResult = await _scrollAndSearch(
      label: label,
      scrollableNodeId: scrollableNodeId,
      action: SemanticsAction.scrollUp,
      maxScrolls: maxScrolls ~/ 2,
    );
    return upResult;
  }

  /// Scroll in one direction and search for the element after each scroll.
  Future<SemanticsNode?> _scrollAndSearch({
    required String label,
    required int scrollableNodeId,
    required SemanticsAction action,
    required int maxScrolls,
  }) async {
    final normalizedLabel = label.toLowerCase();
    Set<String>? previousLabels;

    for (int i = 0; i < maxScrolls; i++) {
      // Check if the element is now visible.
      final node = _findInCurrentTree(normalizedLabel);
      if (node != null) return node;

      // Check if scrolling in this direction is still possible.
      var scrollableNode = _walker.findNodeById(scrollableNodeId);
      scrollableNode ??= _resolveFirstScrollableNode();
      if (scrollableNode == null) {
        break;
      }

      final data = scrollableNode.getSemanticsData();
      if (!_hasAction(data.actions, action)) {
        break; // Reached the edge.
      }

      // Perform scroll.
      _performAction(scrollableNode.id, action);
      await _waitForFrame();
      await Future.delayed(_scrollSettleDelay);

      // Content-change detection: if the visible labels haven't changed
      // after scrolling, the list is exhausted — stop early instead of
      // wasting iterations on identical content.
      final context = _walker.captureScreenContext();
      final currentLabels = <String>{
        for (final e in context.elements) e.label.toLowerCase(),
      };
      if (previousLabels != null &&
          currentLabels.length == previousLabels.length &&
          currentLabels.containsAll(previousLabels)) {
        break; // Content unchanged — list exhausted.
      }
      previousLabels = currentLabels;
    }

    return null;
  }

  /// Re-resolve the first available scrollable node from the latest semantics
  /// snapshot. Useful when the widget tree is rebuilt after an action.
  SemanticsNode? _resolveFirstScrollableNode() {
    final context = _walker.captureScreenContext();
    final scrollable = context.firstScrollable;
    if (scrollable == null) return null;
    return _walker.findNodeById(scrollable.nodeId);
  }

  /// Search the current semantics tree for a node matching the label.
  SemanticsNode? _findInCurrentTree(String normalizedLabel) {
    final context = _walker.captureScreenContext();
    for (final element in context.elements) {
      if (element.label.toLowerCase().contains(normalizedLabel)) {
        return _walker.findNodeById(element.nodeId);
      }
      if (element.hint?.toLowerCase().contains(normalizedLabel) ?? false) {
        return _walker.findNodeById(element.nodeId);
      }
    }
    return null;
  }

  bool _hasAction(int actions, SemanticsAction action) {
    return actions & action.index != 0;
  }

  void _performAction(int nodeId, SemanticsAction action) {
    final views = WidgetsBinding.instance.renderViews;
    if (views.isEmpty) return;
    final owner = views.first.owner?.semanticsOwner;
    owner?.performAction(nodeId, action);
  }

  Future<void> _waitForFrame() {
    final completer = Completer<void>();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!completer.isCompleted) completer.complete();
    });
    return completer.future.timeout(
      const Duration(seconds: 5),
      onTimeout: () {
        if (!completer.isCompleted) completer.complete();
      },
    );
  }
}
