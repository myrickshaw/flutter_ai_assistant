import 'dart:async';

import 'package:flutter/semantics.dart';
import 'package:flutter/widgets.dart';

import '../context/semantics_walker.dart';
import '../core/ai_logger.dart';
import '../models/ui_element.dart';
import '../tools/tool_result.dart';
import 'scroll_handler.dart';

/// Executes actions on the live Flutter UI via the Semantics tree.
///
/// This is the bridge between what the LLM decides to do (tool calls) and
/// the actual UI interactions. All actions are performed through
/// [SemanticsOwner.performAction], which triggers the same callbacks as
/// real user interactions (taps, text input, scrolling, etc.).
class ActionExecutor {
  final SemanticsWalker _walker;
  final ScrollHandler _scrollHandler;

  /// Optional callback for custom route navigation.
  /// If provided, used by [navigateToRoute] instead of Navigator.
  final Future<void> Function(String routeName)? onNavigateToRoute;

  /// Global navigator key for fallback navigation.
  final GlobalKey<NavigatorState>? navigatorKey;

  /// Navigator observer whose [NavigatorObserver.navigator] provides
  /// a fallback [NavigatorState] when no explicit key or callback is given.
  final NavigatorObserver? _navigatorObserver;

  /// Known route names in the app (e.g., ["/home", "/settings"]).
  /// Used to resolve fuzzy route names from the LLM to exact matches.
  final List<String> _knownRoutes;

  ActionExecutor({
    required SemanticsWalker walker,
    this.onNavigateToRoute,
    this.navigatorKey,
    NavigatorObserver? navigatorObserver,
    List<String> knownRoutes = const [],
  }) : _walker = walker,
       _navigatorObserver = navigatorObserver,
       _knownRoutes = knownRoutes,
       _scrollHandler = ScrollHandler(walker: walker);

  /// Resolve the best available [NavigatorState]:
  /// 1. Explicit [navigatorKey]
  /// 2. [NavigatorObserver.navigator] (auto-set when observer is attached)
  NavigatorState? get _navigator =>
      navigatorKey?.currentState ?? _navigatorObserver?.navigator;

  /// Tap an element identified by its label text.
  ///
  /// Uses [parentContext] to disambiguate when multiple elements share
  /// the same label (e.g., multiple "Add" buttons in a product list).
  Future<ToolResult> tapElement(String label, {String? parentContext}) async {
    AiLogger.log(
      'tapElement: "$label" (parentContext=$parentContext)',
      tag: 'Action',
    );
    final node = _findNode(label, parentContext: parentContext);
    if (node == null) {
      // Try scrolling to find the element.
      final scrollResult = await _scrollHandler.scrollToFind(label: label);
      if (scrollResult == null) {
        return ToolResult.fail(
          "Element '$label' not found on screen. "
          'Try scrolling or navigating to a different screen.',
        );
      }
      return _performTap(scrollResult, label);
    }
    return _performTap(node, label);
  }

