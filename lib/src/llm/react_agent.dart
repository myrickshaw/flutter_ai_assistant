import 'dart:async';
import 'dart:typed_data';

import '../core/ai_event.dart';
import '../core/ai_logger.dart';
import '../models/agent_action.dart';
import '../models/app_context_snapshot.dart';
import '../tools/tool_registry.dart';
import '../tools/tool_result.dart';
import 'conversation_memory.dart';
import 'llm_provider.dart';

/// Callback signature for when a tool starts executing.
typedef OnToolStart = void Function(String toolName, Map<String, dynamic> args);

/// Callback signature for when a tool finishes executing.
typedef OnToolComplete =
    void Function(
      String toolName,
      Map<String, dynamic> args,
      ToolResult result,
    );

/// Callback for when the LLM emits reasoning/status text alongside tool calls.
/// This text is shown to the user as progressive status in the action feed.
typedef OnThought = void Function(String thought);

/// Response from the ReAct agent after processing a user message.
class AgentResponse {
  /// The final natural language response to show the user.
  final String text;

  /// All actions the agent performed during this turn.
  final List<AgentAction> actions;

  const AgentResponse({required this.text, this.actions = const []});
}

/// ReAct (Reason → Act → Observe) agent loop.
///
/// This is the core intelligence loop of the AI assistant. Given a user
/// message, it:
/// 1. Sends the message + app context + tool definitions to the LLM
/// 2. If the LLM returns tool calls → executes them → feeds results back
/// 3. Repeats until the LLM returns a text response or max iterations hit
///
/// The LLM sees the full conversation history, the current screen context,
/// and the available tools. It decides whether to act (call tools) or
/// respond (return text).
class ReactAgent {
  final LlmProvider provider;
  final ToolRegistry toolRegistry;
  final ConversationMemory memory;
  final int maxIterations;

  /// Optional override for the system prompt.
  final String? systemPromptOverride;

  /// Name shown to the user.
  final String assistantName;

  /// Whether to ask the user before destructive actions.
  final bool confirmDestructiveActions;

  /// Optional purpose description of the app (domain vocabulary, use cases).
  final String? appPurpose;

  /// Optional few-shot examples of correct behavior. When empty, generic
  /// examples are generated automatically.
  final List<String> fewShotExamples;

  /// Optional domain-specific behavioral instructions injected into the
  /// system prompt. Use this to teach the agent about app-specific workflows,
  /// terminology, and expected behaviors.
  final String? domainInstructions;

  /// Maximum number of post-completion verification passes before accepting
  /// the agent's response. Default: 2.
  ///
  /// After the agent returns a text response following actions, the system
  /// re-checks the screen to verify the task is genuinely complete. For
  /// simple tasks, the first pass confirms and returns. For multi-step flows,
  /// a second pass catches premature completion (e.g., agent stops at an
  /// intermediate step instead of completing the full flow).
  final int maxVerificationAttempts;

  ReactAgent({
    required this.provider,
    required this.toolRegistry,
    required this.memory,
    this.maxIterations = 100,
    this.systemPromptOverride,
    this.assistantName = 'AI Assistant',
    this.confirmDestructiveActions = true,
    this.appPurpose,
    this.fewShotExamples = const [],
    this.domainInstructions,
    this.maxVerificationAttempts = 2,
  });

