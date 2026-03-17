import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:uuid/uuid.dart';

import '../action/action_executor.dart';
import '../context/ai_navigator_observer.dart';
import '../context/context_cache.dart';
import '../context/context_invalidator.dart';
import '../context/route_discovery.dart';
import '../context/screenshot_capture.dart';
import '../context/semantics_walker.dart';
import '../llm/conversation_memory.dart';
import '../llm/react_agent.dart';
import '../models/action_step.dart';
import '../models/app_context_snapshot.dart';
import '../models/chat_content.dart';
import '../models/chat_message.dart';
import '../tools/built_in_tools.dart';
import '../tools/tool_result.dart';
import '../tools/tool_registry.dart';
import '../voice/voice_input_service.dart';
import '../voice/voice_output_service.dart';
import 'ai_assistant_config.dart';
import 'ai_event.dart';
import 'ai_logger.dart';

const _uuid = Uuid();

/// Controls the AI assistant lifecycle and orchestrates all components.
///
/// This is the central brain that wires together:
/// - Context extraction (SemanticsWalker, NavigatorObserver, Cache)
/// - LLM communication (Provider, ReAct Agent, ConversationMemory)
/// - Action execution (ActionExecutor, ScrollHandler)
/// - Tool management (ToolRegistry, built-in + custom tools)
/// - Voice I/O (VoiceInputService, VoiceOutputService)
/// - Chat state (messages, loading, overlay visibility)
class AiAssistantController extends ChangeNotifier {
  final AiAssistantConfig _config;

  // Internal components.
  late final SemanticsWalker _walker;
  late final ActionExecutor _executor;
  late final ToolRegistry _toolRegistry;
  late final ConversationMemory _memory;
  late final ReactAgent _agent;
  late final RouteDiscovery _routeDiscovery;
  late final ContextCache _contextCache;
  late final ContextInvalidator _contextInvalidator;

  // Voice services.
  VoiceInputService? _voiceInput;
  VoiceOutputService? _voiceOutput;

  // Public state.
  final List<AiChatMessage> _messages = [];
  bool _isProcessing = false;
  bool _isOverlayVisible = false;
  bool _isListening = false;
  bool _disposed = false;

  // Action feed state — real-time step streaming.
  final List<ActionStep> _actionSteps = [];
  bool _isActionFeedVisible = false;
  String? _finalResponseText;

  // Progressive status text — the LLM's user-facing reasoning/thought
  // emitted alongside tool calls. Shown in the action feed header.
  String? _progressText;

  // ask_user state — allows the agent to pause and ask the user a question.
  Completer<String>? _userResponseCompleter;
  bool _waitingForUserResponse = false;

  // Cancellation — allows the user to stop the agent mid-execution.
  bool _cancelRequested = false;

  // Action mode — true when the agent has executed a screen-changing tool
  // (navigation, tap, etc.) and is still processing. Used by the UI to
  // make the overlay semi-transparent so the user can see the app underneath.
  bool _hasExecutedScreenChangingTool = false;

  // Handoff mode — the overlay clears so the user can see the app and
  // tap the final action button (Book Ride, Place Order, etc.) themselves.
  // The agent pauses execution and waits for the user to act.
  bool _isHandoffMode = false;
  String? _handoffButtonLabel;
  String? _handoffSummary;
  Completer<String>? _handoffCompleter;
  VoidCallback? _handoffRouteListener;

  // Voice state — partial transcription shown live while user speaks,
  // and tracking whether the current task was initiated by voice.
  String? _partialTranscription;
  bool _currentTaskIsVoice = false;
  DateTime? _lastSpokenProgress;

  // Unread response — set when the agent adds a response while the overlay
  // is hidden (e.g. after handoff success). Cleared when overlay opens.
  bool _hasUnreadResponse = false;

  // Message queue — stores messages sent while the agent is already processing.
  // After the current run completes, the next queued message is sent automatically.
  String? _pendingMessage;
  bool _pendingIsVoice = false;

  // Response popup — shown after auto-closing the overlay on task completion.
  // Compact card above the FAB with the agent's response.
  bool _isResponsePopupVisible = false;
  AiResponseType _responsePopupType = AiResponseType.infoResponse;
  String? _responsePopupText;
  Timer? _responsePopupTimer;

  // Screenshot capture (null if disabled).
  ScreenshotCapture? _screenshotCapture;

  // Current task context — stored when sendMessage starts, used by handoff
  // event to provide full context about the user's original request.
  String? _currentTaskMessage;
  DateTime? _currentTaskStartedAt;

  // Processing timeout timer — paused during user-facing waits (handoff,
  // ask_user) so the user has unlimited time to respond.
  Timer? _processingTimer;

  /// Navigator observer to add to your app's Navigator.
  late final AiNavigatorObserver navigatorObserver;

  /// Safe wrapper around [notifyListeners] that checks [_disposed] first.
  /// Prevents "A ChangeNotifier was used after being disposed" errors.
  void _safeNotify() {
    if (!_disposed) notifyListeners();
  }

  /// Emit an analytics event to the host app's [AiAssistantConfig.onEvent].
  void _emit(AiEventType type, [Map<String, dynamic>? properties]) {
    _config.onEvent?.call(AiEvent.now(type, properties));
  }

  AiAssistantController({
    required AiAssistantConfig config,
    GlobalKey? appContentKey,
  }) : _config = config {
    if (_config.enableLogging) AiLogger.enable();
    if (_config.enableScreenshots && appContentKey != null) {
      _screenshotCapture = ScreenshotCapture(appContentKey: appContentKey);
    }
    _init();
  }

  // ---------------------------------------------------------------------------
  // Public getters
  // ---------------------------------------------------------------------------

  List<AiChatMessage> get messages => List.unmodifiable(_messages);
  bool get isProcessing => _isProcessing;
  bool get isOverlayVisible => _isOverlayVisible;
  bool get isListening => _isListening;
  String? get partialTranscription => _partialTranscription;
  AiAssistantConfig get config => _config;

  /// Live action steps streamed from the ReAct agent loop.
  List<ActionStep> get actionSteps => List.unmodifiable(_actionSteps);

  /// Whether the action feed overlay is currently showing.
  bool get isActionFeedVisible => _isActionFeedVisible;

  /// The agent's final response text, shown briefly in the feed before
  /// transitioning to the normal chat bubble.
  String? get finalResponseText => _finalResponseText;

  /// The LLM's current progressive status text (e.g. "Setting up your ride...").
  /// Updated each iteration as the agent works through the task.
  String? get progressText => _progressText;

  /// Whether the agent is paused waiting for user input (via ask_user tool).
  bool get isWaitingForUserResponse => _waitingForUserResponse;

  /// Whether the overlay is in handoff mode — the overlay clears and a small
  /// floating indicator tells the user which button to tap.
  bool get isHandoffMode => _isHandoffMode;

  /// The label of the button the user should tap (e.g., "Book Ride").
  String? get handoffButtonLabel => _handoffButtonLabel;

  /// Brief description of what happens when the user taps the button.
  String? get handoffSummary => _handoffSummary;