  Future<ToolResult> _performTap(SemanticsNode node, String label) async {
    var data = node.getSemanticsData();
    if (!data.actions.containsAction(SemanticsAction.tap)) {
      // Walk up parent chain to find a tappable ancestor (max 5 levels).
      // Common pattern: Text label is a child of an InkWell/GestureDetector
      // whose semantics node holds the tap action.
      SemanticsNode? current = node.parent;
      SemanticsNode? tappableAncestor;
      for (int depth = 0; depth < 5 && current != null; depth++) {
        final parentData = current.getSemanticsData();
        if (parentData.actions.containsAction(SemanticsAction.tap)) {
          tappableAncestor = current;
          AiLogger.log(
            '_performTap: "$label" not tappable, found tappable ancestor '
            'at depth ${depth + 1} (node ${current.id})',
            tag: 'Action',
          );
          break;
        }
        current = current.parent;
      }
      if (tappableAncestor == null) {
        return ToolResult.fail("Element '$label' is not tappable.");
      }
      node = tappableAncestor;
    }

    // Capture element labels before tap for change detection.
    final beforeContext = _walker.captureScreenContext();
    final beforeLabels = <String>{
      for (final e in beforeContext.elements) e.label.toLowerCase(),
    };

    _performAction(node.id, SemanticsAction.tap);
    await _waitForFrame();

    // Flash capture immediately after tap to catch transient feedback
    // (snackbars, toasts) before they disappear.
    final flashContext = _walker.captureScreenContext();

    // Extra settle time for UI state changes (dialogs, animations, network loads).
    await Future.delayed(const Duration(milliseconds: 300));

    // Re-capture after settle to detect screen changes.
    // Compare label sets, not just counts — catches in-place content changes,
    // modals that replace elements, and other mutations that keep the count stable.
    final afterContext = _walker.captureScreenContext();
    final afterLabels = <String>{
      for (final e in afterContext.elements) e.label.toLowerCase(),
    };
    final addedLabels = afterLabels.difference(beforeLabels);
    final removedLabels = beforeLabels.difference(afterLabels);
    final screenChanged = addedLabels.length + removedLabels.length > 1;

    // Extract transient feedback from both flash and settled snapshots.
    final transientFeedback = _extractTransientFeedback(
      flashContext, beforeContext, afterContext,
    );

    final result = <String, dynamic>{'tapped': label, 'screenChanged': screenChanged};
    if (!screenChanged) {
      result['hint'] = 'Screen appears unchanged — element may be disabled or the action had no visible effect.';
    }
    if (transientFeedback != null) {
      result['feedback'] = transientFeedback;
    }
    return ToolResult.ok(result);
  }

  /// Extract transient feedback (snackbar/toast messages) by comparing
  /// screen state before and after an action.
  ///
  /// Also captures from the post-settle snapshot to catch feedback that
  /// appears with a slight delay (network confirmations, animated toasts).
  String? _extractTransientFeedback(
    dynamic flashContext,
    dynamic beforeContext, [
    dynamic settledContext,
  ]) {
    try {
      final beforeLabels = <String>{};
      for (final e in (beforeContext as dynamic).elements) {
        beforeLabels.add((e.label as String).toLowerCase());
      }

      const transientKeywords = [
        'added', 'removed', 'success', 'error', 'failed', 'deleted',
        'updated', 'saved', 'confirmed', 'cancelled', 'cart',
      ];

      // Check both the flash capture (immediate) and settled capture (delayed).
      final snapshots = [flashContext, ?settledContext];
      for (final snapshot in snapshots) {
        for (final e in (snapshot as dynamic).elements) {
          final label = e.label as String;
          final lower = label.toLowerCase();
          if (beforeLabels.contains(lower)) continue; // Not new.
          if (transientKeywords.any((k) => lower.contains(k))) {
            AiLogger.log('Transient feedback captured: "$label"', tag: 'Action');
            return label;
          }
        }
      }
    } catch (e) {
      AiLogger.warn('Transient feedback extraction failed: $e', tag: 'Action');
    }
    return null;
  }

  /// Enter text into a text field identified by its label or hint.
  Future<ToolResult> setText(
    String label,
    String text, {
    String? parentContext,
  }) async {
    AiLogger.log('setText: "$label" = "$text"', tag: 'Action');
    final node = _findNode(
      label,
      parentContext: parentContext,
      preferType: UiElementType.textField,
    );
    if (node == null) {
      return ToolResult.fail("Text field '$label' not found on screen.");
    }

    final data = node.getSemanticsData();
    if (!data.actions.containsAction(SemanticsAction.setText)) {
      // Try tapping first to focus, then set text.
      if (data.actions.containsAction(SemanticsAction.tap)) {
        _performAction(node.id, SemanticsAction.tap);
        await _waitForFrame();
        // Extra settle for screen transitions (e.g. tapping a search container
        // that opens a new search screen with a real TextField).
        await Future.delayed(const Duration(milliseconds: 500));
      }

      // Retry on the SAME node (handles simple focus-to-activate fields).
      final retryData = node.getSemanticsData();
      if (retryData.actions.containsAction(SemanticsAction.setText)) {
        _performSetText(node.id, text);
        await _waitForFrame();
        return ToolResult.ok({'setText': label, 'value': text});
      }

      // The tap may have opened a NEW screen with a real TextField
      // (common pattern: tappable "Search" container opens a search screen).
      // Look for a TextField that appeared after the tap.
      final newNode = _findNode(
        label,
        parentContext: parentContext,
        preferType: UiElementType.textField,
      );
      if (newNode != null && newNode.id != node.id) {
        final newData = newNode.getSemanticsData();
        if (newData.actions.containsAction(SemanticsAction.setText)) {
          _performSetText(newNode.id, text);
          await _waitForFrame();
          return ToolResult.ok({'setText': label, 'value': text});
        }
      }

      // Last resort: find ANY focused/editable text field on screen.
      final anyTextField = _findAnyTextField();
      if (anyTextField != null) {
        _performSetText(anyTextField.id, text);
        await _waitForFrame();
        return ToolResult.ok({'setText': label, 'value': text});
      }

      return ToolResult.fail(
        "Cannot enter text in '$label'. It may not be a text field. "
        'Try tapping it first with tap_element, then use set_text.',
      );
    }

    _performSetText(node.id, text);
    await _waitForFrame();
    return ToolResult.ok({'setText': label, 'value': text});
  }