  /// Process a user message through the ReAct loop.
  ///
  /// [contextBuilder] is called at the start of each iteration so the LLM
  /// always sees the current screen state after actions (navigation, taps,
  /// scrolls) change the UI. This prevents the LLM from operating on stale
  /// context and stopping prematurely.
  ///
  /// [onToolStart] is called just before each tool executes, allowing the
  /// UI to show a real-time action feed. [onToolComplete] is called after.
  ///
  /// [shouldCancel] is checked at the start of each iteration and between
  /// tool calls. If it returns true, the agent exits gracefully.
  Future<AgentResponse> run({
    required String userMessage,
    required Future<AppContextSnapshot> Function() contextBuilder,
    OnToolStart? onToolStart,
    OnToolComplete? onToolComplete,
    OnThought? onThought,
    bool Function()? shouldCancel,
    AiEventCallback? onEvent,
  }) async {
    AiLogger.log('ReAct run: "$userMessage"', tag: 'Agent');
    void emit(AiEventType type, [Map<String, dynamic>? props]) {
      onEvent?.call(AiEvent.now(type, props));
    }

    memory.addUserMessage(userMessage);
    final executedActions = <AgentAction>[];
    int consecutiveEmptyResponses = 0;
    int verificationAttempts = 0;
    int consecutiveFailures = 0;
    int circuitBreakerFirings = 0;
    final askUserHistory = <String>[];
    int searchRetries = 0;
    bool lastActionWasBlockedAskUser = false;
    String? lastSearchQuery; // T2.2: track last search for result verification

    for (int i = 0; i < maxIterations; i++) {
      // ── Cancellation check ──
      if (shouldCancel?.call() == true) {
        AiLogger.log(
          'Agent cancelled by user at iteration ${i + 1}',
          tag: 'Agent',
        );
        emit(AiEventType.agentCancelled, {
          'iteration': i + 1,
          'actionCount': executedActions.length,
          'reason': 'user_requested',
        });
        final text = executedActions.isNotEmpty
            ? 'Task stopped. ${_summarizeActions(executedActions)}'
            : 'Task stopped.';
        memory.addAssistantMessage(text);
        return AgentResponse(text: text, actions: executedActions);
      }

      AiLogger.log('--- Iteration ${i + 1}/$maxIterations ---', tag: 'Agent');
      emit(AiEventType.agentIterationStarted, {
        'iteration': i + 1,
        'maxIterations': maxIterations,
        'actionsSoFar': executedActions.length,
      });

      // T2.5: Orientation checkpoint every 5 iterations to keep the agent
      // focused on the original goal during long multi-step flows.
      if (i > 0 && i % 5 == 0 && executedActions.isNotEmpty) {
        final actionSummary = executedActions
            .where((a) => a.toolName != 'get_screen_content')
            .map(
              (a) =>
                  '${a.toolName}(${a.arguments.values.first}): ${a.result.success ? "OK" : "FAIL"}',
            )
            .take(8)
            .join(' → ');
        memory.addUserMessage(
          '[SYSTEM — PROGRESS CHECK]\n'
          'Original request: "$userMessage"\n'
          'Actions so far: $actionSummary\n'
          'Continue toward the ORIGINAL goal. Do not stop at intermediate steps.',
        );
        AiLogger.log(
          'Orientation checkpoint at iteration ${i + 1}',
          tag: 'Agent',
        );
        emit(AiEventType.agentOrientationCheckpoint, {
          'iteration': i + 1,
          'actionsSummary': actionSummary,
        });
      }

      // Rebuild context each iteration so the LLM sees fresh screen state
      // after actions (navigation, taps, scrolls) change the UI.
      final context = await contextBuilder();
      final systemPrompt = systemPromptOverride ?? _buildSystemPrompt(context);
      if (i == 0) {
        AiLogger.log(
          'System prompt length: ${systemPrompt.length} chars, '
          '${memory.length} messages in memory',
          tag: 'Agent',
        );
      }

      // Build the messages to send. If a screenshot is available, inject it
      // as an ephemeral multimodal user message at the end. This is NOT stored
      // in conversation memory (screenshots are large and change every iteration).
      final messages = memory.getMessages();
      final screenshot = context.screenshot;
      final messagesWithScreenshot = screenshot != null
          ? _injectScreenshot(messages, screenshot)
          : messages;

      AiLogger.log(
        'Sending ${messages.length} messages '
        '${screenshot != null ? '(+screenshot) ' : ''}'
        '+ ${toolRegistry.length} tools to LLM',
        tag: 'Agent',
      );
      emit(AiEventType.llmRequestSent, {
        'iteration': i + 1,
        'messageCount': messages.length,
        'toolCount': toolRegistry.length,
        'hasScreenshot': screenshot != null,
        'systemPromptLength': systemPrompt.length,
      });
      final llmStopwatch = Stopwatch()..start();

      LlmResponse response;
      try {
        // Race the LLM call against cancellation so the stop button takes
        // effect immediately instead of waiting for the full API timeout.
        final llmFuture = provider.sendMessage(
          messages: messagesWithScreenshot,
          tools: toolRegistry.getToolDefinitions(),
          systemPrompt: systemPrompt,
        );

        if (shouldCancel != null) {
          // Poll cancellation every 500ms while waiting for the LLM.
          final result = await Future.any<LlmResponse?>([
            llmFuture,
            _pollForCancellation(shouldCancel),
          ]);
          if (result == null) {
            // Cancellation won the race.
            AiLogger.log(
              'Agent cancelled during LLM call at iteration ${i + 1}',
              tag: 'Agent',
            );
            final text = executedActions.isNotEmpty
                ? 'Task stopped. ${_summarizeActions(executedActions)}'
                : 'Task stopped.';
            memory.addAssistantMessage(text);
            return AgentResponse(text: text, actions: executedActions);
          }
          response = result;
        } else {
          response = await llmFuture;
        }
      } on AuthenticationException catch (e) {
        // Non-retryable: bad API key. Fail immediately.
        AiLogger.error('Auth failure', error: e, tag: 'Agent');
        emit(AiEventType.llmError, {
          'iteration': i + 1,
          'error': e.toString(),
          'errorType': 'authentication',
          'isRetryable': false,
        });
        const text =
            'API key is invalid or expired. Please check your configuration.';
        memory.addAssistantMessage(text);
        return AgentResponse(text: text, actions: executedActions);
      } on ContextOverflowException catch (e) {
        // Non-retryable: conversation too long. Fail with a clear message.
        AiLogger.error('Context overflow', error: e, tag: 'Agent');
        emit(AiEventType.llmError, {
          'iteration': i + 1,
          'error': e.toString(),
          'errorType': 'context_overflow',
          'isRetryable': false,
        });
        final text = executedActions.isNotEmpty
            ? '${_summarizeActions(executedActions)} (Conversation got too long for the model.)'
            : 'The conversation is too long. Please clear and try again.';
        memory.addAssistantMessage(text);
        return AgentResponse(text: text, actions: executedActions);
      } on ContentFilteredException catch (e) {
        // Non-retryable: safety filter. Inform the user.
        AiLogger.warn('Content filtered: $e', tag: 'Agent');
        emit(AiEventType.llmError, {
          'iteration': i + 1,
          'error': e.toString(),
          'errorType': 'content_filtered',
          'isRetryable': false,
        });
        const text = "I can't help with that request.";
        memory.addAssistantMessage(text);
        return AgentResponse(text: text, actions: executedActions);
      } catch (e) {
        AiLogger.error(
          'LLM call failed at iteration ${i + 1}',
          error: e,
          tag: 'Agent',
        );
        emit(AiEventType.llmError, {
          'iteration': i + 1,
          'error': e.toString(),
          'errorType': 'unknown',
          'isRetryable': true,
          'consecutiveFailures': consecutiveEmptyResponses + 1,
        });
        consecutiveEmptyResponses++;
        if (consecutiveEmptyResponses >= 3) {
          final text = executedActions.isNotEmpty
              ? _summarizeActions(executedActions)
              : 'I encountered an error communicating with the AI service. Please try again.';
          memory.addAssistantMessage(text);
          return AgentResponse(text: text, actions: executedActions);
        }
        // Brief wait before retry.
        await Future.delayed(const Duration(milliseconds: 500));
        continue;
      }

      // Handle empty/null response — LLM returned neither text nor tool calls.
      // Retry up to 3 times before giving up (the LLM may have hit a
      // transient limit or returned an empty candidate list).
      if (!response.isToolCall &&
          (response.textContent == null ||
              response.textContent!.trim().isEmpty)) {
        consecutiveEmptyResponses++;
        AiLogger.warn(
          'LLM returned empty response at iteration ${i + 1} '
          '(consecutive: $consecutiveEmptyResponses)',
          tag: 'Agent',
        );
        emit(AiEventType.llmEmptyResponse, {
          'iteration': i + 1,
          'consecutiveEmpty': consecutiveEmptyResponses,
        });

        // If empty responses follow a blocked ask_user, the LLM is confused.
        // Inject a nudge to get it back on track before giving up.
        if (lastActionWasBlockedAskUser && consecutiveEmptyResponses == 1) {
          AiLogger.log(
            'Injecting nudge after blocked ask_user + empty response',
            tag: 'Agent',
          );
          memory.addUserMessage(
            '[SYSTEM — CONTINUE]\n'
            'Your ask_user was blocked because the user already told you what to do. '
            'The original request was: "$userMessage"\n'
            'DO NOT ask again. Just CONTINUE executing the task. '
            'Call get_screen_content to see the current screen, then take the next action.',
          );
          lastActionWasBlockedAskUser = false;
          await Future.delayed(const Duration(milliseconds: 300));
          continue;
        }

        if (consecutiveEmptyResponses >= 3) {
          if (executedActions.isEmpty) {
            const fallback =
                "I'm not sure how to help with that. Could you rephrase your request?";
            memory.addAssistantMessage(fallback);
            return AgentResponse(text: fallback, actions: executedActions);
          }
          final summary = _summarizeActions(executedActions);
          memory.addAssistantMessage(summary);
          return AgentResponse(text: summary, actions: executedActions);
        }
        // Retry: wait briefly then loop again with fresh context.
        await Future.delayed(const Duration(milliseconds: 500));
        continue;
      }

      // Got a valid response — reset the empty counter.
      consecutiveEmptyResponses = 0;
      llmStopwatch.stop();
      emit(AiEventType.llmResponseReceived, {
        'iteration': i + 1,
        'hasToolCalls': response.isToolCall,
        'hasText':
            response.textContent != null &&
            response.textContent!.trim().isNotEmpty,
        'durationMs': llmStopwatch.elapsedMilliseconds,
      });

      if (!response.isToolCall) {
        final text = response.textContent!;

        // ── Search failure intercept (max 1 retry) ──
        // If the agent returns text claiming it can't find a search bar,
        // but the user's request implies searching, force ONE retry.
        if (_claimsNoSearchBar(text) &&
            _userNeedsSearch(userMessage) &&
            searchRetries < 1) {
          searchRetries++;
          memory.addAssistantMessage(text);
          memory.addUserMessage(
            '[SYSTEM — CORRECTION]\n'
            'You said you cannot find a search bar. This is WRONG.\n'
            'The set_text tool has auto-detection that finds hidden and async search fields.\n'
            'CALL set_text("Search", "<the item the user wants>") RIGHT NOW.\n'
            'Do NOT say you cannot find a search bar — just call set_text.',
          );
          onThought?.call('Retrying search...');
          continue;
        }

        // ── Post-completion verification ──
        // If the agent performed actions, verify the task is genuinely
        // complete before returning. Also catches questions returned as text.
        final looksLikeQuestion = _looksLikeQuestion(text);

        if (executedActions.isNotEmpty &&
            verificationAttempts < maxVerificationAttempts) {
          verificationAttempts++;
          AiLogger.log(
            'Post-completion verification ($verificationAttempts/$maxVerificationAttempts): '
            'agent returned text after ${executedActions.length} actions'
            '${looksLikeQuestion ? ' [question detected]' : ''}',
            tag: 'Agent',
          );

          memory.addAssistantMessage(text);

          final verifyCtx = await contextBuilder();
          final screenNow = verifyCtx.screenContext.toPromptString();

          // Detect if this was a detail-info query but the agent never
          // SUCCESSFULLY tapped into a detail screen (only navigated + read list view).
          final isDetailQuery = _isDetailInfoQuery(userMessage);
          final didTapItemSuccessfully = executedActions.any(
            (a) => a.toolName == 'tap_element' && a.result.success,
          );

          // Detect if the agent stopped at an intermediate step without
          // completing the full flow (no hand_off_to_user, task seems incomplete).
          final didHandoff = executedActions.any(
            (a) => a.toolName == 'hand_off_to_user',
          );

          final verifyMsg = StringBuffer(
            '[SYSTEM — FINAL CHECK]\n'
            'The user asked: "$userMessage"\n\n'
            'Look at the CURRENT SCREEN below and answer the user\'s question FRESH. '
            'Ignore your previous draft — write a completely new response based on what you see NOW.\n\n'
            'INSTRUCTIONS:\n'
            '- If there is still a primary action button to press '
            '(Confirm, Submit, Pay, etc.), press it — the task is not done.\n'
            '- If there are multiple options the user needs to choose, use ask_user.\n'
            '- If the task is complete, respond with a clean summary.\n'
            '- Every fact must be visible on the current screen. '
            'If a value has a label like Fare, Price, Amount, Total, ₹, coins — report it. '
            'Only bare unlabeled large numbers are IDs.\n\n'
            'RESPONSE RULES:\n'
            '- Write as if this is your FIRST and ONLY response. The user has NOT seen any previous draft.\n'
            '- NEVER say: "apologies", "I misread", "let me correct", "I see the problem", "actually".\n'
            '- NEVER reference a previous attempt or correction. Just answer directly.',
          );

          // Generic incomplete-task detection: if the user gave an ACTION
          // command (not a question) and the agent didn't hand off, check
          // whether the task might be incomplete. The domain instructions
          // in the system prompt define what "complete" means for the app.
          if (!didHandoff && !userMessage.trim().endsWith('?')) {
            verifyMsg.write(
              '\n\nIMPORTANT: Re-read the APP-SPECIFIC INSTRUCTIONS in the system prompt. '
              'Is the user\'s request FULLY completed according to those instructions? '
              'If the instructions say a task requires multiple steps (e.g. a multi-step flow), '
              'and you only completed some of them, you MUST continue — do NOT respond yet.',
            );
          }

          if (isDetailQuery && !didTapItemSuccessfully) {
            verifyMsg.write(
              '\n\nCRITICAL — INCOMPLETE: The user asked for DETAILS about a specific item, '
              'but you did NOT successfully tap into the item\'s detail screen. '
              'List views only show summaries — NOT full details. '
              'FIRST: scroll UP to the TOP of the list (the most recent item is at the top). '
              'THEN: TAP the actual item card/row (NOT the page header or section title). '
              'Look for tappable content like dates, amounts, or status text in the item row. '
              'THEN: ONLY use get_screen_content and scroll to READ the detail screen. '
              'Report ALL visible fields comprehensively.',
            );
          }

          if (looksLikeQuestion) {
            verifyMsg.write(
              '\nCRITICAL: Your response contains a question. '
              'Use ask_user tool to ask it — returning text ends the task.',
            );
          }

          verifyMsg.write('\n\nCURRENT SCREEN:\n$screenNow');
          memory.addUserMessage(verifyMsg.toString());

          onThought?.call('Verifying...');
          continue;
        }

        // LLM returned a text response — conversation turn is complete.
        AiLogger.log(
          'LLM returned text (${text.length} chars), turn complete after ${i + 1} iterations',
          tag: 'Agent',
        );
        memory.addAssistantMessage(text);
        return AgentResponse(text: text, actions: executedActions);
      }

      // LLM wants to call tools — execute them.
      final toolCalls = response.toolCalls!;
      final thought = response.textContent;
      AiLogger.log(
        'LLM requested ${toolCalls.length} tool call(s): '
        '${toolCalls.map((c) => c.name).join(', ')}'
        '${thought != null ? ' [thought: "${thought.length > 80 ? '${thought.substring(0, 80)}...' : thought}"]' : ''}',
        tag: 'Agent',
      );

      // Emit the LLM's reasoning text as a progressive status for the user.
      if (thought != null && thought.trim().isNotEmpty) {
        onThought?.call(thought.trim());
      }

      memory.addAssistantToolCalls(toolCalls, thought: thought);

      for (final toolCall in toolCalls) {
        // Check cancellation between tool calls.
        if (shouldCancel?.call() == true) {
          AiLogger.log('Agent cancelled between tool calls', tag: 'Agent');
          // Add a cancelled result for this tool so memory stays consistent.
          memory.addToolResult(toolCall.id, 'Error: Task stopped by user.');
          final text = 'Task stopped. ${_summarizeActions(executedActions)}';
          memory.addAssistantMessage(text);
          return AgentResponse(text: text, actions: executedActions);
        }

        // ── ask_user guards (code-level enforcement) ──
        // The LLM frequently ignores prompt rules about not asking unnecessary
        // questions. These guards intercept bad ask_user calls BEFORE they
        // reach the user, injecting corrective messages so the agent retries.
        if (toolCall.name == 'ask_user') {
          final question = (toolCall.arguments['question'] as String?) ?? '';

          // Guard 1: Unnecessary confirmation ("Would you like to add X?")
          if (_isUnnecessaryConfirmation(question, userMessage)) {
            AiLogger.log(
              'ask_user BLOCKED: unnecessary confirmation',
              tag: 'Agent',
            );
            memory.addToolResult(
              toolCall.id,
              '{"blocked": true, "reason": "SYSTEM: The user ALREADY asked you to do this. '
              'Do NOT ask for confirmation — just do it. Proceed with the action immediately."}',
            );
            lastActionWasBlockedAskUser = true;
            onThought?.call('Proceeding...');
            continue;
          }

          // Guard 2: Redundant quantity question ("How many?")
          if (_isRedundantQuantityQuestion(question, userMessage)) {
            AiLogger.log(
              'ask_user BLOCKED: redundant quantity question',
              tag: 'Agent',
            );
            memory.addToolResult(
              toolCall.id,
              '{"blocked": true, "reason": "SYSTEM: The user ALREADY specified the quantity '
              'in their message: \\"$userMessage\\". Extract the number from their message '
              'and use it. Do NOT ask again."}',
            );
            lastActionWasBlockedAskUser = true;
            onThought?.call('Using specified quantity...');
            continue;
          }

          // Guard 3: Duplicate question (same question asked before)
          if (_isDuplicateAskUser(question, askUserHistory)) {
            AiLogger.log('ask_user BLOCKED: duplicate question', tag: 'Agent');
            memory.addToolResult(
              toolCall.id,
              '{"blocked": true, "reason": "SYSTEM: You already asked this question. '
              'Do NOT repeat questions. Either proceed with the most reasonable choice '
              'or inform the user you need different information."}',
            );
            lastActionWasBlockedAskUser = true;
            continue;
          }
          askUserHistory.add(question);
        }

        // A real tool is about to execute — clear the blocked flag.
        lastActionWasBlockedAskUser = false;

        AiLogger.log(
          'Executing tool: ${toolCall.name}(${toolCall.arguments})',
          tag: 'Agent',
        );
        onToolStart?.call(toolCall.name, toolCall.arguments);

        // Safety timeout on tool execution — prevents the agent from hanging
        // forever if a tool handler blocks (e.g. awaiting a Future that never
        // completes). 30 seconds is generous; most tools complete in <2s.
        ToolResult result;
        try {
          result = await toolRegistry
              .executeTool(toolCall)
              .timeout(const Duration(seconds: 30));
        } on TimeoutException {
          AiLogger.warn(
            'Tool ${toolCall.name} timed out after 30s',
            tag: 'Agent',
          );
          result = ToolResult.fail(
            'Tool "${toolCall.name}" timed out. Try a different approach.',
          );
        }

        AiLogger.log(
          'Tool result: ${toolCall.name} -> ${result.success ? 'OK' : 'FAIL'}'
          '${result.error != null ? ': ${result.error}' : ''}',
          tag: 'Agent',
        );
        onToolComplete?.call(toolCall.name, toolCall.arguments, result);

        memory.addToolResult(toolCall.id, result.toPromptString());

        executedActions.add(
          AgentAction(
            toolName: toolCall.name,
            arguments: toolCall.arguments,
            result: result,
            executedAt: DateTime.now(),
          ),
        );

        // T2.2: Track search queries for result verification.
        if (toolCall.name == 'set_text' && result.success) {
          final label = (toolCall.arguments['label'] as String?) ?? '';
          if (label.toLowerCase().contains('search')) {
            lastSearchQuery = (toolCall.arguments['text'] as String?) ?? '';
          }
        }
        // T2.2: Warn if tapping a result that doesn't match the search query.
        if (toolCall.name == 'tap_element' &&
            result.success &&
            lastSearchQuery != null &&
            lastSearchQuery.isNotEmpty) {
          final tapLabel = (toolCall.arguments['label'] as String?) ?? '';
          // Skip mismatch check for common action buttons — these are
          // expected to not match the search query (e.g. tapping "ADD"
          // after searching "aaloo" is correct, not a mismatch).
          const actionLabels = {
            'add',
            'buy',
            'remove',
            'delete',
            'select',
            'view',
            'open',
            'confirm',
            'submit',
            'cancel',
            'ok',
            'yes',
            'no',
            'done',
            'cart',
            'view cart',
            'checkout',
          };
          final isActionButton = actionLabels.contains(
            tapLabel.toLowerCase().trim(),
          );
          final searchWords = _extractWords(lastSearchQuery);
          final tapWords = _extractWords(tapLabel);
          if (!isActionButton &&
              searchWords.isNotEmpty &&
              tapWords.isNotEmpty) {
            final overlap = searchWords.intersection(tapWords).length;
            final similarity = overlap / searchWords.length;
            if (similarity < 0.3) {
              AiLogger.log(
                'Search-tap mismatch: searched "$lastSearchQuery", '
                'tapped "$tapLabel" (similarity=${similarity.toStringAsFixed(2)})',
                tag: 'Agent',
              );
              // Append warning to the tool result in memory.
              memory.addToolResult(
                '${toolCall.id}_search_warning',
                '[SYSTEM WARNING] You tapped "$tapLabel" but searched for '
                    '"$lastSearchQuery". These don\'t match. Verify this is the '
                    'correct item before proceeding.',
              );
            }
          }
          lastSearchQuery = null; // Clear after first post-search tap.
        }

        // Track consecutive failures for circuit breaker.
        if (result.success) {
          consecutiveFailures = 0;
        } else {
          consecutiveFailures++;
        }
      }

      // ── Consecutive-failure circuit breaker ──
      // If 3+ actions failed in a row, the agent is stuck in a loop
      // (e.g. tapping elements that don't exist). Inject a corrective
      // system message to force it to re-orient.
      if (consecutiveFailures >= 3) {
        circuitBreakerFirings++;
        AiLogger.warn(
          'Circuit breaker firing #$circuitBreakerFirings: '
          '$consecutiveFailures consecutive failures',
          tag: 'Agent',
        );
        emit(AiEventType.agentCircuitBreakerFired, {
          'iteration': i + 1,
          'consecutiveFailures': consecutiveFailures,
          'circuitBreakerCount': circuitBreakerFirings,
        });

        if (circuitBreakerFirings >= 2) {
          // Second firing — the agent is truly stuck. Force an early exit
          // instead of allowing another cycle of failing actions.
          final text = executedActions.isNotEmpty
              ? '${_summarizeActions(executedActions)} '
                    'I ran into repeated issues and could not complete the task.'
              : 'I ran into repeated issues and could not complete the request. '
                    'Please try a different approach.';
          memory.addAssistantMessage(text);
          return AgentResponse(text: text, actions: executedActions);
        }

        memory.addUserMessage(
          '[SYSTEM — CIRCUIT BREAKER]\n'
          'Your last $consecutiveFailures actions ALL FAILED. You are stuck in a loop. '
          'STOP trying to tap elements. Instead:\n'
          '1. Call get_screen_content to see what is actually on screen.\n'
          '2. Report the information you have gathered so far to the user.\n'
          '3. If you have no useful information, say so honestly.\n'
          'Do NOT attempt any more tap_element or set_text calls.',
        );
        consecutiveFailures =
            0; // Reset so the breaker doesn't fire every iteration.
      }

      emit(AiEventType.agentIterationCompleted, {
        'iteration': i + 1,
        'hasToolCalls': response.isToolCall,
        'hasText': !response.isToolCall,
        'actionCount': executedActions.length,
      });

      // Settle delay so the UI updates (including network-loaded content)
      // before the next iteration re-captures screen context.
      await Future.delayed(const Duration(milliseconds: 300));
    }

    // Reached max iterations without a final text response.
    AiLogger.warn('Reached max iterations ($maxIterations)', tag: 'Agent');
    emit(AiEventType.agentMaxIterationsReached, {
      'maxIterations': maxIterations,
      'actionCount': executedActions.length,
    });
    final maxIterText = executedActions.isNotEmpty
        ? _summarizeActions(executedActions)
        : "I wasn't able to complete the request within the step limit. "
              'Please try a simpler command.';
    memory.addAssistantMessage(maxIterText);
    return AgentResponse(text: maxIterText, actions: executedActions);
  }

