import '../models/ui_element.dart';

/// A snapshot of the current screen's UI elements, extracted from the
/// Flutter Semantics tree.
class ScreenContext {
  /// All meaningful UI elements on the current screen.
  final List<UiElement> elements;

  /// When this snapshot was captured.
  final DateTime capturedAt;

  const ScreenContext({
    required this.elements,
    required this.capturedAt,
  });

  factory ScreenContext.empty() {
    return ScreenContext(elements: [], capturedAt: DateTime.now());
  }

  bool get isEmpty => elements.isEmpty;
  bool get isNotEmpty => elements.isNotEmpty;

  /// Whether the screen has a scrollable area.
  bool get isScrollable =>
      elements.any((e) => e.type == UiElementType.scrollable);

  /// Whether there is more content below the current viewport.
  bool get canScrollDown => elements.any(
      (e) => e.type == UiElementType.scrollable &&
          e.availableActions.contains('scrollDown'));

  /// Whether there is more content above the current viewport.
  bool get canScrollUp => elements.any(
      (e) => e.type == UiElementType.scrollable &&
          e.availableActions.contains('scrollUp'));

  /// Format all elements as a human-readable prompt section for the LLM.
  ///
  /// The output is structured to help the LLM understand the screen:
  /// - Scroll indicators at the top if the screen has more content
  /// - Elements grouped under header sections for visual clarity
  /// - Noise filtered out (scrollable containers, empty-label elements)
  String toPromptString() {
    if (elements.isEmpty) return '(No UI elements detected on screen)';

    final buffer = StringBuffer();

    // Scroll awareness: tell the LLM there's more content.
    if (canScrollDown && canScrollUp) {
      buffer.writeln(
          '** This screen has MORE CONTENT above AND below — scroll to see all content. **');
    } else if (canScrollDown) {
      buffer.writeln(
          '** This screen has MORE CONTENT below — scroll down to see it. **');
    } else if (canScrollUp) {
      buffer.writeln(
          '** This screen has MORE CONTENT above — scroll up to see it. **');
    }

    // Filter out noise:
    // - Scrollable containers (structural, not content)
    // - Elements with empty labels AND no value (invisible/structural)
    final meaningful = elements.where((e) {
      if (e.type == UiElementType.scrollable) return false;
      if (e.label.isEmpty && (e.value == null || e.value!.isEmpty)) {
        return false;
      }
      return true;
    }).toList();

    if (meaningful.isEmpty) {
      buffer.writeln('(No visible UI elements detected)');
      return buffer.toString().trimRight();
    }

    // Group elements under headers for better structure.
    int idx = 1;
    for (final element in meaningful) {
      if (element.type == UiElementType.header) {
        // Headers are visual separators — show them distinctly.
        buffer.writeln();
        buffer.writeln('--- ${element.label} ---');
        continue;
      }
      buffer.writeln('  $idx. ${element.toPromptString()}');
      idx++;
    }

    return buffer.toString().trimRight();
  }

  /// Get all elements that support a specific action.
  List<UiElement> elementsWithAction(String action) {
    return elements.where((e) => e.availableActions.contains(action)).toList();
  }

  /// Find elements by label (case-insensitive partial match).
  List<UiElement> findByLabel(String query) {
    final lower = query.toLowerCase();
    return elements.where((e) => e.label.toLowerCase().contains(lower)).toList();
  }

  /// Find the first scrollable element on screen, if any.
  UiElement? get firstScrollable {
    for (final e in elements) {
      if (e.type == UiElementType.scrollable) return e;
    }
    return null;
  }

  @override
  String toString() => 'ScreenContext(${elements.length} elements)';
}