  /// Scroll the current scrollable area in the given direction.
  Future<ToolResult> scroll(String direction) async {
    final context = _walker.captureScreenContext();
    final scrollable = context.firstScrollable;

    if (scrollable == null) {
      return ToolResult.fail('No scrollable area found on the current screen.');
    }

    final action = switch (direction.toLowerCase()) {
      'up' => SemanticsAction.scrollUp,
      'down' => SemanticsAction.scrollDown,
      'left' => SemanticsAction.scrollLeft,
      'right' => SemanticsAction.scrollRight,
      _ => null,
    };

    if (action == null) {
      return ToolResult.fail(
        "Invalid scroll direction: '$direction'. Use up, down, left, or right.",
      );
    }

    final node = _walker.findNodeById(scrollable.nodeId);
    if (node == null) {
      return ToolResult.fail('Scrollable element no longer available.');
    }

    final data = node.getSemanticsData();
    if (!data.actions.containsAction(action)) {
      return ToolResult.fail("Cannot scroll $direction — already at the edge.");
    }

    _performAction(node.id, action);
    await _waitForFrame();
    // Extra wait for scroll animation and content loading to settle.
    await Future.delayed(const Duration(milliseconds: 250));
    return ToolResult.ok({'scrolled': direction});
  }

  /// Navigate to a named route.
  ///
  /// The LLM may provide route names without a leading `/` or with
  /// incorrect casing. [_resolveRouteName] normalizes the input before
  /// navigating to avoid common mismatches.
  Future<ToolResult> navigateToRoute(String routeName) async {
    final resolved = _resolveRouteName(routeName);
    AiLogger.log(
      'navigateToRoute: "$routeName" -> resolved="$resolved"',
      tag: 'Action',
    );

    // If the resolved route wasn't found in known routes, fail fast with
    // a suggestion instead of attempting navigation that will crash.
    if (_knownRoutes.isNotEmpty && !_knownRoutes.contains(resolved)) {
      final suggestion = _findClosestRoute(resolved);
      return ToolResult.fail(
        "Route '$resolved' is not a known route. "
        'Available routes: ${_knownRoutes.join(', ')}'
        '${suggestion != null ? '. Did you mean "$suggestion"?' : '.'}',
      );
    }

    // Priority 1: developer-provided navigation callback.
    if (onNavigateToRoute != null) {
      try {
        await onNavigateToRoute!(resolved);
        await _waitForFrame();
        // Extra settle time for route transition animations and content loading.
        await Future.delayed(const Duration(milliseconds: 500));
        return ToolResult.ok({'navigatedTo': resolved});
      } catch (e) {
        return ToolResult.fail(
          "Navigation to '$resolved' failed: $e. "
          '${_knownRoutes.isNotEmpty ? 'Available routes: ${_knownRoutes.join(', ')}' : ''}',
        );
      }
    }

    // Priority 2: NavigatorState from key or observer.
    final navigator = _navigator;
    if (navigator != null) {
      try {
        // Do NOT await pushNamed — it returns a Future that resolves when the
        // route is POPPED, not pushed. Awaiting would block the agent forever.
        unawaited(navigator.pushNamed(resolved));
        await _waitForFrame();
        // Extra settle time for route transition animations and content loading.
        await Future.delayed(const Duration(milliseconds: 500));
        return ToolResult.ok({'navigatedTo': resolved});
      } catch (e) {
        return ToolResult.fail(
          "Navigation to '$resolved' failed: $e. "
          '${_knownRoutes.isNotEmpty ? 'Available routes: ${_knownRoutes.join(', ')}' : ''}',
        );
      }
    }

    return ToolResult.fail(
      "Cannot navigate: no navigation handler or navigator key configured. "
      "Add the navigatorObserver to your MaterialApp's navigatorObservers list.",
    );
  }