  /// Whether the agent has an unread response (added while overlay was hidden).
  /// Used by the FAB to show a notification badge.
  bool get hasUnreadResponse => _hasUnreadResponse;

  /// Whether the overlay should enter "action mode" — a compact, semi-transparent
  /// state that lets the user see the app underneath while the agent works.
  ///
  /// True when the agent is processing, has executed at least one screen-changing
  /// tool (navigation, tap, scroll), and is NOT paused waiting for user input.
  bool get isActionMode =>
      _isActionFeedVisible &&
      _isProcessing &&
      !_waitingForUserResponse &&
      _hasExecutedScreenChangingTool;

  /// Whether the compact response popup is currently visible above the FAB.
  bool get isResponsePopupVisible => _isResponsePopupVisible;

  /// The type of the response popup (action confirmation vs info card).
  AiResponseType get responsePopupType => _responsePopupType;

  /// The text content shown in the response popup.
  String? get responsePopupText => _responsePopupText;

  /// The most recent agent-assisted action (successful handoff), if any.
  ///
  // ---------------------------------------------------------------------------
  // Initialization
  // ---------------------------------------------------------------------------

  void _init() {
    AiLogger.log('Initializing AiAssistantController', tag: 'Controller');
    // 1. Context engine.
    _walker = SemanticsWalker();
    _walker.ensureSemantics();

    _contextCache = ContextCache(
      screenTtl: _config.contextCacheTtl,
      onCaptureScreen: _walker.captureScreenContext,
      onCaptureGlobal: _config.globalContextProvider,
    );
    _contextInvalidator = ContextInvalidator(cache: _contextCache);
    _contextInvalidator.attach();

    _routeDiscovery = RouteDiscovery(
      knownRoutes: _config.knownRoutes,
      routeDescriptions: _config.routeDescriptions,
    );
    navigatorObserver = AiNavigatorObserver(
      onRouteChanged: (route) {
        _contextCache.invalidateScreen();
        _emit(AiEventType.routeChanged, {
          'toRoute': route,
        });
      },
    );

    // 2. Action execution.
    _executor = ActionExecutor(
      walker: _walker,
      onNavigateToRoute: _config.navigateToRoute,
      navigatorObserver: navigatorObserver,
      knownRoutes: _config.knownRoutes,
    );

    // 3. Tool registry — built-in + custom tools.
    _toolRegistry = ToolRegistry();
    _toolRegistry.registerAll(
      createBuiltInTools(
        BuiltInToolHandlers(
          onTap: (label, {parentContext}) => _unwrapResult(
            _executor.tapElement(label, parentContext: parentContext),
          ),
          onSetText: (label, text, {parentContext}) => _unwrapResult(
            _executor.setText(label, text, parentContext: parentContext),
          ),
          onScroll: (direction) => _unwrapResult(_executor.scroll(direction)),
          onNavigate: (routeName) =>
              _unwrapResult(_executor.navigateToRoute(routeName)),
          onGoBack: () => _unwrapResult(_executor.goBack()),
          onGetScreenContent: () => _unwrapResult(_executor.getScreenContent()),
          onLongPress: (label, {parentContext}) => _unwrapResult(
            _executor.longPress(label, parentContext: parentContext),
          ),
          onIncrease: (label) => _unwrapResult(_executor.increaseValue(label)),
          onDecrease: (label) => _unwrapResult(_executor.decreaseValue(label)),
          onAskUser: _handleAskUser,
          onHandoff: _config.confirmDestructiveActions ? _handleHandoff : null,
        ),
      ),
    );

    // Register any developer-provided custom tools.
    if (_config.customTools.isNotEmpty) {
      _toolRegistry.registerAll(_config.customTools);
    }

    // 4. Conversation memory + ReAct agent.
    _memory = ConversationMemory(
      maxMessages: _config.maxAgentIterations * 4 + 20,
    );
    _agent = ReactAgent(
      provider: _config.provider,
      toolRegistry: _toolRegistry,
      memory: _memory,
      maxIterations: _config.maxAgentIterations,
      systemPromptOverride: _config.systemPromptOverride,
      assistantName: _config.assistantName,
      confirmDestructiveActions: _config.confirmDestructiveActions,
      appPurpose: _config.appPurpose,
      fewShotExamples: _config.fewShotExamples,
      domainInstructions: _config.domainInstructions,
      maxVerificationAttempts: _config.maxVerificationAttempts,
    );

    // 5. Voice services (lazy-initialized on first use).
    if (_config.voiceEnabled) {
      _voiceInput = VoiceInputService();
      _voiceOutput = VoiceOutputService();
    }

    AiLogger.log(
      'Initialized: ${_toolRegistry.length} tools registered, '
      'voice=${_config.voiceEnabled}, '
      'maxIterations=${_config.maxAgentIterations}',
      tag: 'Controller',
    );
  }

  /// Unwrap a [ToolResult] into the data map, throwing on failure so the
  /// [ToolRegistry] can catch it and create a proper failed [ToolResult].
  static Future<Map<String, dynamic>> _unwrapResult(
    Future<ToolResult> future,
  ) async {
    final result = await future;
    if (!result.success) {
      throw Exception(result.error ?? 'Action failed');
    }
    return result.data;
  }

  // ---------------------------------------------------------------------------
  // Processing timeout — pauses during user-facing waits
  // ---------------------------------------------------------------------------

  /// Start (or restart) the processing timer. Fires after 3 minutes of ACTIVE
  /// agent processing and sets [_cancelRequested] to gracefully stop the agent.
  /// The timer is paused during handoff and ask_user waits so the user has
  /// unlimited time to respond.
  void _startProcessingTimer() {
    _processingTimer?.cancel();
    _processingTimer = Timer(const Duration(minutes: 3), () {
      if (_isProcessing && !_isHandoffMode && !_waitingForUserResponse) {
        AiLogger.log('Processing timeout (3 min active)', tag: 'Controller');
        _emit(AiEventType.agentTimeout, {
          'actionCount': _actionSteps.length,
        });
        _cancelRequested = true;
        _safeNotify();
      }
    });
  }

  void _pauseProcessingTimer() => _processingTimer?.cancel();

  /// Resume with a fresh 3-minute window (each user interaction resets the clock).
  void _resumeProcessingTimer() => _startProcessingTimer();

  // ---------------------------------------------------------------------------
  // Handoff mode — user taps the real button
  // ---------------------------------------------------------------------------