  /// Heuristic: does the user's message ask for DETAILS about a specific item
  /// — as opposed to a simple value query like "what's my balance?".
  /// Used in verification to catch shallow list-view responses that should
  /// have drilled into a detail screen.
  static bool _isDetailInfoQuery(String message) {
    final lower = message.toLowerCase();
    const detailIntents = [
      'tell me about',
      'details',
      'detail',
      'what did i',
      'show me my',
      'info about',
      'information about',
      'about my',
      'describe',
    ];
    for (final intent in detailIntents) {
      if (lower.contains(intent)) return true;
    }
    // "last/recent/my" + noun pattern (e.g. "my last order").
    if (lower.contains('last') ||
        lower.contains('recent') ||
        lower.contains('latest')) {
      // If the message has a recency prefix and is asking about *something*,
      // it's likely a detail query. The LLM will determine the specifics.
      if (lower.contains('my') || lower.contains('the')) return true;
    }
    return false;
  }

  /// Heuristic: does the text look like a question directed at the user?
  /// Used to detect when the LLM returns a question as text instead of
  /// using the ask_user tool.
  static bool _looksLikeQuestion(String text) {
    final trimmed = text.trim();
    if (trimmed.endsWith('?')) return true;
    final lower = trimmed.toLowerCase();
    // Common question patterns directed at the user.
    return lower.contains('do you want') ||
        lower.contains('would you like') ||
        lower.contains('shall i') ||
        lower.contains('should i') ||
        lower.contains('can you tell me') ||
        lower.contains('could you') ||
        lower.contains('please provide') ||
        lower.contains('please tell me') ||
        lower.contains('what is your') ||
        lower.contains('which one');
  }