  /// Resolve a route name from the LLM to the actual registered route.
  ///
  /// The LLM frequently strips the leading `/` or uses inconsistent casing.
  /// This method tries progressively looser matching:
  /// 1. Exact match (e.g., "/settings" → "/settings")
  /// 2. Add `/` prefix (e.g., "settings" → "/settings")
  /// 3. Case-insensitive match (e.g., "Settings" → "/settings")
  /// 4. Fallback: ensure `/` prefix and return as-is.
  String _resolveRouteName(String input) {
    // 1. Exact match.
    if (_knownRoutes.contains(input)) return input;

    // 2. Add leading `/` and check.
    final withSlash = input.startsWith('/') ? input : '/$input';
    if (_knownRoutes.contains(withSlash)) return withSlash;

    // 3. Case-insensitive match.
    final lowerInput = withSlash.toLowerCase();
    for (final route in _knownRoutes) {
      if (route.toLowerCase() == lowerInput) return route;
    }

    // 4. Fallback: return with `/` prefix but warn.
    AiLogger.warn(
      'Route "$input" not found in known routes, using "$withSlash"',
      tag: 'Action',
    );
    return withSlash;
  }

  /// Find the closest known route to [input] using simple substring overlap.
  /// Returns null if no reasonable match exists.
  String? _findClosestRoute(String input) {
    if (_knownRoutes.isEmpty) return null;
    final lower = input.replaceAll('/', '').toLowerCase();
    String? best;
    int bestScore = 0;
    for (final route in _knownRoutes) {
      final routeLower = route.replaceAll('/', '').toLowerCase();
      // Count shared characters as a rough similarity score.
      int score = 0;
      for (int i = 0; i < lower.length && i < routeLower.length; i++) {
        if (lower[i] == routeLower[i]) score++;
      }
      if (score > bestScore) {
        bestScore = score;
        best = route;
      }
    }
    // Only suggest if at least 3 chars match (avoids garbage suggestions).
    return bestScore >= 3 ? best : null;
  }

  /// Pop the current route (go back).
  Future<ToolResult> goBack() async {
    // Priority 1: NavigatorState from key or observer.
    final navigator = _navigator;
    if (navigator != null && navigator.canPop()) {
      navigator.pop();
      await _waitForFrame();
      return ToolResult.ok({'action': 'navigated back'});
    }

    // Priority 2: semantics dismiss action (works for dialogs, sheets, etc.).
    final views = WidgetsBinding.instance.renderViews;
    if (views.isNotEmpty) {
      final owner = views.first.owner?.semanticsOwner;
      final root = owner?.rootSemanticsNode;
      if (root != null) {
        final dismissNode = _findDismissableNode(root);
        if (dismissNode != null) {
          owner!.performAction(dismissNode.id, SemanticsAction.dismiss);
          await _waitForFrame();
          return ToolResult.ok({'action': 'navigated back'});
        }
      }
    }

    return ToolResult.fail('Cannot go back — already at the root screen.');
  }

  /// Search for a node with a dismiss action (back button, close button, etc.).
  SemanticsNode? _findDismissableNode(SemanticsNode node) {
    final data = node.getSemanticsData();
    if (data.actions & SemanticsAction.dismiss.index != 0) return node;
    SemanticsNode? result;
    node.visitChildren((child) {
      result ??= _findDismissableNode(child);
      return result == null;
    });
    return result;
  }

