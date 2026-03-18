import 'package:flutter/rendering.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/widgets.dart';

import '../core/ai_logger.dart';
import '../models/ui_element.dart';
import 'screen_context.dart';

/// Walks the Flutter Semantics tree to extract structured UI descriptions.
///
/// The Semantics tree is Flutter's accessibility layer — it describes what
/// is on screen in terms of labels, values, actions, and element types.
/// This class reads that tree and produces [ScreenContext] snapshots.
class SemanticsWalker {
  SemanticsHandle? _semanticsHandle;

  /// Enable the semantics tree. Must be called once at startup.
  /// Returns a handle that keeps the tree alive; dispose it when done.
  void ensureSemantics() {
    if (_semanticsHandle == null) {
      AiLogger.log('Enabling semantics tree', tag: 'Semantics');
    }
    _semanticsHandle ??= WidgetsBinding.instance.ensureSemantics();
  }

  /// Release the semantics handle.
  void dispose() {
    AiLogger.log('Disposing semantics handle', tag: 'Semantics');
    _semanticsHandle?.dispose();
    _semanticsHandle = null;
  }

  /// Capture a snapshot of the current screen's UI elements.
  ScreenContext captureScreenContext() {
    final views = WidgetsBinding.instance.renderViews;
    if (views.isEmpty) {
      AiLogger.warn(
        'No render views available for screen capture',
        tag: 'Semantics',
      );
      return ScreenContext.empty();
    }
    final owner = views.first.owner?.semanticsOwner;
    final root = owner?.rootSemanticsNode;
    if (root == null) {
      AiLogger.warn(
        'No root semantics node — tree may not be ready',
        tag: 'Semantics',
      );
      return ScreenContext.empty();
    }

    final elements = <UiElement>[];
    _walkNode(root, elements, depth: 0, parentLabels: []);
    AiLogger.log(
      'Screen captured: ${elements.length} elements '
      '(${elements.where((e) => e.availableActions.isNotEmpty).length} interactive)',
      tag: 'Semantics',
    );
    return ScreenContext(elements: elements, capturedAt: DateTime.now());
  }

  /// Find a specific SemanticsNode by its ID.
  SemanticsNode? findNodeById(int nodeId) {
    final views = WidgetsBinding.instance.renderViews;
    if (views.isEmpty) return null;
    final owner = views.first.owner?.semanticsOwner;
    final root = owner?.rootSemanticsNode;
    if (root == null) return null;
    final node = _searchById(root, nodeId);
    AiLogger.log(
      'findNodeById($nodeId): ${node != null ? 'found' : 'NOT found'}',
      tag: 'Semantics',
    );
    return node;
  }

  SemanticsNode? _searchById(SemanticsNode node, int targetId) {
    if (node.id == targetId) return node;
    SemanticsNode? result;
    node.visitChildren((child) {
      result ??= _searchById(child, targetId);
      return result == null; // stop visiting if found
    });
    return result;
  }