  /// Detects if the agent is asking an unnecessary confirmation question
  /// when the user already expressed clear action intent.
  ///
  /// E.g., user says "order X" and agent asks "Would you like to add X?"
  /// — the user ALREADY said to do it.
  static bool _isUnnecessaryConfirmation(String question, String userMessage) {
    final lowerQ = question.toLowerCase();

    // Patterns that indicate the agent is confirming an action.
    const confirmPatterns = [
      'would you like to',
      'shall i',
      'do you want me to',
      'do you want to',
      'should i',
      'want me to',
    ];

    final hasConfirmPattern = confirmPatterns.any((p) => lowerQ.contains(p));
    if (!hasConfirmPattern) return false;

    // The user's message must be imperative (not a question or info request).
    final lowerU = userMessage.toLowerCase().trim();
    if (lowerU.endsWith('?')) return false;
    // Short imperative messages (< 60 chars) that aren't questions are likely commands.
    return lowerU.length < 60;
  }

  /// Detects if the agent is asking about quantity when the user already
  /// specified it in their original message.
  ///
  /// E.g., user says "add 3 items" and agent asks "How many?"
  static bool _isRedundantQuantityQuestion(
    String question,
    String userMessage,
  ) {
    final lowerQ = question.toLowerCase();

    // Question must be asking about quantity.
    const quantityPatterns = [
      'how many',
      'how much',
      'quantity',
      'kitna',
      'kitne',
      'kitni',
    ];
    final isQuantityQuestion = quantityPatterns.any((p) => lowerQ.contains(p));
    if (!isQuantityQuestion) return false;

    // User's message must contain a digit or a common number word.
    final lowerU = userMessage.toLowerCase();
    if (RegExp(r'\d+').hasMatch(lowerU)) return true;

    // Common number words across languages — these are basic numerals,
    // not domain-specific terms.
    const numberWords = [
      // English
      'one', 'two', 'three', 'four', 'five', 'six', 'seven', 'eight',
      'nine', 'ten', 'half', 'quarter', 'dozen',
      // Hindi (transliterated)
      'ek', 'do', 'teen', 'char', 'paanch', 'panch', 'chhah', 'saat',
      'aath', 'nau', 'das', 'aadha', 'pav',
      // Common units
      'kilo', 'kg', 'gram', 'packet', 'piece', 'litre', 'liter',
    ];
    return numberWords.any((w) {
      // Word boundary check to avoid false matches (e.g. "done" containing "do").
      final idx = lowerU.indexOf(w);
      if (idx == -1) return false;
      final before = idx > 0 ? lowerU[idx - 1] : ' ';
      final after = idx + w.length < lowerU.length
          ? lowerU[idx + w.length]
          : ' ';
      return !RegExp(r'[a-z]').hasMatch(before) &&
          !RegExp(r'[a-z]').hasMatch(after);
    });
  }