  /// Re-capture the current screen and return a description.
  ///
  /// Includes a settle delay before capturing so that asynchronously-loaded
  /// content (network results, animations) has time to appear in the
  /// semantics tree.
  Future<ToolResult> getScreenContent() async {
    await Future.delayed(const Duration(milliseconds: 1500));
    final context = _walker.captureScreenContext();
    return ToolResult.ok({'screenContent': context.toPromptString()});
  }

  /// Long press an element.
  Future<ToolResult> longPress(String label, {String? parentContext}) async {
    final node = _findNode(label, parentContext: parentContext);
    if (node == null) {
      return ToolResult.fail("Element '$label' not found on screen.");
    }

    final data = node.getSemanticsData();
    if (!data.actions.containsAction(SemanticsAction.longPress)) {
      return ToolResult.fail("Element '$label' does not support long press.");
    }

    _performAction(node.id, SemanticsAction.longPress);
    await _waitForFrame();
    return ToolResult.ok({'longPressed': label});
  }

  /// Increase the value of a slider/stepper.
  ///
  /// The LLM often targets the quantity text (e.g. "1") which doesn't support
  /// increase. The actual stepper container or a sibling/parent node usually
  /// holds the action. This method tries progressively broader searches.
  Future<ToolResult> increaseValue(String label) async {
    final found = _findNodeWithAction(label, SemanticsAction.increase);
    if (found != null) {
      _performAction(found.id, SemanticsAction.increase);
      await _waitForFrame();
      return ToolResult.ok({'increased': label});
    }

    // Fallback: find a tappable button that looks like an increase/+ control.
    final fallback = _findStepperButton(label, isIncrease: true);
    if (fallback != null) {
      _performAction(fallback.id, SemanticsAction.tap);
      await _waitForFrame();
      await Future.delayed(const Duration(milliseconds: 300));
      return ToolResult.ok({'increased': label, 'via': 'tap_fallback'});
    }

    return ToolResult.fail(
      "Element '$label' does not support increase. "
      'Try tapping the "+" or "Increase quantity" button instead.',
    );
  }

  /// Decrease the value of a slider/stepper.
  ///
  /// Same progressive search as [increaseValue] — see its doc comment.
  Future<ToolResult> decreaseValue(String label) async {
    final found = _findNodeWithAction(label, SemanticsAction.decrease);
    if (found != null) {
      _performAction(found.id, SemanticsAction.decrease);
      await _waitForFrame();
      return ToolResult.ok({'decreased': label});
    }

    // Fallback: find a tappable button that looks like a decrease/- control.
    final fallback = _findStepperButton(label, isIncrease: false);
    if (fallback != null) {
      _performAction(fallback.id, SemanticsAction.tap);
      await _waitForFrame();
      await Future.delayed(const Duration(milliseconds: 300));
      return ToolResult.ok({'decreased': label, 'via': 'tap_fallback'});
    }

    return ToolResult.fail(
      "Element '$label' does not support decrease. "
      'Try tapping the "-" or "Decrease quantity" button instead.',
    );
  }

  // ---------------------------------------------------------------------------
  // Private helpers
  // ---------------------------------------------------------------------------