  void _walkNode(
    SemanticsNode node,
    List<UiElement> elements, {
    required int depth,
    required List<String> parentLabels,
  }) {
    final data = node.getSemanticsData();

    final label = data.label;
    final value = data.value;
    final hint = data.hint;
    final actions = data.actions;
    // ignore: deprecated_member_use
    final flags = data.flags;

    // Determine the element type from flags.
    final type = _detectType(flags, actions);

    // Determine which actions are available.
    final availableActions = _extractActions(actions);

    // Include this node if it has meaningful content or actions.
    final hasContent = label.isNotEmpty || value.isNotEmpty;
    final hasActions = availableActions.isNotEmpty;
    final isInteractive = hasActions && type != UiElementType.unknown;

    if (hasContent || isInteractive) {
      final isEnabled =
          !flags.containsFlag(SemanticsFlag.hasEnabledState) ||
          flags.containsFlag(SemanticsFlag.isEnabled);
      final isFocused = flags.containsFlag(SemanticsFlag.isFocused);

      bool? isChecked;
      if (flags.containsFlag(SemanticsFlag.hasCheckedState)) {
        isChecked = flags.containsFlag(SemanticsFlag.isChecked);
      } else if (flags.containsFlag(SemanticsFlag.hasToggledState)) {
        isChecked = flags.containsFlag(SemanticsFlag.isToggled);
      }

      elements.add(
        UiElement(
          nodeId: node.id,
          label: label,
          value: value.isNotEmpty ? value : null,
          hint: hint.isNotEmpty ? hint : null,
          type: type,
          availableActions: availableActions,
          parentLabels: parentLabels.length > 5
              ? parentLabels.sublist(parentLabels.length - 5)
              : parentLabels,
          bounds: node.rect,
          isEnabled: isEnabled,
          isFocused: isFocused,
          isChecked: isChecked,
        ),
      );
    }

    // Build parent labels for children: include this node's label if present.
    final childParentLabels = label.isNotEmpty
        ? [...parentLabels, label]
        : parentLabels;

    // Collect sibling labels once per parent level (O(n) instead of O(n²)).
    // Only collect when the parent has multiple children worth labeling.
    List<String>? siblingLabels;
    int childCount = 0;
    node.visitChildren((_) {
      childCount++;
      return true;
    });

    if (childCount > 1) {
      siblingLabels = <String>[];
      node.visitChildren((child) {
        final childData = child.getSemanticsData();
        if (childData.label.isNotEmpty) {
          siblingLabels!.add(childData.label);
        }
        return siblingLabels!.length < 10; // Cap to avoid huge lists
      });
    }

    // Recurse into children with enriched parent context.
    final childContext = siblingLabels != null && siblingLabels.isNotEmpty
        ? [...childParentLabels, ...siblingLabels]
        : childParentLabels;

    node.visitChildren((child) {
      _walkNode(child, elements, depth: depth + 1, parentLabels: childContext);
      return true;
    });
  }

  UiElementType _detectType(int flags, int actions) {
    if (flags.containsFlag(SemanticsFlag.isButton)) return UiElementType.button;
    if (flags.containsFlag(SemanticsFlag.isTextField)) {
      return UiElementType.textField;
    }
    if (flags.containsFlag(SemanticsFlag.isHeader)) return UiElementType.header;
    if (flags.containsFlag(SemanticsFlag.isSlider)) return UiElementType.slider;
    if (flags.containsFlag(SemanticsFlag.isLink)) return UiElementType.link;
    if (flags.containsFlag(SemanticsFlag.isImage)) return UiElementType.image;

    if (flags.containsFlag(SemanticsFlag.hasCheckedState) ||
        flags.containsFlag(SemanticsFlag.hasToggledState)) {
      return UiElementType.toggle;
    }

    // Check for scrollable via actions.
    if (actions.containsAction(SemanticsAction.scrollUp) ||
        actions.containsAction(SemanticsAction.scrollDown) ||
        actions.containsAction(SemanticsAction.scrollLeft) ||
        actions.containsAction(SemanticsAction.scrollRight)) {
      return UiElementType.scrollable;
    }

    // If it has a tap action, treat as button.
    if (actions.containsAction(SemanticsAction.tap)) {
      return UiElementType.button;
    }

    return UiElementType.text;
  }

  List<String> _extractActions(int actions) {
    final result = <String>[];
    if (actions.containsAction(SemanticsAction.tap)) result.add('tap');
    if (actions.containsAction(SemanticsAction.longPress)) {
      result.add('longPress');
    }
    if (actions.containsAction(SemanticsAction.setText)) result.add('setText');
    if (actions.containsAction(SemanticsAction.scrollUp)) {
      result.add('scrollUp');
    }
    if (actions.containsAction(SemanticsAction.scrollDown)) {
      result.add('scrollDown');
    }
    if (actions.containsAction(SemanticsAction.scrollLeft)) {
      result.add('scrollLeft');
    }
    if (actions.containsAction(SemanticsAction.scrollRight)) {
      result.add('scrollRight');
    }
    if (actions.containsAction(SemanticsAction.increase)) {
      result.add('increase');
    }
    if (actions.containsAction(SemanticsAction.decrease)) {
      result.add('decrease');
    }
    if (actions.containsAction(SemanticsAction.copy)) result.add('copy');
    if (actions.containsAction(SemanticsAction.cut)) result.add('cut');
    if (actions.containsAction(SemanticsAction.paste)) result.add('paste');
    if (actions.containsAction(SemanticsAction.dismiss)) result.add('dismiss');
    if (actions.containsAction(SemanticsAction.focus)) result.add('focus');
    return result;
  }
}

/// Extension to check flags in the bitmask.
extension on int {
  bool containsFlag(SemanticsFlag flag) => this & flag.index != 0;
  bool containsAction(SemanticsAction action) => this & action.index != 0;
}
