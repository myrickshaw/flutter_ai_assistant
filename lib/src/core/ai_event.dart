/// Comprehensive analytics event system for the AI Assistant.
///
/// The host app registers an [AiEventCallback] via [AiAssistantConfig.onEvent]
/// to receive structured events covering the full lifecycle of every
/// conversation, agent iteration, tool call, voice interaction, and UI action.
///
/// ```dart
/// AiAssistantConfig(
///   onEvent: (event) {
///     analytics.logEvent(event.type.name, event.properties);
///   },
/// )
/// ```
library;

/// All trackable event types emitted by the AI Assistant.
enum AiEventType {
  // ── Conversation lifecycle ──────────────────────────────────────────────

  /// A new user message starts processing.
  /// Properties: `message`, `isVoice`, `conversationLength`
  conversationStarted,

  /// The agent finished processing and returned a response.
  /// Properties: `response`, `responseType`, `totalActions`, `totalIterations`,
  ///             `durationMs`, `wasVoice`
  conversationCompleted,

  /// The agent encountered an unrecoverable error.
  /// Properties: `error`, `stackTrace`, `totalActions`, `durationMs`
  conversationError,

  /// User message added to chat (text or voice).
  /// Properties: `message`, `isVoice`
  messageSent,

  /// Assistant response added to chat.
  /// Properties: `response`, `responseType`, `actionCount`
  messageReceived,

  /// Conversation was cleared by the user.
  /// Properties: `messageCount`
  conversationCleared,

  // ── Agent loop ──────────────────────────────────────────────────────────

  /// A new ReAct iteration begins.
  /// Properties: `iteration`, `maxIterations`, `actionsSoFar`
  agentIterationStarted,

  /// A ReAct iteration completed (LLM responded).
  /// Properties: `iteration`, `hasToolCalls`, `hasText`, `durationMs`
  agentIterationCompleted,

  /// Agent was cancelled by the user mid-execution.
  /// Properties: `iteration`, `actionCount`, `reason`
  agentCancelled,

  /// Agent hit the processing timeout (3 min active processing).
  /// Properties: `iteration`, `actionCount`
  agentTimeout,

  /// Agent hit the max iteration limit.
  /// Properties: `maxIterations`, `actionCount`
  agentMaxIterationsReached,

  /// Orientation checkpoint fired (every 5 iterations).
  /// Properties: `iteration`, `actionsSummary`
  agentOrientationCheckpoint,

  /// Circuit breaker fired due to consecutive failures.
  /// Properties: `iteration`, `consecutiveFailures`, `circuitBreakerCount`
  agentCircuitBreakerFired,

  // ── LLM communication ──────────────────────────────────────────────────

  /// An LLM API request was sent.
  /// Properties: `iteration`, `messageCount`, `toolCount`, `hasScreenshot`,
  ///             `systemPromptLength`
  llmRequestSent,

  /// An LLM API response was received.
  /// Properties: `iteration`, `hasToolCalls`, `hasText`, `durationMs`
  llmResponseReceived,

  /// An LLM API call failed (network, auth, rate limit, etc.).
  /// Properties: `iteration`, `error`, `errorType`, `isRetryable`,
  ///             `consecutiveFailures`
  llmError,

  /// LLM returned an empty/null response.
  /// Properties: `iteration`, `consecutiveEmpty`
  llmEmptyResponse,

  // ── Tool execution ─────────────────────────────────────────────────────

  /// A tool started executing.
  /// Properties: `toolName`, `arguments`, `iteration`
  toolExecutionStarted,

  /// A tool finished executing.
  /// Properties: `toolName`, `arguments`, `success`, `error`, `durationMs`,
  ///             `iteration`
  toolExecutionCompleted,

  /// Screen content was captured (get_screen_content).
  /// Properties: `route`, `elementCount`, `durationMs`
  screenContentCaptured,

  /// Screen stabilization was needed (async content loading).
  /// Properties: `route`, `attempts`, `initialElements`, `finalElements`
  screenStabilizationAttempted,

  // ── Voice I/O ──────────────────────────────────────────────────────────

  /// Voice input (microphone) was activated.
  /// Properties: `locales`
  voiceInputStarted,

  /// Voice input produced a recognized result.
  /// Properties: `text`, `confidence`, `accepted`
  voiceInputCompleted,

  /// Voice input failed or was filtered out.
  /// Properties: `error`, `text`, `confidence`
  voiceInputError,

  /// TTS started speaking.
  /// Properties: `text`, `isProgress` (true for mid-task status updates)
  ttsStarted,

  // ── UI interactions ────────────────────────────────────────────────────

  /// Chat overlay was opened.
  chatOverlayOpened,

  /// Chat overlay was closed.
  /// Properties: `wasProcessing`
  chatOverlayClosed,

  /// A suggestion chip (empty-state) was tapped.
  /// Properties: `label`, `message`
  suggestionChipTapped,

  /// An interactive button in a chat message was tapped.
  /// Properties: `buttonLabel`, `wasAskUserResponse`
  buttonTapped,

  /// Handoff mode started (agent pauses, user taps real button).
  /// Properties: `buttonLabel`, `summary`
  handoffStarted,

  /// Handoff completed (user tapped the button or confirmed).
  /// Properties: `buttonLabel`, `resolution` (route_change|manual|timeout|cancelled)
  handoffCompleted,

  /// ask_user tool paused the agent to ask the user a question.
  /// Properties: `question`
  askUserStarted,

  /// User responded to an ask_user question.
  /// Properties: `question`, `response`
  askUserCompleted,

  /// User tapped "Stop" to cancel the agent.
  stopRequested,

  /// Response popup was shown above the FAB.
  /// Properties: `responseType`, `text`
  responsePopupShown,

  // ── Navigation ─────────────────────────────────────────────────────────

  /// A route change was detected by the navigator observer.
  /// Properties: `fromRoute`, `toRoute`
  routeChanged,

  /// Agent executed a navigation action.
  /// Properties: `route`, `success`
  navigationExecuted,
}

/// Callback type for receiving analytics events.
typedef AiEventCallback = void Function(AiEvent event);

/// A structured analytics event emitted by the AI Assistant.
///
/// Each event has a [type] (what happened), a [timestamp] (when), and
/// a [properties] map with event-specific data. The property keys for
/// each event type are documented on the [AiEventType] enum values.
class AiEvent {
  /// What happened.
  final AiEventType type;

  /// When it happened.
  final DateTime timestamp;

  /// Event-specific data. Keys vary by [type] — see [AiEventType] docs.
  final Map<String, dynamic> properties;

  const AiEvent({
    required this.type,
    required this.timestamp,
    this.properties = const {},
  });

  /// Convenience factory that auto-fills [timestamp] with [DateTime.now].
  factory AiEvent.now(AiEventType type, [Map<String, dynamic>? properties]) {
    return AiEvent(
      type: type,
      timestamp: DateTime.now(),
      properties: properties ?? const {},
    );
  }

  @override
  String toString() => 'AiEvent(${type.name}, $properties)';
}
