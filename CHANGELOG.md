## 0.2.0

### Added

- **`FirebaseAiProvider`** — new recommended Gemini provider built on
  [`firebase_ai`](https://pub.dev/packages/firebase_ai) (Firebase AI Logic).
  Routes calls through Firebase so the Gemini API key never ships in the app
  binary, supports Firebase App Check (Play Integrity / App Attest /
  reCAPTCHA Enterprise) for per-request platform attestation, and unlocks
  implicit prompt caching automatically on Gemini 2.5+ models.
- `FirebaseAiProvider.streamMessage(...)` for incremental streaming responses
  in custom chat UIs (the ReAct agent loop still uses non-streaming
  `sendMessage`).
- `FirebaseAiProvider.generateStructured(...)` — one-shot prompt with
  `responseSchema` JSON output for direct use outside the agent.
- `ThinkingConfig` parameter on `FirebaseAiProvider` to expose Gemini 2.5
  thinking budgets.
- `bin/generate.dart` learnt a Vertex AI + Application Default Credentials
  auth path. Pass `--project=YOUR_GCP_PROJECT` after running `gcloud auth
  application-default login`; no long-lived `GEMINI_API_KEY` needed in `.env`
  or CI variables.

### Changed

- Default Gemini model bumped to `gemini-2.5-flash` (was `gemini-2.0-flash`).
- README: new "Recommended: FirebaseAiProvider" section documenting three
  security postures (with App Check, Firebase without App Check, legacy raw
  key) and a "Migrating from `GeminiProvider`" subsection.

### Deprecated

- `GeminiProvider` is now `@Deprecated`. Upstream `google_generative_ai` was
  archived by Google in December 2025. `GeminiProvider` will be removed in
  v0.3.0; migrate to `FirebaseAiProvider`.
- `bin/generate.dart` `--api-key` / `--env` paths emit a deprecation warning
  recommending `--project=` + ADC.

### Security

- The migration path eliminates the need to ship a Gemini API key inside the
  app binary. Existing apps that have shipped `GeminiProvider(apiKey: ...)`
  should rotate the key in [Google AI
  Studio](https://aistudio.google.com/app/apikey) after upgrading — keys
  already in distributed binaries remain extractable.

### Platform support

- `firebase_ai` does not ship Linux or Windows desktop bindings. Apps that
  target those platforms and used `GeminiProvider` should either pin to
  `^0.1.x` or switch to `ClaudeProvider` / `OpenAiProvider`. Android, iOS,
  Web, and macOS are fully supported.

### Breaking

- `GeminiProvider` now produces an analyzer deprecation warning at every
  instantiation site. The class still works for one minor cycle.
- Default Gemini model identifier changed (`gemini-2.0-flash` →
  `gemini-2.5-flash`). Override the `model` parameter to keep the previous
  model.

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
