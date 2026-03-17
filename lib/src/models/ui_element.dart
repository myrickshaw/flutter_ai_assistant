import 'dart:ui';

/// Type of UI element detected from semantics flags.
enum UiElementType {
  button,
  textField,
  header,
  slider,
  link,
  text,
  checkbox,
  toggle,
  scrollable,
  image,
  unknown,
}

/// A parsed representation of a SemanticsNode, describing a single
/// interactive or informative UI element on screen.
class UiElement {
  /// The SemanticsNode ID, used to target this element for actions.
  final int nodeId;

  /// The accessible label (button text, field label, etc.).
  final String label;

  /// Current value (text field content, slider position, etc.).
  final String? value;

  /// Accessibility hint (e.g. "Double tap to activate").
  final String? hint;

  /// Detected element type based on semantics flags.
  final UiElementType type;

  /// List of actions this element supports (tap, longPress, setText, etc.).
  final List<String> availableActions;

  /// Labels of parent and sibling nodes, used for disambiguation when
  /// multiple elements share the same label (e.g., multiple "Add" buttons
  /// in a product list — the parentLabels contain the product name).
  final List<String> parentLabels;

  /// Bounding rectangle of the element on screen.
  final Rect bounds;

  /// Whether this element is currently enabled.
  final bool isEnabled;

  /// Whether this element is currently focused.
  final bool isFocused;

  /// Whether this element is checked (for checkboxes/toggles).
  final bool? isChecked;

  const UiElement({
    required this.nodeId,
    required this.label,
    this.value,
    this.hint,
    required this.type,
    required this.availableActions,
    this.parentLabels = const [],
    required this.bounds,
    this.isEnabled = true,
    this.isFocused = false,
    this.isChecked,
  });

  /// Format this element as a human-readable string for the LLM prompt.
  String toPromptString() {
    final buffer = StringBuffer();

    // Type prefix
    final typeStr = switch (type) {
      UiElementType.button => '[Button]',
      UiElementType.textField => '[TextField]',
      UiElementType.header => '[Header]',
      UiElementType.slider => '[Slider]',
      UiElementType.link => '[Link]',
      UiElementType.checkbox => '[Checkbox]',
      UiElementType.toggle => '[Toggle]',
      UiElementType.scrollable => '[Scrollable]',
      UiElementType.image => '[Image]',
      UiElementType.text => '[Text]',
      UiElementType.unknown => '',
    };

    buffer.write('$typeStr "$label"');

    if (value != null && value!.isNotEmpty) {
      buffer.write(' (value: "$value")');
    }

    if (isChecked != null) {
      buffer.write(isChecked! ? ' [checked]' : ' [unchecked]');
    }

    if (!isEnabled) {
      buffer.write(' [disabled]');
    }

    if (availableActions.isNotEmpty) {
      buffer.write(' {${availableActions.join(', ')}}');
    }

    if (parentLabels.isNotEmpty) {
      buffer.write(' in context: [${parentLabels.join(', ')}]');
    }

    return buffer.toString();
  }

  @override
  String toString() => 'UiElement(nodeId: $nodeId, label: "$label", type: $type)';
}