  /// Detects if the agent is asking a question it already asked earlier
  /// in this conversation turn. Uses word overlap to detect rephrased duplicates.
  static bool _isDuplicateAskUser(String question, List<String> history) {
    if (history.isEmpty) return false;
    final qWords = _extractWords(question);
    if (qWords.isEmpty) return false;

    for (final prev in history) {
      final pWords = _extractWords(prev);
      if (pWords.isEmpty) continue;
      final overlap = qWords.intersection(pWords).length;
      final similarity = overlap / qWords.length;
      if (similarity > 0.6) return true;
    }
    return false;
  }

  /// Extract meaningful words from a string for overlap comparison.
  static Set<String> _extractWords(String text) {
    const stopWords = {
      'the',
      'a',
      'an',
      'is',
      'are',
      'was',
      'were',
      'to',
      'for',
      'of',
      'in',
      'on',
      'at',
      'by',
      'do',
      'you',
      'i',
      'me',
      'my',
      'your',
      'it',
      'this',
      'that',
      'and',
      'or',
      'but',
      'would',
      'like',
      'want',
      'please',
      'could',
      'should',
      'can',
      'will',
      'shall',
    };
    return text
        .toLowerCase()
        .replaceAll(RegExp(r'[^\w\s]'), '')
        .split(RegExp(r'\s+'))
        .where((w) => w.length > 1 && !stopWords.contains(w))
        .toSet();
  }

  /// Heuristic: does the user's message imply they need to search for something?
  /// Used to trigger a search-bar retry when the agent incorrectly claims
  /// it cannot find a search field.
  static bool _userNeedsSearch(String message) {
    final lower = message.toLowerCase();
    // Explicit search intent.
    if (lower.contains('search') ||
        lower.contains('find') ||
        lower.contains('look for')) {
      return true;
    }
    // Imperative commands that typically require searching:
    // "order X", "buy X", "add X", "book X", "get X"
    const actionVerbs = [
      'order',
      'buy',
      'add',
      'book',
      'get',
      'manga',
      'mangao',
    ];
    for (final verb in actionVerbs) {
      // verb followed by a space and something = likely needs search
      if (lower.contains('$verb ')) return true;
    }
    return false;
  }

  /// Detects if the agent's text response claims it cannot find a search bar.
  static bool _claimsNoSearchBar(String text) {
    final lower = text.toLowerCase();
    const patterns = [
      'unable to find the search',
      'cannot find the search',
      'can\'t find the search',
      'couldn\'t find the search',
      'could not find the search',
      'don\'t see a search',
      'do not see a search',
      'no search bar',
      'no search field',
      'search bar is not',
      'search field is not',
      'i am unable to find a search',
      'i don\'t see a text field',
      'unable to locate the search',
      'unable to find a text field',
    ];
    return patterns.any((p) => lower.contains(p));
  }

  /// Polls [shouldCancel] every 500ms and returns null when cancelled.
  /// Used with [Future.any] to race against the LLM call so the stop
  /// button takes effect during API waits instead of after timeout.
  static Future<LlmResponse?> _pollForCancellation(
    bool Function() shouldCancel,
  ) async {
    while (true) {
      await Future.delayed(const Duration(milliseconds: 500));
      if (shouldCancel()) return null;
    }
  }

  /// Generate a user-friendly summary when the agent did work but the LLM
  /// returned an empty response instead of a proper text conclusion.
  String _summarizeActions(List<AgentAction> actions) {
    // Filter out internal tools and ask_user from the visible summary.
    final visible = actions
        .where(
          (a) => a.toolName != 'get_screen_content' && a.toolName != 'ask_user',
        )
        .toList();
    if (visible.isEmpty) return 'Done.';

    // Count action types for a concise summary instead of listing every action.
    final succeeded = visible.where((a) => a.result.success).length;
    final failed = visible.where((a) => !a.result.success).length;
    final total = visible.length;

    if (failed == 0) {
      return 'Done — completed $total action${total == 1 ? '' : 's'}.';
    }
    return 'Partially done — $succeeded of $total action${total == 1 ? '' : 's'} succeeded, '
        '$failed failed.';
  }

  /// Inject a screenshot into the message list as a multimodal user message.
  ///
  /// The screenshot is appended as the LAST user message so the LLM sees it
  /// alongside the latest context. It is NOT stored in conversation memory
  /// (ephemeral — changes every iteration and is large).
  List<LlmMessage> _injectScreenshot(
    List<LlmMessage> messages,
    Uint8List screenshot,
  ) {
    return [
      ...messages,
      LlmMessage.userMultimodal(
        '[SCREENSHOT] Current screen visual. Use this for text in images, '
        'charts, visual layouts, and content not captured by the semantics tree.',
        [LlmImageContent(bytes: screenshot)],
      ),
    ];
  }

