import 'tool_definition.dart';

/// Provides the callback signatures that built-in tools delegate to.
///
/// These are implemented by [ActionExecutor] and injected at startup,
/// keeping the tool definitions decoupled from the action execution layer.
class BuiltInToolHandlers {
  final Future<Map<String, dynamic>> Function(
    String label, {
    String? parentContext,
  })
  onTap;
  final Future<Map<String, dynamic>> Function(
    String label,
    String text, {
    String? parentContext,
  })
  onSetText;
  final Future<Map<String, dynamic>> Function(String direction) onScroll;
  final Future<Map<String, dynamic>> Function(String routeName) onNavigate;
  final Future<Map<String, dynamic>> Function() onGoBack;
  final Future<Map<String, dynamic>> Function() onGetScreenContent;
  final Future<Map<String, dynamic>> Function(
    String label, {
    String? parentContext,
  })
  onLongPress;
  final Future<Map<String, dynamic>> Function(String label) onIncrease;
  final Future<Map<String, dynamic>> Function(String label) onDecrease;
  final Future<String> Function(String question) onAskUser;
  final Future<String> Function(String buttonLabel, String summary)? onHandoff;

  const BuiltInToolHandlers({
    required this.onTap,
    required this.onSetText,
    required this.onScroll,
    required this.onNavigate,
    required this.onGoBack,
    required this.onGetScreenContent,
    required this.onLongPress,
    required this.onIncrease,
    required this.onDecrease,
    required this.onAskUser,
    this.onHandoff,
  });
}