  /// Handler for the hand_off_to_user tool. Clears the overlay, shows a
  /// minimal floating indicator, and waits for the user to tap the real
  /// action button on the app screen (or cancel).
  ///
  /// Resolution triggers:
  /// 1. Route change detected → user tapped the button and app navigated
  /// 2. User taps "I'm done" on indicator → manual confirmation
  /// 3. User taps "Cancel" on indicator → cancellation
  Future<String> _handleHandoff(String buttonLabel, String summary) async {
    AiLogger.log(
      'hand_off_to_user: button="$buttonLabel", summary="$summary"',
      tag: 'Controller',
    );

    _isHandoffMode = true;
    _handoffButtonLabel = buttonLabel;
    _handoffSummary = summary;
    _progressText = null;
    _emit(AiEventType.handoffStarted, {
      'buttonLabel': buttonLabel,
      'summary': summary,
    });

    // Show the handoff message in the chat history.
    _messages.add(
      AiChatMessage(
        id: _uuid.v4(),
        role: AiMessageRole.assistant,
        content: 'Everything is ready! Tap "$buttonLabel" to confirm.',
        timestamp: DateTime.now(),
      ),
    );
    _safeNotify();

    // Set up a completer that resolves when the user acts.
    _handoffCompleter = Completer<String>();

    // Listen for route changes — if the route changes, the user likely
    // tapped the button and the app navigated to a confirmation/success screen.
    final routeBefore = AiNavigatorObserver.currentRoute;
    _handoffRouteListener = () {
      final routeNow = AiNavigatorObserver.currentRoute;
      if (routeNow != routeBefore &&
          _handoffCompleter != null &&
          !_handoffCompleter!.isCompleted) {
        AiLogger.log(
          'Handoff: route changed $routeBefore → $routeNow',
          tag: 'Controller',
        );
        _handoffCompleter!.complete(
          'User tapped the button. Screen changed from '
          '"$routeBefore" to "$routeNow". '
          'Call get_screen_content to see the result and report to the user.',
        );
      }
    };
    navigatorObserver.onRouteChanged = (route) {
      // Keep the original cache invalidation behavior.
      _contextCache.invalidateScreen();
      // Check for handoff resolution.
      _handoffRouteListener?.call();
    };

    // Pause the processing timer — user has unlimited time to act.
    _pauseProcessingTimer();

    try {
      // 5-minute timeout — if the user doesn't act, auto-cancel so the
      // agent doesn't hang indefinitely.
      final result = await _handoffCompleter!.future.timeout(
        const Duration(minutes: 5),
        onTimeout: () {
          AiLogger.warn('Handoff timed out after 5 minutes', tag: 'Controller');
          return 'User did not act within 5 minutes. The handoff timed out. '
              'Inform the user the action was not completed and they can try again.';
        },
      );
      AiLogger.log('Handoff resolved: $result', tag: 'Controller');
      final resolution = result.contains('cancelled')
          ? 'cancelled'
          : result.contains('timed out')
              ? 'timeout'
              : result.contains('route changed') ||
                      result.contains('Screen changed')
                  ? 'route_change'
                  : 'manual';
      final routeAfter = AiNavigatorObserver.currentRoute;

      _emit(AiEventType.handoffCompleted, {
        'buttonLabel': buttonLabel,
        'summary': summary,
        'resolution': resolution,
        'routeBefore': routeBefore,
        'routeAfter': routeAfter,
        'userMessage': _currentTaskMessage,
        'wasVoice': _currentTaskIsVoice,
        'durationMs': _currentTaskStartedAt != null
            ? DateTime.now().difference(_currentTaskStartedAt!).inMilliseconds
            : null,
      });

      // On cancel, keep overlay so user can give new instructions.
      // On success (route change or manual Done), hide overlay so user
      // sees the app's confirmation/result screen.
      final wasCancelled = result.contains('cancelled');
      _exitHandoffMode(keepOverlay: wasCancelled);
      _resumeProcessingTimer();
      return result;
    } catch (e) {
      _exitHandoffMode(keepOverlay: true);
      _resumeProcessingTimer();
      rethrow;
    }
  }

  /// Resolve handoff from the UI — user tapped "Done" on the indicator.
  void resolveHandoff() {
    if (_handoffCompleter != null && !_handoffCompleter!.isCompleted) {
      AiLogger.log('Handoff: user confirmed manually', tag: 'Controller');
      _handoffCompleter!.complete(
        'User confirmed they completed the action. '
        'Call get_screen_content to see the result and report to the user.',
      );
    }
  }

  /// Cancel handoff from the UI — user tapped "Cancel" on the indicator.
  void cancelHandoff() {
    if (_handoffCompleter != null && !_handoffCompleter!.isCompleted) {
      AiLogger.log('Handoff: user cancelled', tag: 'Controller');
      _handoffCompleter!.complete(
        'User cancelled the action. Do NOT proceed. '
        'Inform the user the action was cancelled.',
      );
    }
  }

  /// Exit handoff mode and restore normal state.
  ///
  /// [keepOverlay] controls what happens to the overlay:
  /// - `true` (cancel): overlay reappears so user can give new instructions
  /// - `false` (success): overlay stays hidden so user sees the app result
  void _exitHandoffMode({bool keepOverlay = false}) {
    _isHandoffMode = false;
    _handoffButtonLabel = null;
    _handoffSummary = null;
    _handoffCompleter = null;
    _handoffRouteListener = null;
    // Restore the original route change callback.
    navigatorObserver.onRouteChanged = (_) => _contextCache.invalidateScreen();
    // On success, hide overlay silently (without stopping the agent) so the
    // user sees the app's confirmation/result screen. The agent continues
    // processing in the background and the response will be available when
    // the user opens the overlay via the FAB.
    if (!keepOverlay) {
      _isOverlayVisible = false;
    }
    _safeNotify();
  }

  // ---------------------------------------------------------------------------
  // ask_user — pause agent and wait for user input
  // ---------------------------------------------------------------------------

  /// Handler for the ask_user tool. Pauses agent execution, shows the
  /// question in chat, and waits for the user to respond.
  ///
  /// Auto-parses numbered options and yes/no patterns in the question
  /// text into interactive buttons for quick replies.
  Future<String> _handleAskUser(String question) async {
    AiLogger.log('ask_user: "$question"', tag: 'Controller');
    _emit(AiEventType.askUserStarted, {'question': question});
    _waitingForUserResponse = true;
    _progressText = null;

    // Auto-parse the question text into rich content with buttons.
    final richContent = _parseAskUserContent(question);

    // Show the question as an assistant message in the chat.
    _messages.add(
      AiChatMessage(
        id: _uuid.v4(),
        role: AiMessageRole.assistant,
        content: question,
        timestamp: DateTime.now(),
        richContent: richContent,
      ),
    );
    _safeNotify();

    // Pause the processing timer — user has unlimited time to respond.
    _pauseProcessingTimer();

    // Create a completer and wait for the user's response.
    _userResponseCompleter = Completer<String>();
    try {
      final response = await _userResponseCompleter!.future;
      AiLogger.log('ask_user response: "$response"', tag: 'Controller');
      _emit(AiEventType.askUserCompleted, {
        'question': question,
        'response': response,
      });
      _waitingForUserResponse = false;
      _safeNotify();
      _resumeProcessingTimer();
      return response;
    } catch (e) {
      _waitingForUserResponse = false;
      _safeNotify();
      _resumeProcessingTimer();
      rethrow;
    }
  }

  // ---------------------------------------------------------------------------
  // ask_user auto-parsing — extract buttons from question text
  // ---------------------------------------------------------------------------

  /// Pattern for numbered options: "1) Option text" or "1. Option text"
  static final _numberedOptionPattern = RegExp(r'^\s*(\d+)[.)]\s+(.+)$', multiLine: true);

