## 0.1.2

### Fixed

- Suppress deprecated `hasFlag`/`flags` warnings for newer Flutter SDK compatibility.
- Resize demo GIFs in README to 300px side-by-side layout.

## 0.1.1

### Fixed

- Dart formatter compliance across all source files (50/50 static analysis).
- Lint issues in `semantics_walker.dart` (`curly_braces_in_flow_control_structures`).
- Unresolved dartdoc reference `[enableLogging]` in `AiLogger`.

## 0.1.0

- Initial release.
- ReAct agent loop with multi-step task execution (tap, type, scroll, navigate).
- Semantics-based screen reading — no instrumentation needed.
- LLM providers: Gemini, Claude, OpenAI.
- Voice input (speech-to-text) with multi-locale support.
- Voice output (text-to-speech) with language auto-detection.
- Rich chat overlay with action feed, handoff mode, and response popups.
- Custom tool registration for app-specific business logic.
- App manifest generation for structured screen descriptions.
- Analytics event system via `onEvent` callback.