  /// Find a SemanticsNode that supports a specific [action] (increase/decrease).
  ///
  /// Progressively broader search:
  /// 1. Find node by label — if it supports the action, return it.
  /// 2. If multiple nodes match the label, try each for the action.
  /// 3. Walk up the parent chain of each match (stepper containers often hold
  ///    the increase/decrease action on a parent, not the text child).
  /// 4. Search ALL nodes on screen for one that supports the action near
  ///    the matched element (fallback for unlabeled steppers).
  SemanticsNode? _findNodeWithAction(String label, SemanticsAction action) {
    final context = _walker.captureScreenContext();
    final normalizedLabel = label.toLowerCase();

    // Find all elements whose label contains the search term.
    final matches = context.elements
        .where((e) => e.label.toLowerCase().contains(normalizedLabel))
        .toList();
    AiLogger.log(
      '_findNodeWithAction: "$label" -> ${matches.length} match(es), '
      'looking for ${action.name}',
      tag: 'Action',
    );

    // Step 1-2: Check each matching node directly.
    for (final match in matches) {
      final node = _walker.findNodeById(match.nodeId);
      if (node == null) continue;
      final data = node.getSemanticsData();
      if (data.actions.containsAction(action)) {
        AiLogger.log(
          '_findNodeWithAction: direct match on node ${node.id}',
          tag: 'Action',
        );
        return node;
      }
    }

    // Step 3: Walk up parent chain of each match (max 3 levels).
    for (final match in matches) {
      final node = _walker.findNodeById(match.nodeId);
      if (node == null) continue;
      SemanticsNode? current = node.parent;
      for (int depth = 0; depth < 3 && current != null; depth++) {
        final data = current.getSemanticsData();
        if (data.actions.containsAction(action)) {
          AiLogger.log(
            '_findNodeWithAction: found on parent node ${current.id} '
            '(depth ${depth + 1} from "${match.label}")',
            tag: 'Action',
          );
          return current;
        }
        current = current.parent;
      }
    }

    // Step 4: Find ANY node on screen that supports the action.
    // This handles cases where the stepper has no label at all.
    for (final element in context.elements) {
      final node = _walker.findNodeById(element.nodeId);
      if (node == null) continue;
      final data = node.getSemanticsData();
      if (data.actions.containsAction(action)) {
        AiLogger.log(
          '_findNodeWithAction: fallback — found node ${node.id} '
          '("${element.label}") with ${action.name}',
          tag: 'Action',
        );
        return node;
      }
    }

    AiLogger.log(
      '_findNodeWithAction: no node with ${action.name} found on screen',
      tag: 'Action',
    );
    return null;
  }

  /// Find a tappable button that looks like a stepper +/- control.
  ///
  /// Strategy:
  /// 1. Search by label patterns ("+", "Increase quantity", etc.)
  /// 2. If no labeled match, find unlabeled tappable buttons NEAR the target
  ///    product — common pattern for `IconButton(Icons.add)` without semantics.
  ///    Stepper buttons typically appear as: [- button] [count text] [+ button],
  ///    so we look for small tappable nodes adjacent to a number value.
  SemanticsNode? _findStepperButton(String label, {required bool isIncrease}) {
    final context = _walker.captureScreenContext();

    final patterns = isIncrease
        ? const ['increase quantity', 'increase', '+', 'plus', 'add']
        : const ['decrease quantity', 'decrease', '-', 'minus', 'subtract', 'remove'];

    // Pass 1: Search by label patterns (including non-empty labels).
    for (final element in context.elements) {
      final lower = element.label.toLowerCase().trim();
      if (lower.isEmpty) continue;

      final matches = patterns.any((p) => lower == p || lower.contains(p));
      if (!matches) continue;

      final node = _walker.findNodeById(element.nodeId);
      if (node == null) continue;

      final data = node.getSemanticsData();
      if (data.actions.containsAction(SemanticsAction.tap)) {
        AiLogger.log(
          '_findStepperButton: found "${element.label}" (node ${node.id}) '
          'as ${isIncrease ? "increase" : "decrease"} fallback',
          tag: 'Action',
        );
        return node;
      }
    }

    // Pass 2: Find unlabeled tappable buttons near a number value.
    // Stepper layouts: [- button (empty label)] [Text "1"] [+ button (empty label)]
    // Find elements showing a numeric value, then look at nearby tappable
    // elements with empty labels (icon buttons).
    final normalizedLabel = label.toLowerCase();
    final numberElements = <UiElement>[];
    final emptyLabelButtons = <UiElement>[];

    for (final element in context.elements) {
      final lower = element.label.toLowerCase().trim();
      // Numeric elements (the count display "1", "2", etc.)
      if (lower.isNotEmpty && RegExp(r'^\d+$').hasMatch(lower)) {
        // Check if this number is near the target product in the element tree.
        final isNearTarget = element.parentLabels.any(
          (p) => p.toLowerCase().contains(normalizedLabel),
        );
        if (isNearTarget) numberElements.add(element);
      }
      // Empty-label tappable buttons (likely icon buttons)
      if (lower.isEmpty && element.availableActions.contains('tap')) {
        emptyLabelButtons.add(element);
      }
    }

    // For each number element near the target, find adjacent empty-label buttons.
    for (final numEl in numberElements) {
      final numY = numEl.bounds.center.dy;
      final numX = numEl.bounds.center.dx;

      // Find empty-label tappable buttons on the same horizontal line.
      final nearby = emptyLabelButtons.where((btn) {
        final dy = (btn.bounds.center.dy - numY).abs();
        return dy < 40; // Same row (within 40px vertically).
      }).toList();

      if (nearby.isEmpty) continue;

      // Sort by X position. For increase (+), pick the one to the RIGHT of
      // the number. For decrease (-), pick the one to the LEFT.
      nearby.sort((a, b) => a.bounds.center.dx.compareTo(b.bounds.center.dx));

      final candidates = isIncrease
          ? nearby.where((btn) => btn.bounds.center.dx > numX)
          : nearby.where((btn) => btn.bounds.center.dx < numX);

      if (candidates.isNotEmpty) {
        final target = isIncrease ? candidates.first : candidates.last;
        final node = _walker.findNodeById(target.nodeId);
        if (node != null) {
          AiLogger.log(
            '_findStepperButton: found unlabeled button (node ${node.id}) '
            '${isIncrease ? "right" : "left"} of count "${numEl.label}" '
            'near "$label"',
            tag: 'Action',
          );
          return node;
        }
      }
    }

    AiLogger.log(
      '_findStepperButton: no ${isIncrease ? "increase" : "decrease"} '
      'button found on screen',
      tag: 'Action',
    );
    return null;
  }