  /// Pattern for lettered options: "a) Option text" or "A. Option text"
  static final _letteredOptionPattern = RegExp(r'^\s*([a-zA-Z])[.)]\s+(.+)$', multiLine: true);

  /// Words that suggest a yes/no or confirm/cancel question.
  static const _confirmPatterns = [
    'confirm',
    'proceed',
    'continue',
    'should i',
    'shall i',
    'do you want',
    'would you like',
    'is that correct',
    'is this correct',
    'are you sure',
  ];

  /// Parse an ask_user question into rich content with auto-detected buttons.
  ///
  /// Detects:
  /// 1. Numbered lists ("1) Option A  2) Option B") → option buttons
  /// 2. Lettered lists ("a) Small  b) Large") → option buttons
  /// 3. Yes/no confirmation patterns → confirm/cancel buttons
  ///
  /// Returns null if no patterns detected (falls back to plain text).
  List<ChatContent>? _parseAskUserContent(String question) {
    // Try numbered options first.
    var matches = _numberedOptionPattern.allMatches(question).toList();
    if (matches.length >= 2) {
      return _buildOptionsContent(question, matches);
    }

    // Try lettered options.
    matches = _letteredOptionPattern.allMatches(question).toList();
    if (matches.length >= 2) {
      return _buildOptionsContent(question, matches);
    }

    // Try yes/no confirmation pattern.
    final lower = question.toLowerCase();
    for (final pattern in _confirmPatterns) {
      if (lower.contains(pattern)) {
        return [
          TextContent(question),
          const ButtonsContent(
            buttons: [
              ChatButton(
                label: 'Yes',
                style: ChatButtonStyle.success,
                icon: IconData(0xe156, fontFamily: 'MaterialIcons'), // check
              ),
              ChatButton(
                label: 'No',
                style: ChatButtonStyle.destructive,
                icon: IconData(0xe16a, fontFamily: 'MaterialIcons'), // close
              ),
            ],
          ),
        ];
      }
    }

    return null;
  }

  /// Build rich content from a question with extracted option matches.
  ///
  /// Splits the question into the preamble text (before the first option)
  /// and the option buttons.
  List<ChatContent> _buildOptionsContent(
    String question,
    List<RegExpMatch> matches,
  ) {
    // Extract the preamble — text before the first option.
    final firstMatchStart = matches.first.start;
    final preamble = question.substring(0, firstMatchStart).trim();

    // Extract option labels.
    final buttons = matches.map((m) {
      final label = m.group(2)!.trim();
      return ChatButton(label: label, style: ChatButtonStyle.primary);
    }).toList();

    return [
      if (preamble.isNotEmpty) TextContent(preamble),
      ButtonsContent(
        buttons: buttons,
        layout: buttons.any((b) => b.label.length > 30)
            ? ButtonLayout.column
            : ButtonLayout.wrap,
      ),
    ];
  }

  // ---------------------------------------------------------------------------
  // Post-task suggestion chips
  // ---------------------------------------------------------------------------

  /// Build contextual suggestion chips based on what the agent just did.
  ///
  /// Delegates to the developer-provided [PostTaskChipsBuilder] callback
  /// from the config. Returns null if no callback is configured or if the
  /// callback returns null. Also suppresses chips for questions and very
  /// short confirmations.
  ButtonsContent? _buildSuggestionChips(AgentResponse response) {
    if (_config.postTaskChipsBuilder == null) return null;

    // Don't add suggestions to very short confirmations — they auto-close.
    if (response.text.length <= 40) return null;

    // Don't add suggestions if no actions were performed (simple text response).
    if (response.actions.isEmpty) return null;

    // Don't add suggestions if the response is a question — the user needs
    // to answer, not navigate away. This catches cases where the LLM returns
    // a question as text instead of using ask_user.
    final trimmedText = response.text.trim();
    if (trimmedText.endsWith('?')) return null;

    return _config.postTaskChipsBuilder!(response);
  }

  // ---------------------------------------------------------------------------
  // Cancellation — stop the agent mid-execution
  // ---------------------------------------------------------------------------

  /// Request the agent to stop execution. If the agent is waiting for user
  /// input (via ask_user), the completer is resolved with a cancellation
  /// message so the agent loop can exit gracefully.
  void requestStop() {
    AiLogger.log('Stop requested by user', tag: 'Controller');
    _emit(AiEventType.stopRequested);
    _cancelRequested = true;

    // If waiting for user response, resolve the completer so the agent
    // doesn't hang forever.
    if (_waitingForUserResponse &&
        _userResponseCompleter != null &&
        !_userResponseCompleter!.isCompleted) {
      _userResponseCompleter!.complete('The user stopped the task.');
      _userResponseCompleter = null;
      _waitingForUserResponse = false;
    }
    // If in handoff mode, cancel it and close the overlay.
    if (_isHandoffMode) {
      cancelHandoff();
      _isOverlayVisible = false;
    }
    _safeNotify();
  }

  // ---------------------------------------------------------------------------
  // Chat actions
  // ---------------------------------------------------------------------------

  /// Send a suggestion chip message. Emits [AiEventType.suggestionChipTapped]
  /// before delegating to [sendMessage].
  Future<void> sendSuggestion(String label, String message) async {
    _emit(AiEventType.suggestionChipTapped, {
      'label': label,
      'message': message,
    });
    return sendMessage(message);
  }