/// Creates the standard set of built-in tools that work on any Flutter app.
///
/// These tools are auto-registered and allow the LLM to interact with
/// the app's UI via the Semantics tree.
List<AiTool> createBuiltInTools(BuiltInToolHandlers handlers) {
  return [
    // --- tap_element ---
    AiTool(
      name: 'tap_element',
      description:
          'Tap a button, link, or interactive element on screen by its label text. '
          'If multiple elements share the same label, use parentContext to specify which one '
          '(e.g., the section or nearby heading). '
          'Do NOT use for adjusting quantities — use increase_value/decrease_value for +/- steppers.',
      parameters: {
        'label': const ToolParameter(
          type: 'string',
          description: 'The visible text label of the element to tap.',
        ),
        'parentContext': const ToolParameter(
          type: 'string',
          description:
              'Optional: the ITEM NAME or PRIMARY TITLE near the element to disambiguate '
              'when multiple elements share the same label. Use the product name, heading, '
              'or main title — NOT prices, discounts, or badges. '
              'Example: for "ADD" next to "Organic Milk", use parentContext="Organic Milk".',
        ),
      },
      required: const ['label'],
      handler: (args) => handlers.onTap(
        args['label'] as String,
        parentContext: args['parentContext'] as String?,
      ),
    ),

    // --- set_text ---
    AiTool(
      name: 'set_text',
      description:
          'Enter text into a text field (search bar, input box, form field). '
          'This clears any existing text and replaces it with the new value. '
          'IMPORTANT: You do NOT need to see a text field in the screen content to use this tool. '
          'The tool automatically finds text fields even if they are hidden, unfocused, inside '
          'app bars, or not yet loaded. It will tap to activate search bars, wait for async fields '
          'to appear, and find text inputs by type even if the label does not match exactly. '
          'When you need to type into a search bar, ALWAYS call this tool — do not skip it because '
          'you cannot see a text field in the screen content.',
      parameters: {
        'label': const ToolParameter(
          type: 'string',
          description:
              'The label, hint, or placeholder text of the text field.',
        ),
        'text': const ToolParameter(
          type: 'string',
          description: 'The text to enter into the field.',
        ),
        'parentContext': const ToolParameter(
          type: 'string',
          description:
              'Optional: a nearby heading or section label to disambiguate.',
        ),
      },
      required: const ['label', 'text'],
      handler: (args) => handlers.onSetText(
        args['label'] as String,
        args['text'] as String,
        parentContext: args['parentContext'] as String?,
      ),
    ),

    // --- scroll ---
    AiTool(
      name: 'scroll',
      description:
          'Scroll the current scrollable area. Use this when you need to find '
          'elements that are off-screen or to see more content.',
      parameters: {
        'direction': const ToolParameter(
          type: 'string',
          description: 'The direction to scroll.',
          enumValues: ['up', 'down', 'left', 'right'],
        ),
      },
      required: const ['direction'],
      handler: (args) => handlers.onScroll(args['direction'] as String),
    ),

    // --- navigate_to_route ---
    AiTool(
      name: 'navigate_to_route',
      description:
          'Navigate to a different screen/route by its exact route name. '
          'Route names always start with "/" (e.g., "/home", "/settings", "/profile"). '
          'Use the route names EXACTLY as listed in the ALL APP SCREENS section of your context.',
      parameters: {
        'routeName': const ToolParameter(
          type: 'string',
          description:
              'The exact route name to navigate to, including the leading "/" '
              '(e.g., "/home", "/settings", "/profile").',
        ),
      },
      required: const ['routeName'],
      handler: (args) => handlers.onNavigate(args['routeName'] as String),
    ),

    // --- go_back ---
    AiTool(
      name: 'go_back',
      description:
          'Go back to the previous screen (pop the current route). '
          'Equivalent to pressing the back button.',
      parameters: const {},
      required: const [],
      handler: (_) => handlers.onGoBack(),
    ),

    // --- get_screen_content ---
    AiTool(
      name: 'get_screen_content',
      description:
          'Re-read the current screen to get a fresh view of what is visible. '
          'Use this after performing actions to see the updated UI, or when '
          'you need to check what is currently on screen.',
      parameters: const {},
      required: const [],
      handler: (_) => handlers.onGetScreenContent(),
    ),

    // --- long_press_element ---
    AiTool(
      name: 'long_press_element',
      description:
          'Long press an element on screen. Some elements show context menus '
          'or additional options when long pressed.',
      parameters: {
        'label': const ToolParameter(
          type: 'string',
          description: 'The visible text label of the element to long press.',
        ),
        'parentContext': const ToolParameter(
          type: 'string',
          description:
              'Optional: a nearby heading or section label to disambiguate.',
        ),
      },
      required: const ['label'],
      handler: (args) => handlers.onLongPress(
        args['label'] as String,
        parentContext: args['parentContext'] as String?,
      ),
    ),

    // --- increase_value ---
    AiTool(
      name: 'increase_value',
      description:
          'Increase the numeric value of a QUANTITY STEPPER or SLIDER. '
          'The label should identify the stepper/slider — typically "quantity", '
          '"Increase quantity", or the product name next to +/- buttons. '
          'Do NOT pass button labels like "Add to cart" or "Buy" — use tap_element for those.',
      parameters: {
        'label': const ToolParameter(
          type: 'string',
          description:
              'The label of the quantity stepper or slider to increase '
              '(e.g., "quantity", "Increase quantity", or the product name).',
        ),
      },
      required: const ['label'],
      handler: (args) => handlers.onIncrease(args['label'] as String),
    ),

    // --- decrease_value ---
    AiTool(
      name: 'decrease_value',
      description:
          'Decrease the numeric value of a QUANTITY STEPPER or SLIDER. '
          'The label should identify the stepper/slider — typically "quantity", '
          '"Decrease quantity", or the product name next to +/- buttons. '
          'Do NOT pass button labels like "Remove" or "Delete" — use tap_element for those.',
      parameters: {
        'label': const ToolParameter(
          type: 'string',
          description:
              'The label of the quantity stepper or slider to decrease '
              '(e.g., "quantity", "Decrease quantity", or the product name).',
        ),
      },
      required: const ['label'],
      handler: (args) => handlers.onDecrease(args['label'] as String),
    ),

    // --- ask_user ---
    AiTool(
      name: 'ask_user',
      description:
          'LAST RESORT: Ask the user a question and wait for their response. '
          'Use ONLY when: (1) there are multiple options with genuinely different consequences '
          '(different prices, different destinations) that the user has not specified, or '
          '(2) critical information is truly missing and cannot be inferred from context. '
          'Do NOT use to confirm actions the user already requested. '
          'Do NOT use when the app structure makes the answer obvious. '
          'When presenting options, list ALL with full details (name, price).',
      parameters: {
        'question': const ToolParameter(
          type: 'string',
          description:
              'A clear, specific question. When presenting options, list each with details '
              '(e.g. "1) Option A — 100  2) Option B — 150. Which one?").',
        ),
      },
      required: const ['question'],
      handler: (args) async {
        final question = args['question'] as String;
        final response = await handlers.onAskUser(question);
        return {
          'yourQuestion': question,
          'userResponse': response,
          'instruction':
              'The user responded to your question. '
              'If their response ANSWERS your question → continue with the task. '
              'If their response is a COMPLETELY DIFFERENT REQUEST '
              '(unrelated to your question) → ABANDON your current task '
              'and handle their new request instead. '
              'NEVER repeat the same question — if they didn\'t answer it, they don\'t want to.',
        };
      },
    ),

    // --- hand_off_to_user ---
    if (handlers.onHandoff != null)
      AiTool(
        name: 'hand_off_to_user',
        description:
            'Hand control to the user for the FINAL irreversible action. '
            'Use this ONLY when you have completed ALL preparatory steps and the '
            'final action button (Book Ride, Place Order, Confirm Payment, Submit, etc.) '
            'is visible on screen. The overlay will clear so the user can see the full app '
            'screen with all details and tap the button themselves. '
            'Do NOT use for intermediate steps or information queries.',
        parameters: {
          'button_label': const ToolParameter(
            type: 'string',
            description:
                'The EXACT label of the final action button the user should tap '
                '(e.g., "Book Ride", "Place Order", "Confirm Payment").',
          ),
          'summary': const ToolParameter(
            type: 'string',
            description:
                'Brief description of what will happen when the user taps the button '
                '(e.g., "Your order will be placed and payment of ₹150 will be charged").',
          ),
        },
        required: const ['button_label', 'summary'],
        handler: (args) async {
          final buttonLabel = args['button_label'] as String;
          final summary = args['summary'] as String;
          final result = await handlers.onHandoff!(buttonLabel, summary);
          return {
            'handoffResult': result,
            'instruction':
                'The user has acted. Call get_screen_content to see '
                'the current screen and report the outcome to the user.',
          };
        },
      ),
  ];
}