  /// Find a SemanticsNode by matching its label, with optional disambiguation.
  SemanticsNode? _findNode(
    String label, {
    String? parentContext,
    UiElementType? preferType,
  }) {
    final context = _walker.captureScreenContext();
    final normalizedLabel = label.toLowerCase();

    // Find all elements whose label contains the search term.
    var matches = context.elements.where(
      (e) => e.label.toLowerCase().contains(normalizedLabel),
    );
    AiLogger.log(
      '_findNode: "$label" -> ${matches.length} match(es) from ${context.elements.length} elements',
      tag: 'Action',
    );

    // If preferring a specific type, narrow to that type when possible.
    // If no label matches are of the right type, KEEP all label matches
    // so we can still tap/interact with the element found by label.
    if (preferType != null) {
      final typed = matches.where((e) => e.type == preferType);
      if (typed.isNotEmpty) matches = typed;
    }

    final matchList = matches.toList();
    if (matchList.isEmpty) {
      // Also try matching by hint text.
      final hintMatches = context.elements
          .where(
            (e) => e.hint?.toLowerCase().contains(normalizedLabel) ?? false,
          )
          .toList();
      if (hintMatches.isNotEmpty) {
        return _walker.findNodeById(hintMatches.first.nodeId);
      }

      // For short symbolic labels ("+", "-") with parentContext, try finding
      // unlabeled tappable buttons near the parent element. Common pattern:
      // Icon buttons in steppers have no semantic label.
      if (label.length <= 2 && parentContext != null) {
        final normalizedParent = parentContext.toLowerCase();
        // Find elements matching the parent context.
        final parentMatches = context.elements.where(
          (e) => e.label.toLowerCase().contains(normalizedParent),
        );
        if (parentMatches.isNotEmpty) {
          final parentEl = parentMatches.first;
          final parentY = parentEl.bounds.center.dy;
          // Find tappable elements with empty labels on the same row.
          final nearbyButtons = context.elements.where((e) {
            if (e.label.isNotEmpty) return false;
            if (!e.availableActions.contains('tap')) return false;
            final dy = (e.bounds.center.dy - parentY).abs();
            return dy < 60; // Same row within 60px
          }).toList();

          if (nearbyButtons.isNotEmpty) {
            // For "+", pick rightmost; for "-", pick leftmost.
            nearbyButtons.sort(
              (a, b) => a.bounds.center.dx.compareTo(b.bounds.center.dx),
            );
            final target = (label == '+' || label == 'plus')
                ? nearbyButtons.last
                : nearbyButtons.first;
            AiLogger.log(
              '_findNode: positional match for "$label" near "$parentContext" '
              '-> node ${target.nodeId}',
              tag: 'Action',
            );
            return _walker.findNodeById(target.nodeId);
          }
        }
      }

      return null;
    }

    if (matchList.length == 1) {
      return _walker.findNodeById(matchList.first.nodeId);
    }

    // Multiple matches: disambiguate using parentContext.
    // Prefer exact matches over substring matches to avoid "Product 123"
    // matching "Product 1234" or "Product 123-XL".
    if (parentContext != null) {
      final normalizedParent = parentContext.toLowerCase();

      // Pass 1: exact match on a parent label.
      final exactMatch = matchList.where(
        (e) => e.parentLabels.any(
          (p) => p.toLowerCase() == normalizedParent,
        ),
      );
      if (exactMatch.isNotEmpty) {
        return _walker.findNodeById(exactMatch.first.nodeId);
      }

      // Pass 2: substring match (looser).
      final substringMatch = matchList.where(
        (e) => e.parentLabels.any(
          (p) => p.toLowerCase().contains(normalizedParent),
        ),
      );
      if (substringMatch.isNotEmpty) {
        return _walker.findNodeById(substringMatch.first.nodeId);
      }
    }

    // Fallback: prefer interactive elements, then first match.
    final interactive = matchList.where((e) => e.availableActions.isNotEmpty);
    if (interactive.isNotEmpty) {
      return _walker.findNodeById(interactive.first.nodeId);
    }

    return _walker.findNodeById(matchList.first.nodeId);
  }