  /// Build the system prompt with full app context.
  ///
  /// Structure:
  /// 1. Role + App Purpose
  /// 2. Core Rules (9 focused, non-contradictory rules)
  /// 3. Few-shot examples
  /// 4. App context (manifest, routes, screen detail)
  /// 5. Live UI
  String _buildSystemPrompt(AppContextSnapshot context) {
    final buffer = StringBuffer();
    final manifest = context.appManifest;

    // ── Section 1: Role + App Purpose ──
    buffer.writeln(
      'You are $assistantName, an AI that controls a mobile app\'s UI on behalf of the user.',
    );
    buffer.writeln(
      'You execute tasks by tapping buttons, entering text, scrolling, and navigating between screens.',
    );
    if (appPurpose != null) {
      buffer.writeln();
      buffer.writeln('APP PURPOSE: $appPurpose');
    }
    buffer.writeln();

    // ── Prime Directives ──
    buffer.writeln('*** PRIME DIRECTIVES (NEVER VIOLATE) ***');
    buffer.writeln(
      '• User gives a command → DO IT. NEVER ask for confirmation when the intent is clear.',
    );
    buffer.writeln(
      '• User specifies details (quantity, name, destination) → USE THEM. NEVER re-ask.',
    );
    buffer.writeln(
      '• When searching, ALWAYS call set_text — even if you do NOT see a text field on screen. '
      'The tool auto-detects hidden, unfocused, and async search bars. NEVER say "I cannot find the search bar" '
      '— just call set_text("Search", "query") and it will find the field.',
    );
    buffer.writeln(
      '• ask_user is ONLY for genuinely ambiguous situations (2+ equally valid options). Aim for ZERO questions.',
    );
    buffer.writeln();

    // ── Section 2: Core Rules ──
    buffer.writeln('RULES:');
    buffer.writeln(
      '1. EXECUTE DECISIVELY: Perform the user\'s request without unnecessary questions. '
      'If the intent is clear, ACT — do not ask. Pick obvious matches from search suggestions. '
      'Do not ask the user to confirm something that directly matches what they requested. '
      'If the user asks for multiple things, process each independently. '
      'If something is NOT FOUND (search returns no match), use ask_user to inform the user. '
      'NEVER silently substitute a different item — always ask first. '
      'SEARCH FIRST: When the user names a specific item to find, act on, or interact with, '
      'ALWAYS search for it using set_text BEFORE tapping any results. '
      'Items visible on screen by default may NOT be what the user wants — search to find the exact match. '
      'SEARCH VERIFICATION: After searching, READ the results on screen. '
      'Verify that result names actually match the search query. '
      'If the screen shows unrelated results after a search, the search returned no matches — inform the user.',
    );
    buffer.writeln(
      '2. WHEN TO ASK (ask_user tool): Default is DO NOT ASK — just act. '
      'The ONLY time you may ask is when there are 2+ equally valid options with different consequences '
      'that you genuinely cannot choose between (e.g. two options at different prices, ambiguous choices). '
      'Maximum ONE question per task, and only if truly unavoidable. '
      'When you must ask, list ALL options with full details (name, price). '
      'IMPORTANT: If you need to ask, you MUST use the ask_user TOOL — not return text. '
      'Returning text TERMINATES the task — the user cannot respond to plain text. '
      'RESPONSE HANDLING: When you receive the user\'s response to ask_user: '
      'If they say "yes", "ok", "sure", "haan", "ha", "go ahead", or any affirmative → '
      'IMMEDIATELY proceed with the action you proposed. Do NOT re-describe what you will do or ask again. '
      'If the response is a COMPLETELY DIFFERENT REQUEST '
      '(e.g. you asked "which transaction?" but user says "tell me about my order"), '
      'ABANDON your previous question and handle the NEW request instead. '
      'NEVER repeat the same question if the user\'s response was unrelated — they want something else now. '
      'NEVER ask the same ask_user question twice in a single conversation turn.',
    );
    if (confirmDestructiveActions) {
      buffer.writeln(
        '3. COMPLETE ENTIRE TASK: Do NOT stop at intermediate steps. '
        'Complete ALL preparatory work (navigate, search, fill forms, select options). '
        'Filling forms, selecting locations, and confirming destinations are INTERMEDIATE — keep going. '
        'For the FINAL irreversible action, use hand_off_to_user (see Rule 8).',
      );
    } else {
      buffer.writeln(
        '3. COMPLETE ENTIRE TASK: Do NOT stop at intermediate steps. '
        'You MUST press the FINAL action button yourself (Confirm, Pay, Submit, etc.). '
        'Filling forms, selecting options, and entering details are INTERMEDIATE — keep going. '
        'NEVER tell the user to press a button themselves.',
      );
    }
    buffer.writeln(
      '4. WAIT FOR CONTENT: After actions that trigger network calls (navigation, search, '
      'form submission, confirming destination), content takes time to load. '
      'Call get_screen_content once to refresh. If screen still appears empty, call once more. '
      'Maximum 2 consecutive get_screen_content calls — the system already waits for content between iterations. '
      'While waiting for content, do NOT tap Close, Back, or Cancel — stay on the screen and keep checking.',
    );
    buffer.writeln(
      '5. NEVER GIVE UP (but be efficient): Before saying "unable to" or "not available": '
      'FIRST check if you need to NAVIGATE to a different screen — you are NOT limited to the current screen. '
      'You can use navigate_to_route to go to ANY screen in the APP SCREENS list at any time. '
      'If the information or action the user needs is on a different screen, GO THERE. '
      'NEVER say "I can only access the current screen" — you can navigate anywhere. '
      'Also: retry get_screen_content once, scroll to check off-screen content. '
      'But do NOT loop endlessly — '
      'if after 2 attempts something isn\'t working, try a different approach or inform the user.',
    );
    buffer.writeln(
      '6. PLAN FIRST: For multi-step tasks, mentally plan the full sequence before starting. '
      'Example: "1. Navigate to the target screen, 2. Search for the item, 3. Tap the result, 4. Complete the action". '
      'Then execute step by step, one action at a time, observing results after each.',
    );
    buffer.writeln(
      '7. SCREEN INTERACTION: Use parentContext to disambiguate same-label elements — '
      'ALWAYS use the ITEM NAME or MAIN TITLE as parentContext, never prices, discounts, or badges. '
      'If the screen says "MORE CONTENT below/above", scroll to see it. '
      'Your screen view auto-refreshes after each action. '
      'Use navigate_to_route with the EXACT route name including "/" from the APP SCREENS list.',
    );
    if (confirmDestructiveActions) {
      buffer.writeln(
        '8. FINAL ACTIONS (hand_off_to_user): When you reach the FINAL irreversible action button '
        '(Confirm, Submit, Pay, etc.), do NOT tap it yourself. '
        'Instead, call hand_off_to_user with the exact button label and a brief summary. '
        'The overlay will clear so the user can see the full screen and tap the button themselves. '
        'Complete ALL preparatory steps first (navigate, search, fill forms, select options) — '
        'only hand off at the very last button. '
        'For mid-flow choices (which ride type? which item?), use ask_user as before.',
      );
    } else {
      buffer.writeln(
        '8. ACTIONS: You have permission to perform ALL actions without asking for confirmation. '
        'This includes bookings, purchases, and form submissions. Execute them directly.',
      );
    }
    if (manifest != null) {
      buffer.writeln(
        '9. MANIFEST vs LIVE: SCREEN KNOWLEDGE describes the typical layout. '
        'LIVE UI shows what is actually on screen now. Trust LIVE UI for interaction targets. '
        'Use SCREEN KNOWLEDGE for planning navigation and understanding screen purpose.',
      );
    }
    buffer.writeln(
      '10. LANGUAGE: Understand the user regardless of language. '
      'Users may mix languages (e.g. English with Hindi, Spanish, etc.), use slang, '
      'abbreviations, or informal transliterations. Extract intent from context. '
      'Do NOT ask for clarification just because the phrasing is informal or multilingual. '
      'Respond in the same language the user used.',
    );
    buffer.writeln(
      '11. ACCURACY AND GROUNDING: ONLY state facts you can verify from the LIVE UI. '
      'NEVER fabricate element labels, values, prices, names, or counts not visible on screen. '
      'If the screen shows "Balance: 150 coins", report EXACTLY that — no rounding or embellishing. '
      'If you cannot find the requested information on screen, say so explicitly. '
      'Distinguish: obvious inference (user says "book ride", app has "Book Ride" button → tap it) = ACCEPTABLE. '
      'Reasonable default (only one matching result → pick it) = ACCEPTABLE. '
      'Fabrication (user asks balance, you cannot see it → making up a number) = NEVER. '
      'Over-guessing (user says "order food", multiple equal options visible → picking randomly) = ASK with ask_user. '
      'CRITICAL: Before tapping on ANY item, verify it matches the user\'s request. '
      'If no matching item is visible, DO NOT select a different one. '
      'NUMBERS: Read labels carefully to distinguish IDs from prices. '
      'If a number has a label like "Fare", "Amount", "Price", "Cost", "Total", "₹", or "coins" — it IS a price, report it. '
      'If a number is just displayed next to a ride/order without any price-related label (like a bare "1152134") — it is likely an ID. '
      'When in doubt, report the number WITH its label so the user can judge (e.g. "Ride #1152134, Fare: ₹150").',
    );
    buffer.writeln(
      '12. CONSISTENCY AND EFFICIENCY: For common task patterns, follow a deterministic sequence. '
      'Navigation tasks: navigate_to_route → get_screen_content → report. '
      'Search tasks: navigate → get_screen_content (WAIT for screen to fully load) → set_text in search → get_screen_content → verify results match query → tap result. '
      'Detail/info queries about a specific item: '
      'navigate to list → get_screen_content → TAP the item to open detail screen → '
      'get_screen_content → scroll_down → get_screen_content → report ALL fields from detail screen. '
      'Simple info queries: navigate → get_screen_content → report. '
      'Same request type = same steps every time. Do not skip steps or vary your approach between similar tasks. '
      'EFFICIENCY: Do NOT call get_screen_content more than 2 times in a row without performing an action between them. '
      'If an approach fails twice, try a DIFFERENT approach (different search term, different screen, scroll). '
      'Never repeat the same failed action — it will fail again.',
    );
    buffer.writeln();

    if (context.screenshot != null) {
      buffer.writeln(
        '13. VISUAL CONTEXT: A screenshot of the current screen is attached. '
        'Use it for text inside images, charts, visual layouts, and content the semantics tree cannot capture. '
        'LIVE UI (semantics) remains primary for element labels, actions, and interaction targets. '
        'The screenshot is supplementary — do NOT rely on it for tap targets.',
      );
    }
    buffer.writeln();

    // ── Response style ──
    buffer.writeln('RESPONSE STYLE — How to talk to the user:');
    buffer.writeln(
      'Your responses are shown in a chat UI. Write like a smart, helpful friend — not a robot.',
    );
    buffer.writeln();
    buffer.writeln('FINAL RESPONSES (text returned to user):');
    buffer.writeln(
      '- LEAD WITH THE ANSWER. Never start with "The current screen shows..." or "I navigated to...". '
      'The user asked a question — answer it directly.',
    );
    buffer.writeln(
      '- NEVER mention screens, routes, navigation, tapping, or technical mechanics. '
      'BAD: "The current screen shows your coin balance. Your wallet balance is 995592317 coins." '
      'GOOD: "Your wallet balance is 99,55,92,317 coins."',
    );
    buffer.writeln(
      '- FORMAT numbers for readability: use commas (1,00,000 or 100,000), '
      'currency symbols (₹, \$), and proper date formats (27 Feb 2026, not 2026-02-27).',
    );
    buffer.writeln(
      '- For INFO queries: give a clean, structured answer. '
      'BAD: "I found the details. The item was X from Y." '
      'GOOD: "Your last item:\\n• From A → B\\n• Date/Time\\n• Amount: ₹X\\n• Status: Completed"',
    );
    buffer.writeln(
      '- For ACTION completion: confirm briefly and warmly. '
      'BAD: "I have completed the action. The action is now done." '
      'GOOD: "Done! Added to your cart."',
    );
    buffer.writeln(
      '- For ERRORS: be honest and helpful, not apologetic or verbose. '
      'BAD: "I apologize for the error. I was unable to locate the requested information on the current screen." '
      'GOOD: "Couldn\'t find that item. Want me to try a different search?"',
    );
    buffer.writeln(
      '- Keep responses SHORT. 1-3 sentences for actions. A few bullet points for info. '
      'No filler like "Sure!", "Absolutely!", "I\'d be happy to help!"',
    );
    buffer.writeln();
    buffer.writeln('PROGRESS STATUS (brief text alongside tool calls):');
    buffer.writeln(
      '- Write from the user\'s perspective, like a loading indicator.',
    );
    buffer.writeln(
      '- BAD: "Navigating to /history screen..." → GOOD: "Checking your history..."',
    );
    buffer.writeln(
      '- BAD: "Tapping on the search field..." → GOOD: "Searching..."',
    );
    buffer.writeln(
      '- BAD: "Calling get_screen_content to read the UI..." → GOOD: "Reading the details..."',
    );
    buffer.writeln(
      '- BAD: "Executing scroll_down action..." → GOOD: "Looking for more details..."',
    );
    buffer.writeln(
      '- Keep these to 2-5 words. Think: what would a loading spinner say?',
    );
    buffer.writeln();

    // ── Failure recovery guidance ──
    buffer.writeln('WHEN THINGS GO WRONG:');
    buffer.writeln(
      '- tap_element fails → call get_screen_content to see what is ACTUALLY on screen. '
      'The element name may differ from what you expect. Use the exact label from the screen.',
    );
    buffer.writeln(
      '- Screen looks empty or unexpected → wait by calling get_screen_content once more. '
      'Content may still be loading. Do NOT navigate away immediately.',
    );
    buffer.writeln(
      '- Search returns no results → try a shorter/simpler search term.',
    );
    buffer.writeln(
      '- Same action fails twice → try a DIFFERENT approach entirely. '
      'Do NOT repeat the same failing action a third time.',
    );
    buffer.writeln(
      '- After 2+ failures, if you cannot complete the task, inform the user honestly '
      'with what you DID accomplish and what went wrong. Do not silently give up.',
    );
    buffer.writeln();

    // ── Domain-specific instructions (provided by the app developer) ──
    if (domainInstructions != null && domainInstructions!.trim().isNotEmpty) {
      buffer.writeln('APP-SPECIFIC INSTRUCTIONS:');
      buffer.writeln(domainInstructions);
      buffer.writeln();
    }

    // ── Task types guidance ──
    buffer.writeln('TASK TYPES:');
    buffer.writeln(
      '- ACTION tasks (commands to do something): '
      'Navigate → interact → complete the FULL action including pressing the final button. '
      'Do NOT stop at intermediate steps — complete the entire requested flow.',
    );
    buffer.writeln(
      '- INFORMATION tasks (queries about data, status, details): '
      'Two sub-types:',
    );
    buffer.writeln(
      '  A) SIMPLE INFO (a single value like balance, count, status): '
      'Navigate → get_screen_content → report the value. Done.',
    );
    buffer.writeln(
      '  B) DETAIL INFO (about a specific item): '
      'Navigate to list → get_screen_content → TAP the specific item to open its DETAIL screen → '
      'get_screen_content (now on detail screen) → scroll_down → get_screen_content → '
      'extract and report ALL fields comprehensively. '
      'STOP TAPPING after opening the detail screen. Once you are on the detail screen, '
      'your ONLY allowed tools are get_screen_content and scroll (up/down). '
      'Do NOT tap any more elements — you are just READING, not performing actions.',
    );
    buffer.writeln(
      '  WARNING: A list screen ONLY shows summaries (title, date, status). '
      'This is NOT enough for detail queries. '
      'You MUST tap into the item to see its detail screen with full information. '
      'Reporting ONLY from a list view is a FAILURE.',
    );
    buffer.writeln(
      '  TAP TARGETS: Tap the item\'s CONTENT (date, amount, status text) — '
      'NOT the page header, section title, or tab label.',
    );
    buffer.writeln(
      '  "LAST" / "MOST RECENT": The FIRST item at the TOP of the list is the most recent. '
      'Do NOT scroll down before tapping — you will move past it. '
      'Only scroll DOWN AFTER you are on the detail screen to see more details below the fold.',
    );
    buffer.writeln(
      '- HELP/SUPPORT tasks (refund, complaint, issue, help, support, problem): '
      'Navigate to the app\'s Help, Support, or Customer Service section. '
      'If no help section exists, inform the user honestly.',
    );
    buffer.writeln();

    // ── Section 3: Few-shot examples ──
    buffer.writeln('EXAMPLES OF CORRECT BEHAVIOR:');
    buffer.writeln();
    if (fewShotExamples.isNotEmpty) {
      // Use developer-provided app-specific examples.
      for (final example in fewShotExamples) {
        buffer.writeln(example);
        buffer.writeln();
      }
    } else {
      // Generic fallback examples that work for any app.
      buffer.writeln('User: "go to settings"');
      buffer.writeln('Status: "Opening settings..."');
      buffer.writeln('Actions: navigate_to_route("/settings")');
      buffer.writeln('Response: "Here are your settings."');
      buffer.writeln();
      buffer.writeln('User: "search for X"');
      buffer.writeln('Status: "Searching..."');
      buffer.writeln(
        'Actions: navigate to relevant screen → get_screen_content → '
        'set_text("Search", "X") → get_screen_content → tap matching result',
      );
      buffer.writeln('Response: "Found X — here it is."');
      buffer.writeln();
      buffer.writeln('User: "tell me about my last item"');
      buffer.writeln(
        'Status: "Checking..." → "Opening details..." → "Reading..."',
      );
      buffer.writeln(
        'Actions: navigate to list screen → get_screen_content → '
        'tap first item (most recent) → get_screen_content → scroll_down → get_screen_content',
      );
      buffer.writeln(
        'Response: "Your last item:\\n• Detail 1\\n• Detail 2\\n• Status: Done"',
      );
      buffer.writeln(
        'NOTE: The agent tapped INTO the item to open its detail screen — '
        'it did NOT just read the list view summary.',
      );
      buffer.writeln();
    }

    // ── Section 4: App Context ──

    // Tier 1: App Map (from manifest).
    if (manifest != null) {
      _writeScopedManifestContext(buffer, context);

      // Include dynamically discovered routes NOT in the manifest.
      final manifestRoutes = manifest.screens.keys.toSet();
      final extraRoutes = context.availableRoutes.where(
        (r) => !manifestRoutes.contains(r.name),
      );
      if (extraRoutes.isNotEmpty) {
        buffer.writeln('OTHER DISCOVERED SCREENS:');
        for (final route in extraRoutes) {
          final desc = route.description != null
              ? ' — ${route.description}'
              : '';
          buffer.writeln('  ${route.name}$desc');
        }
        buffer.writeln();
      }
    } else {
      // Fallback: flat route list.
      if (context.availableRoutes.isNotEmpty) {
        buffer.writeln(
          'APP SCREENS (navigate with exact route name including "/"):',
        );
        for (final route in context.availableRoutes) {
          final desc = route.description != null
              ? ' — ${route.description}'
              : '';
          buffer.writeln('  • ${route.name}$desc');
        }
        buffer.writeln();
      }
    }

    // Current screen info.
    if (context.currentRoute != null) {
      buffer.writeln('CURRENT SCREEN: ${context.currentRoute}');
    }
    if (context.navigationStack.isNotEmpty) {
      buffer.writeln(
        'NAVIGATION STACK: ${context.navigationStack.join(' → ')}',
      );
    }
    buffer.writeln();

    // Tier 2: Current screen manifest detail.
    if (manifest != null && context.currentRoute != null) {
      final screenDetail = manifest.toScreenDetailPrompt(context.currentRoute!);
      if (screenDetail != null) {
        buffer.writeln(screenDetail);
        buffer.writeln();
      }
    }

    // ── Section 5: Live UI ──
    buffer.writeln(
      manifest != null
          ? 'LIVE UI (what\'s actually on screen right now):'
          : 'WHAT\'S ON SCREEN:',
    );
    buffer.writeln(context.screenContext.toPromptString());
    buffer.writeln();

    // Screen knowledge cache (brief).
    if (context.screenKnowledge.isNotEmpty) {
      buffer.writeln('SCREENS SEEN BEFORE:');
      final knownEntries = context.screenKnowledge.entries.toList()
        ..sort((a, b) => a.key.compareTo(b.key));
      for (final entry in knownEntries.take(20)) {
        buffer.writeln(
          '  • ${entry.key}: ${entry.value.elements.length} elements',
        );
      }
      if (knownEntries.length > 20) {
        buffer.writeln('  +${knownEntries.length - 20} more screens omitted');
      }
      buffer.writeln();
    }

    // Global state.
    if (context.globalState != null && context.globalState!.isNotEmpty) {
      buffer.writeln('APP STATE:');
      for (final entry in context.globalState!.entries) {
        buffer.writeln('  • ${entry.key}: ${entry.value}');
      }
      buffer.writeln();
    }

    return buffer.toString();
  }