  /// Send a text message from the user.
  Future<void> sendMessage(String text, {bool isVoice = false}) async {
    if (text.trim().isEmpty) return;

    // If the agent is waiting for user response (ask_user tool), complete
    // the completer with the user's message instead of starting a new run.
    if (_waitingForUserResponse &&
        _userResponseCompleter != null &&
        !_userResponseCompleter!.isCompleted) {
      AiLogger.log('User response to ask_user: "$text"', tag: 'Controller');
      _messages.add(
        AiChatMessage(
          id: _uuid.v4(),
          role: AiMessageRole.user,
          content: text,
          timestamp: DateTime.now(),
          isVoice: isVoice,
        ),
      );
      _safeNotify();
      _userResponseCompleter!.complete(text);
      _userResponseCompleter = null;
      return;
    }

    // Don't start a new run while already processing — queue for later.
    if (_isProcessing) {
      AiLogger.log('Queuing message (agent busy): "$text"', tag: 'Controller');
      _pendingMessage = text;
      _pendingIsVoice = isVoice;
      return;
    }

    // Dismiss any visible popup and ensure overlay is open for the new request.
    if (_isResponsePopupVisible) dismissResponsePopup();
    if (!_isOverlayVisible) {
      _isOverlayVisible = true;
      _hasUnreadResponse = false;
    }

    AiLogger.log('sendMessage: "$text" (voice=$isVoice)', tag: 'Controller');
    _emit(AiEventType.messageSent, {
      'message': text,
      'isVoice': isVoice,
    });

    // Track whether this task originated from voice for TTS/haptics.
    _currentTaskIsVoice = isVoice;
    _lastSpokenProgress = null;
    _partialTranscription = null;

    // Store task context for handoff event enrichment.
    _currentTaskMessage = text;
    _currentTaskStartedAt = DateTime.now();

    // Add user message to chat.
    _messages.add(
      AiChatMessage(
        id: _uuid.v4(),
        role: AiMessageRole.user,
        content: text,
        timestamp: DateTime.now(),
        isVoice: isVoice,
      ),
    );
    _isProcessing = true;

    // Reset action feed and cancellation for this new request.
    _actionSteps.clear();
    _isActionFeedVisible = false;
    _finalResponseText = null;
    _progressText = null;
    _cancelRequested = false;
    _hasExecutedScreenChangingTool = false;
    _safeNotify();

    final stopwatch = Stopwatch()..start();
    try {
      // Start the processing timer — fires after 3 minutes of ACTIVE agent
      // work. Paused automatically during handoff and ask_user waits so the
      // user has unlimited time to respond.
      _startProcessingTimer();
      _emit(AiEventType.conversationStarted, {
        'message': text,
        'isVoice': isVoice,
        'conversationLength': _messages.length,
      });

      // Run the ReAct agent with streaming callbacks for the action feed.
      // The context builder is called each iteration so the LLM always
      // sees the current screen state after actions change the UI.
      // A generous 10-minute safety timeout prevents runaway futures.
      final response = await _agent
          .run(
            userMessage: text,
            contextBuilder: _buildContext,
            onToolStart: _onToolStart,
            onToolComplete: _onToolComplete,
            onThought: _onThought,
            shouldCancel: () => _cancelRequested,
            onEvent: _config.onEvent,
          )
          .timeout(
            const Duration(minutes: 10),
            onTimeout: () => const AgentResponse(
              text: 'The session expired. Please try again.',
            ),
          );

      // If tools were executed, show the final response in the feed briefly.
      if (_isActionFeedVisible) {
        _finalResponseText = response.text;
        _safeNotify();

        // Brief pause so the user sees the completed feed + final text.
        await Future.delayed(const Duration(milliseconds: 800));
      }

      // Transition: hide action feed, add the normal chat bubble.
      _isActionFeedVisible = false;
      AiLogger.log(
        'Agent response: "${response.text.length > 100 ? '${response.text.substring(0, 100)}...' : response.text}" '
        '(${response.actions.length} actions)',
        tag: 'Controller',
      );
      // Build rich content for the response — include suggestion chips
      // for successful completions so the user has quick follow-up options.
      // Also detect questions-as-text (LLM returned a question without using
      // ask_user) and auto-generate interactive buttons so the user can tap
      // to respond instead of typing.
      final responseType = _classifyResponse(response);
      List<ChatContent>? responseRichContent;
      if (responseType != AiResponseType.error) {
        final suggestions = _buildSuggestionChips(response);
        if (suggestions != null) {
          responseRichContent = [
            TextContent(response.text),
            suggestions,
          ];
        } else {
          // If no suggestion chips and the response looks like a question
          // with embedded options, auto-generate interactive buttons.
          // This handles cases where the LLM returns a question as plain
          // text instead of using ask_user — the user can still tap to reply.
          final trimmedText = response.text.trim();
          if (trimmedText.endsWith('?') || trimmedText.contains('?')) {
            responseRichContent = _parseAskUserContent(response.text);
          }
        }
      }

      _messages.add(
        AiChatMessage(
          id: _uuid.v4(),
          role: AiMessageRole.assistant,
          content: response.text,
          timestamp: DateTime.now(),
          actions: response.actions.isNotEmpty ? response.actions : null,
          richContent: responseRichContent,
        ),
      );

      stopwatch.stop();
      _emit(AiEventType.conversationCompleted, {
        'response': response.text.length > 200
            ? '${response.text.substring(0, 200)}...'
            : response.text,
        'responseType': responseType.name,
        'totalActions': response.actions.length,
        'durationMs': stopwatch.elapsedMilliseconds,
        'wasVoice': isVoice,
      });
      _emit(AiEventType.messageReceived, {
        'response': response.text.length > 200
            ? '${response.text.substring(0, 200)}...'
            : response.text,
        'responseType': responseType.name,
        'actionCount': response.actions.length,
      });

      // Post-task behavior depends on response type:
      //
      // ACTION COMPLETE → auto-close overlay, show popup ("Added to cart!")
      //   The user's next step is to interact with the APP, not the agent.
      //
      // INFO RESPONSE → overlay STAYS OPEN for follow-up conversation
      //   The user is talking to the agent, not the app. They'll want to
      //   read the response and might ask follow-ups.
      //
      // ERROR → overlay stays open for retry/correction.
      //
      // If overlay was already hidden (e.g. after handoff), show popup
      // regardless of type since the user needs to see the result somewhere.
      if (_config.autoCloseOnComplete &&
          _isOverlayVisible &&
          responseType == AiResponseType.actionComplete) {
        // Auto-close: agent did something, user needs to see/interact with the app.
        _isOverlayVisible = false;
        _safeNotify();
        await Future.delayed(const Duration(milliseconds: 350));
        if (!_disposed) _showResponsePopup(response.text, responseType);
      } else if (!_isOverlayVisible) {
        // Overlay was already hidden (e.g. after handoff success) — show popup.
        _showResponsePopup(response.text, responseType);
      }
      // Info responses and errors: overlay stays open — user continues chatting.

      // If the user spoke, speak a concise summary back and provide haptic.
      if (_currentTaskIsVoice && _voiceOutput != null) {
        if (_config.enableHaptics) HapticFeedback.heavyImpact();
        if (_config.enableTts) {
          _emit(AiEventType.ttsStarted, {
            'text': response.text.length > 100
                ? '${response.text.substring(0, 100)}...'
                : response.text,
            'isProgress': false,
          });
          _voiceOutput!.speakSummary(response.text);
        }
      }
    } catch (e, stack) {
      AiLogger.error(
        'sendMessage failed',
        error: e,
        stackTrace: stack,
        tag: 'Controller',
      );
      stopwatch.stop();
      _emit(AiEventType.conversationError, {
        'error': e.toString(),
        'durationMs': stopwatch.elapsedMilliseconds,
      });
      _isActionFeedVisible = false;
      final errorMsg = _currentTaskIsVoice
          ? _friendlyVoiceError(e)
          : _friendlyError(e);
      _messages.add(
        AiChatMessage(
          id: _uuid.v4(),
          role: AiMessageRole.assistant,
          content: errorMsg,
          timestamp: DateTime.now(),
        ),
      );
      // Speak the error if this was a voice task.
      if (_currentTaskIsVoice && _voiceOutput != null && _config.enableTts) {
        _voiceOutput!.speak(errorMsg);
      }
    } finally {
      _processingTimer?.cancel();
      _isProcessing = false;
      _actionSteps.clear();
      _finalResponseText = null;
      _progressText = null;
      _waitingForUserResponse = false;
      _cancelRequested = false;
      _hasExecutedScreenChangingTool = false;
      if (_isHandoffMode) _exitHandoffMode(keepOverlay: true);
      _safeNotify();

      // Drain the pending message queue — process next queued message.
      if (_pendingMessage != null && !_disposed) {
        final queued = _pendingMessage!;
        final queuedVoice = _pendingIsVoice;
        _pendingMessage = null;
        _pendingIsVoice = false;
        // Schedule after current microtask to avoid re-entrancy.
        Future.microtask(() => sendMessage(queued, isVoice: queuedVoice));
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Interactive button handling
  // ---------------------------------------------------------------------------

  /// Called when the user taps an interactive button in a chat message.
  ///
  /// Disables all buttons in the message (prevents double-tap), highlights
  /// the tapped button, and either resolves an active ask_user prompt or
  /// sends the button label as a new user message.
  void handleButtonTap(
    AiChatMessage message,
    ChatButton button,
    int buttonIndex,
  ) {
    // Disable all buttons in this message and highlight the tapped one.
    message.buttonsDisabled = true;
    message.tappedButtonIndex = buttonIndex;
    _emit(AiEventType.buttonTapped, {
      'buttonLabel': button.label,
      'wasAskUserResponse': _waitingForUserResponse,
    });
    _safeNotify();

    // If the agent is waiting for user input (ask_user), resolve the
    // completer with the button label instead of starting a new run.
    if (_waitingForUserResponse &&
        _userResponseCompleter != null &&
        !_userResponseCompleter!.isCompleted) {
      AiLogger.log(
        'Button tap resolving ask_user: "${button.label}"',
        tag: 'Controller',
      );
      _messages.add(
        AiChatMessage(
          id: _uuid.v4(),
          role: AiMessageRole.user,
          content: button.label,
          timestamp: DateTime.now(),
        ),
      );
      _safeNotify();
      _userResponseCompleter!.complete(button.label);
      _userResponseCompleter = null;
      return;
    }

    // Otherwise, send the button label as a new user message.
    sendMessage(button.label);
  }

  /// Tools that are internal to the agent (observations, not user-visible actions).
  static const _internalTools = {'get_screen_content'};

  /// Tools that change the screen and require cache invalidation.
  static const _screenChangingTools = {
    'tap_element',
    'set_text',
    'scroll',
    'navigate_to_route',
    'go_back',
    'long_press_element',
    'increase_value',
    'decrease_value',
  };

  /// Called when a tool starts executing in the ReAct loop.
  void _onToolStart(String toolName, Map<String, dynamic> args) {
    _emit(AiEventType.toolExecutionStarted, {
      'toolName': toolName,
      'arguments': args,
    });

    // Internal tools, ask_user, and hand_off_to_user are not shown in the action feed.
    if (_internalTools.contains(toolName) ||
        toolName == 'ask_user' ||
        toolName == 'hand_off_to_user') {
      return;
    }

    // Track when a screen-changing tool is executed for action mode.
    if (_screenChangingTools.contains(toolName)) {
      _hasExecutedScreenChangingTool = true;
    }

    // Show the action feed on the first user-facing tool call.
    if (!_isActionFeedVisible) {
      _isActionFeedVisible = true;
    }
    _actionSteps.add(ActionStep.started(toolName: toolName, arguments: args));
    // Haptic tick on each visible action.
    if (_config.enableHaptics) HapticFeedback.selectionClick();
    _safeNotify();
  }

  /// Called when a tool finishes executing in the ReAct loop.
  void _onToolComplete(
    String toolName,
    Map<String, dynamic> args,
    ToolResult result,
  ) {
    _emit(AiEventType.toolExecutionCompleted, {
      'toolName': toolName,
      'arguments': args,
      'success': result.success,
      if (!result.success) 'error': result.error,
    });

    // Emit semantic events for specific tool completions.
    if (toolName == 'get_screen_content' && result.success) {
      _emit(AiEventType.screenContentCaptured, {
        'route': AiNavigatorObserver.currentRoute,
      });
    }
    if (toolName == 'navigate_to_route') {
      _emit(AiEventType.navigationExecuted, {
        'route': args['route_name'] ?? args['routeName'] ?? '',
        'success': result.success,
      });
    }

    // Invalidate screen cache after actions that change the screen,
    // so the next iteration's context rebuild captures fresh state.
    if (_screenChangingTools.contains(toolName)) {
      _contextCache.invalidateScreen();
    }

    // Internal tools, ask_user, and hand_off_to_user are not shown in the action feed.
    if (_internalTools.contains(toolName) ||
        toolName == 'ask_user' ||
        toolName == 'hand_off_to_user') {
      return;
    }

    // Find the matching in-progress step and mark it completed/failed.
    final index = _actionSteps.lastIndexWhere(
      (s) => s.toolName == toolName && s.status == ActionStepStatus.inProgress,
    );
    if (index != -1) {
      _actionSteps[index] = _actionSteps[index].copyWith(
        status: result.success
            ? ActionStepStatus.completed
            : ActionStepStatus.failed,
        error: result.error,
        completedAt: DateTime.now(),
      );
      _safeNotify();
    }
  }

  /// Called when the LLM emits reasoning/status text alongside tool calls.
  /// Updates the progressive status shown in the action feed header.
  /// Sanitizes the text to remove meta-commentary before displaying.
  void _onThought(String thought) {
    final sanitized = _sanitizeThought(thought);
    if (sanitized == null) return; // Entirely meta — don't update.

    _progressText = sanitized;

    // Show the action feed if not already visible (thought can arrive
    // before the first tool call starts).
    if (!_isActionFeedVisible) {
      _isActionFeedVisible = true;
    }

    // Voice progress: speak sanitized thoughts aloud (throttled to max
    // once per 4 seconds) so the user hears what the agent is doing.
    if (_currentTaskIsVoice && _voiceOutput != null && _config.enableTts && sanitized.length > 5) {
      final now = DateTime.now();
      if (_lastSpokenProgress == null ||
          now.difference(_lastSpokenProgress!) > const Duration(seconds: 4)) {
        _lastSpokenProgress = now;
        _emit(AiEventType.ttsStarted, {
          'text': sanitized,
          'isProgress': true,
        });
        _voiceOutput!.speak(sanitized);
      }
    }

    _safeNotify();
  }

  /// Filter meta-commentary from LLM thoughts before showing to users.
  ///
  /// The system prompt tells the LLM to write user-friendly status text,
  /// but it sometimes leaks internal reasoning like "Let me call
  /// get_screen_content...". This filter catches purely technical thoughts
  /// while allowing user-friendly progress messages through.
  static String? _sanitizeThought(String thought) {
    final trimmed = thought.trim();
    if (trimmed.isEmpty) return null;

    final lower = trimmed.toLowerCase();

    // Drop entirely if it's purely internal meta-commentary.
    // These patterns indicate the LLM is talking to itself, not the user.
    const metaPatterns = [
      'calling ',
      'executing ',
      'using the ',
      'looking at the screen',
      'the current screen shows',
      'based on the screen',
      'according to the screen',
    ];

    for (final pattern in metaPatterns) {
      if (lower.startsWith(pattern)) return null;
    }

    // Drop if it's purely a tool reference with no user-facing context.
    // e.g. "I'll call get_screen_content" but NOT "Searching for onion..."
    const toolNames = [
      'get_screen_content',
      'tap_element',
      'set_text',
      'navigate_to_route',
      'scroll',
      'go_back',
      'long_press_element',
      'ask_user',
      'hand_off_to_user',
      'increase_value',
      'decrease_value',
    ];
    for (final tool in toolNames) {
      if (lower.contains(tool)) return null;
    }

    return trimmed;
  }

  /// Dismiss the action feed manually (e.g. user taps away).
  void dismissActionFeed() {
    _isActionFeedVisible = false;
    _safeNotify();
  }

  /// Convert raw exceptions into user-friendly messages.
  static String _friendlyError(Object error) {
    final msg = error.toString();

    // Network / connectivity errors.
    if (msg.contains('SocketException') || msg.contains('HandshakeException')) {
      return 'It looks like there\'s no internet connection. Please check your network and try again.';
    }
    if (msg.contains('TimeoutException') || msg.contains('timed out')) {
      return 'The request timed out. Please try again.';
    }

    // HTTP status codes from LLM providers.
    if (msg.contains('401') || msg.contains('Unauthorized')) {
      return 'Authentication failed. Please check the API key configuration.';
    }
    if (msg.contains('429') || msg.contains('rate limit')) {
      return 'Too many requests. Please wait a moment and try again.';
    }
    if (msg.contains('500') || msg.contains('502') || msg.contains('503')) {
      return 'The AI service is temporarily unavailable. Please try again shortly.';
    }

    // Generic fallback — no raw stack trace.
    return 'Something went wrong. Please try again.';
  }

  /// Concise, speakable error messages for voice-initiated tasks.
  static String _friendlyVoiceError(Object error) {
    final msg = error.toString();
    if (msg.contains('SocketException') || msg.contains('HandshakeException')) {
      return "Can't reach the server. Check your connection.";
    }
    if (msg.contains('TimeoutException') || msg.contains('timed out')) {
      return 'That took too long. Try again?';
    }
    if (msg.contains('429') || msg.contains('rate limit')) {
      return 'Too many requests. Wait a moment and try again.';
    }
    return 'Something went wrong. Want to try again?';
  }

  /// Build the full app context snapshot for the LLM.
  Future<AppContextSnapshot> _buildContext() async {
    final currentRoute = AiNavigatorObserver.currentRoute;

    // Use the cache for screen context.
    var screenContext = _contextCache.getScreenContext(currentRoute);

    // Screen stabilization: after a cache rebuild (screen was dirty),
    // wait briefly and re-capture to handle content that loads asynchronously
    // (e.g. ride options after confirming a destination, search results, etc.).
    // Skip if the screen already has enough elements (content loaded fast).
    if (_contextCache.wasDirty && screenContext.elements.length <= 5) {
      final initialElements = screenContext.elements.length;
      int stabilizationAttempts = 0;
      for (int attempt = 0; attempt < 4; attempt++) {
        await Future.delayed(const Duration(milliseconds: 500));
        _contextCache.invalidateScreen();
        final fresh = _contextCache.getScreenContext(currentRoute);
        final oldCount = screenContext.elements.length;
        final newCount = fresh.elements.length;
        stabilizationAttempts++;
        if (newCount > 5) {
          screenContext = fresh;
          break;
        }
        AiLogger.log(
          'Screen stabilization: element count '
          '$oldCount → $newCount, '
          '${newCount <= 5 ? 'too few elements, ' : ''}'
          'retrying (attempt ${attempt + 1}/4)',
          tag: 'Controller',
        );
        screenContext = fresh;
      }
      _emit(AiEventType.screenStabilizationAttempted, {
        'route': currentRoute,
        'attempts': stabilizationAttempts,
        'initialElements': initialElements,
        'finalElements': screenContext.elements.length,
      });
    }

    // Cache the current screen knowledge for future cross-screen commands.
    if (currentRoute != null) {
      AiNavigatorObserver.cacheScreenKnowledge(currentRoute, screenContext);
    }

    // Get global state (also via cache).
    final globalState = await _contextCache.getGlobalContext();

    // Capture screenshot if enabled and the screen changed.
    // Only capture on dirty rebuilds to avoid redundant captures.
    Uint8List? screenshot;
    if (_screenshotCapture != null && _contextCache.wasDirty) {
      screenshot = await _screenshotCapture!.capture();
      AiLogger.log(
        'Screenshot captured: ${screenshot != null ? '${(screenshot.length / 1024).toStringAsFixed(1)}KB' : 'failed'}',
        tag: 'Controller',
      );
    }

    return AppContextSnapshot(
      currentRoute: currentRoute,
      navigationStack: AiNavigatorObserver.routeStack,
      screenContext: screenContext,
      availableRoutes: _routeDiscovery.getAvailableRoutes(),
      globalState: globalState.isNotEmpty ? globalState : null,
      screenKnowledge: AiNavigatorObserver.screenKnowledge,
      appManifest: _config.appManifest,
      screenshot: screenshot,
    );
  }

  // ---------------------------------------------------------------------------
  // Response popup — compact card shown after auto-close
  // ---------------------------------------------------------------------------

  /// Classify a completed agent response for post-task UI behavior.
  ///
  /// Uses a conservative heuristic — errs on the side of [infoResponse]
  /// (card stays visible) rather than [actionComplete] (auto-dismisses).
  ///
  /// Only classified as [actionComplete] when:
  /// 1. Agent performed MUTATING actions (tap, set_text — not just navigation)
  /// 2. The response is SHORT (≤ 80 chars — a brief confirmation, not a report)
  ///
  /// This prevents info queries that required navigation ("what's my balance?"
  /// → navigate to wallet → read screen) from being auto-dismissed.
  AiResponseType _classifyResponse(
    AgentResponse response, {
    bool isError = false,
  }) {
    if (isError) return AiResponseType.error;

    // Tools that MODIFY app state or perform user-requested actions.
    const mutatingTools = {
      'tap_element',
      'set_text',
      'long_press_element',
      'increase_value',
      'decrease_value',
      'navigate_to_route',
      'go_back',
    };
    final hasMutatingAction = response.actions.any(
      (a) => mutatingTools.contains(a.toolName),
    );

    // Info-query pattern: agent navigated somewhere THEN read the screen to
    // extract data (e.g. "what's my balance?" → navigate → get_screen_content).
    // These should stay open even if the response is short.
    final isInfoPattern = response.actions.isNotEmpty &&
        response.actions.last.toolName == 'get_screen_content' &&
        !response.actions.any((a) =>
            a.toolName == 'tap_element' ||
            a.toolName == 'set_text' ||
            a.toolName == 'long_press_element');

    // Short response + mutating tools = action confirmation ("Added to cart!")
    // Long response or no mutating tools = informational (needs reading time)
    // Info pattern (navigate → read) = informational regardless of length.
    if (hasMutatingAction && response.text.length <= 80 && !isInfoPattern) {
      return AiResponseType.actionComplete;
    }
    return AiResponseType.infoResponse;
  }

  /// Show the response popup above the FAB with the given text and type.
  void _showResponsePopup(String text, AiResponseType type) {
    _emit(AiEventType.responsePopupShown, {
      'responseType': type.name,
      'text': text.length > 100 ? '${text.substring(0, 100)}...' : text,
    });
    _isResponsePopupVisible = true;
    _responsePopupType = type;
    _responsePopupText = text;
    _hasUnreadResponse = false; // The popup IS the notification.

    // Auto-dismiss: action confirmations after 8s, info stays until dismissed.
    _responsePopupTimer?.cancel();
    if (type == AiResponseType.actionComplete) {
      _responsePopupTimer = Timer(
        const Duration(seconds: 8),
        dismissResponsePopup,
      );
    }
    _safeNotify();
  }

  /// Dismiss the response popup (called by timer, swipe, or tap-away).
  void dismissResponsePopup() {
    if (!_isResponsePopupVisible) return;
    _responsePopupTimer?.cancel();
    _isResponsePopupVisible = false;
    _responsePopupText = null;
    _safeNotify();
  }

  /// Tap the response popup to re-open the full chat.
  void expandResponsePopup() {
    dismissResponsePopup();
    showOverlay();
  }

  // ---------------------------------------------------------------------------
  // Overlay & voice controls
  // ---------------------------------------------------------------------------

  /// Toggle the chat overlay visibility.
  /// If a response popup is showing, expand it to full chat instead.
  /// If the agent is currently processing, closing the overlay will stop it.
  void toggleOverlay() {
    if (_isResponsePopupVisible) {
      expandResponsePopup();
      return;
    }
    _isOverlayVisible = !_isOverlayVisible;
    if (_isOverlayVisible) {
      _hasUnreadResponse = false;
      _emit(AiEventType.chatOverlayOpened);
    } else {
      _emit(AiEventType.chatOverlayClosed, {'wasProcessing': _isProcessing});
      if (_isProcessing) requestStop();
    }
    _safeNotify();
  }

  /// Show the chat overlay. Dismisses any visible response popup.
  void showOverlay() {
    dismissResponsePopup();
    _isOverlayVisible = true;
    _hasUnreadResponse = false;
    _safeNotify();
  }

  /// Hide the chat overlay. Stops any in-progress agent execution.
  void hideOverlay() {
    _isOverlayVisible = false;
    if (_isProcessing) {
      requestStop();
    }
    _safeNotify();
  }

  /// Start voice input. Recognized speech is sent as a message.
  Future<void> startVoiceInput() async {
    if (_voiceInput == null || _isListening) return;
    // Allow voice input during ask_user but not during other processing.
    if (_isProcessing && !_waitingForUserResponse) return;
    AiLogger.log('Starting voice input', tag: 'Voice');
    _emit(AiEventType.voiceInputStarted, {
      'locales': _config.preferredLocales,
    });

    _isListening = true;
    _partialTranscription = null;
    if (_config.enableHaptics) HapticFeedback.mediumImpact();
    _safeNotify();

    try {
      await _voiceInput!.startListening(
        preferredLocales: _config.preferredLocales,
        onResult: (text, confidence) {
          _isListening = false;
          _partialTranscription = null;

          // Confidence filtering: discard noise / false starts.
          if (text.trim().length < 2 ||
              (confidence > 0 && confidence < 0.3 && text.trim().length < 5)) {
            AiLogger.log(
              'Voice filtered: "$text" (confidence=${confidence.toStringAsFixed(2)}, len=${text.trim().length})',
              tag: 'Voice',
            );
            _emit(AiEventType.voiceInputError, {
              'text': text,
              'confidence': confidence,
              'error': 'filtered_low_confidence',
            });
            _partialTranscription = "Didn't catch that. Try again.";
            _safeNotify();
            // Clear the "didn't catch" message after a moment.
            Future.delayed(const Duration(seconds: 2), () {
              if (!_disposed && _partialTranscription == "Didn't catch that. Try again.") {
                _partialTranscription = null;
                _safeNotify();
              }
            });
            return;
          }

          _emit(AiEventType.voiceInputCompleted, {
            'text': text,
            'confidence': confidence,
            'accepted': true,
          });
          if (_config.enableHaptics) HapticFeedback.lightImpact();
          _safeNotify();
          if (text.trim().isNotEmpty) {
            sendMessage(text, isVoice: true);
          }
        },
        onPartial: (partialText) {
          _partialTranscription = partialText;
          _safeNotify();
        },
      );
    } catch (_) {
      _isListening = false;
      _partialTranscription = null;
      _safeNotify();
    }
  }

  /// Stop voice input.
  Future<void> stopVoiceInput() async {
    if (_voiceInput == null || !_isListening) return;
    await _voiceInput!.stopListening();
    _isListening = false;
    _safeNotify();
  }

  /// Toggle voice listening on/off.
  Future<void> toggleVoiceInput() async {
    if (_isListening) {
      await stopVoiceInput();
    } else {
      await startVoiceInput();
    }
  }

  /// Clear the conversation and start fresh.
  void clearConversation() {
    _emit(AiEventType.conversationCleared, {
      'messageCount': _messages.length,
    });
    // If processing, stop first.
    if (_isProcessing) {
      _cancelRequested = true;
    }
    _messages.clear();
    _memory.clear();
    _actionSteps.clear();
    _isActionFeedVisible = false;
    _finalResponseText = null;
    _progressText = null;
    _waitingForUserResponse = false;
    _cancelRequested = false;
    _hasExecutedScreenChangingTool = false;
    _currentTaskIsVoice = false;
    _lastSpokenProgress = null;
    _partialTranscription = null;
    _pendingMessage = null;
    _pendingIsVoice = false;
    _hasUnreadResponse = false;
    // Resolve any pending completers to prevent dangling futures.
    if (_userResponseCompleter != null &&
        !_userResponseCompleter!.isCompleted) {
      _userResponseCompleter!.completeError(StateError('Conversation cleared'));
    }
    _userResponseCompleter = null;
    if (_isHandoffMode) _exitHandoffMode(keepOverlay: true);
    dismissResponsePopup();
    _processingTimer?.cancel();
    _safeNotify();
  }

  @override
  void dispose() {
    AiLogger.log('Disposing AiAssistantController', tag: 'Controller');
    _disposed = true;
    _cancelRequested = true;
    _processingTimer?.cancel();
    _responsePopupTimer?.cancel();
    // Resolve any pending completers to prevent dangling futures.
    if (_userResponseCompleter != null &&
        !_userResponseCompleter!.isCompleted) {
      _userResponseCompleter!.completeError(StateError('Controller disposed'));
    }
    if (_handoffCompleter != null && !_handoffCompleter!.isCompleted) {
      _handoffCompleter!.completeError(StateError('Controller disposed'));
    }
    _contextInvalidator.detach();
    _walker.dispose();
    _voiceInput?.dispose();
    _voiceOutput?.dispose();
    try {
      _config.provider.dispose();
    } catch (e) {
      AiLogger.warn('Provider dispose failed: $e', tag: 'Controller');
    }
    super.dispose();
  }
}
