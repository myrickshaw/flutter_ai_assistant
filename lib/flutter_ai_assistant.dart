/// Drop-in AI assistant for any Flutter app.
///
/// Wrap your MaterialApp with [AiAssistant] to auto-enable AI capabilities:
///
/// ```dart
/// AiAssistant(
///   config: AiAssistantConfig(
///     provider: GeminiProvider(apiKey: 'your-key'),
///   ),
///   child: MaterialApp(home: HomeScreen()),
/// )
/// ```
library;

// Core
export 'src/core/ai_assistant.dart';
export 'src/core/ai_assistant_config.dart';
export 'src/core/ai_assistant_controller.dart';
export 'src/core/ai_event.dart';
export 'src/core/ai_logger.dart';

// Context (navigator observer for developers to plug in)
export 'src/context/ai_navigator_observer.dart';

// LLM Providers
export 'src/llm/llm_provider.dart';
export 'src/llm/providers/claude_provider.dart';
export 'src/llm/providers/gemini_provider.dart';
export 'src/llm/providers/openai_provider.dart';

// Tools (for custom tool registration)
export 'src/tools/tool_definition.dart';
export 'src/tools/tool_result.dart';

// Models (for type access)
export 'src/models/action_step.dart';
export 'src/models/agent_action.dart';
export 'src/models/chat_content.dart';
export 'src/models/chat_message.dart';

// Agent (public types for config callbacks)
export 'src/llm/react_agent.dart' show AgentResponse;

// Manifest (build-time app context)
export 'src/manifest/manifest.dart';

// Voice
export 'src/voice/voice_input_service.dart';
export 'src/voice/voice_output_service.dart';