  void _writeScopedManifestContext(
    StringBuffer buffer,
    AppContextSnapshot context,
  ) {
    final manifest = context.appManifest;
    if (manifest == null) return;

    const maxDetailedScreens = 24;
    const maxCurrentLinks = 8;

    buffer.writeln('APP OVERVIEW:');
    buffer.writeln(manifest.appDescription);
    buffer.writeln();

    if (manifest.globalNavigation.isNotEmpty) {
      buffer.writeln('GLOBAL NAVIGATION:');
      final navItems = manifest.globalNavigation
          .map((n) => '${n.label} (${n.route})')
          .join(', ');
      buffer.writeln('  $navItems');
      buffer.writeln();
    }

    final prioritizedRoutes = <String>{};
    final currentRoute = context.currentRoute;
    if (currentRoute != null && manifest.screens.containsKey(currentRoute)) {
      prioritizedRoutes.add(currentRoute);
      final currentScreen = manifest.screens[currentRoute];
      if (currentScreen != null) {
        for (final link in currentScreen.linksTo) {
          if (!manifest.screens.containsKey(link.targetRoute)) continue;
          prioritizedRoutes.add(link.targetRoute);
          if (prioritizedRoutes.length >= maxCurrentLinks) break;
        }
      }
    }

    for (final nav in manifest.globalNavigation) {
      if (!manifest.screens.containsKey(nav.route)) continue;
      prioritizedRoutes.add(nav.route);
      if (prioritizedRoutes.length >= maxDetailedScreens) break;
    }

    if (prioritizedRoutes.length < maxDetailedScreens) {
      for (final flow in manifest.flows) {
        for (final step in flow.steps) {
          if (!manifest.screens.containsKey(step.route)) continue;
          prioritizedRoutes.add(step.route);
          if (prioritizedRoutes.length >= maxDetailedScreens) break;
        }
        if (prioritizedRoutes.length >= maxDetailedScreens) break;
      }
    }

    if (prioritizedRoutes.length < maxDetailedScreens) {
      final remaining =
          manifest.screens.keys
              .where((r) => !prioritizedRoutes.contains(r))
              .toList()
            ..sort();
      for (final route in remaining) {
        prioritizedRoutes.add(route);
        if (prioritizedRoutes.length >= maxDetailedScreens) break;
      }
    }

    buffer.writeln('APP SCREENS (core map):');
    for (final route in prioritizedRoutes) {
      final screen = manifest.screens[route];
      if (screen == null) continue;
      buffer.writeln(
        '  $route - ${screen.title} - ${_truncate(screen.description, 120)}',
      );
      if (route == currentRoute && screen.linksTo.isNotEmpty) {
        for (final link in screen.linksTo.take(maxCurrentLinks)) {
          buffer.writeln(
            '    -> ${link.targetRoute} (${_truncate(link.trigger, 70)})',
          );
        }
      }
    }
    buffer.writeln();

    final allRoutes = <String>{
      ...manifest.screens.keys,
      ...context.availableRoutes.map((r) => r.name),
    }.toList()..sort();
    buffer.writeln('ALL ROUTES (exact names for navigate_to_route):');
    for (final route in allRoutes) {
      buffer.writeln('  - $route');
    }
    buffer.writeln();
  }

  String _truncate(String value, int maxChars) {
    if (value.length <= maxChars) return value;
    return '${value.substring(0, maxChars - 3)}...';
  }
}