  /// Find the best TextField node on screen that supports setText.
  ///
  /// Prefers focused fields over unfocused, and picks the LAST editable
  /// field in document order (most likely the newly-opened search bar).
  SemanticsNode? _findAnyTextField() {
    final context = _walker.captureScreenContext();
    final textFields = context.elements
        .where((e) => e.type == UiElementType.textField)
        .toList();
    if (textFields.isEmpty) return null;

    // Prefer a focused field if one exists.
    SemanticsNode? bestNode;
    String? bestLabel;
    for (final tf in textFields) {
      final node = _walker.findNodeById(tf.nodeId);
      if (node == null) continue;
      final data = node.getSemanticsData();
      if (!data.actions.containsAction(SemanticsAction.setText)) continue;
      final isFocused = data.hasFlag(SemanticsFlag.isFocused);
      if (isFocused) {
        AiLogger.log(
          '_findAnyTextField: found focused "${tf.label}" (node ${node.id})',
          tag: 'Action',
        );
        return node; // Focused field wins immediately.
      }
      // Track the last editable field as fallback.
      bestNode = node;
      bestLabel = tf.label;
    }

    if (bestNode != null) {
      AiLogger.log(
        '_findAnyTextField: found "$bestLabel" (node ${bestNode.id})',
        tag: 'Action',
      );
    }
    return bestNode;
  }

  /// Perform a semantics action on a node.
  void _performAction(int nodeId, SemanticsAction action) {
    final views = WidgetsBinding.instance.renderViews;
    if (views.isEmpty) return;
    final owner = views.first.owner?.semanticsOwner;
    owner?.performAction(nodeId, action);
  }

  /// Perform a setText action on a node.
  void _performSetText(int nodeId, String text) {
    final views = WidgetsBinding.instance.renderViews;
    if (views.isEmpty) return;
    final owner = views.first.owner?.semanticsOwner;
    owner?.performAction(nodeId, SemanticsAction.setText, text);
  }

  /// Wait for the next frame to settle after performing an action.
  ///
  /// Times out after 5 seconds to prevent the agent from hanging forever
  /// if the render pipeline stalls or the widget tree is torn down.
  Future<void> _waitForFrame() {
    final completer = Completer<void>();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!completer.isCompleted) completer.complete();
    });
    return completer.future.timeout(
      const Duration(seconds: 5),
      onTimeout: () {
        if (!completer.isCompleted) completer.complete();
        AiLogger.warn('_waitForFrame timed out after 5s', tag: 'Action');
      },
    );
  }
}

/// Extension to check actions in the bitmask.
extension on int {
  bool containsAction(SemanticsAction action) => this & action.index != 0;
}
