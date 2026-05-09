import 'dart:typed_data';

import 'package:flutter_ai_assistant/flutter_ai_assistant.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Typed exceptions', () {
    test('AuthenticationException carries message', () {
      const e = AuthenticationException('bad key');
      expect(e.message, 'bad key');
      expect(e.toString(), contains('AuthenticationException'));
      expect(e.toString(), contains('bad key'));
    });

    test('RateLimitException carries optional retryAfter', () {
      const e = RateLimitException('429', retryAfter: Duration(seconds: 5));
      expect(e.retryAfter, const Duration(seconds: 5));
    });

    test('ContextOverflowException is distinct from RateLimitException', () {
      const a = ContextOverflowException('too long');
      const b = RateLimitException('too many');
      expect(a, isNot(isA<RateLimitException>()));
      expect(b, isNot(isA<ContextOverflowException>()));
    });

    test(
      'ContentFilteredException is distinct from AuthenticationException',
      () {
        const a = ContentFilteredException('blocked');
        const b = AuthenticationException('forbidden');
        expect(a, isNot(isA<AuthenticationException>()));
        expect(b, isNot(isA<ContentFilteredException>()));
      },
    );
  });

  group('LlmMessage factories', () {
    test('user / assistant / system / toolResult set role and content', () {
      expect(LlmMessage.user('hi').role, LlmRole.user);
      expect(LlmMessage.user('hi').content, 'hi');
      expect(LlmMessage.assistant('hello').role, LlmRole.assistant);
      expect(LlmMessage.system('rules').role, LlmRole.system);
      final t = LlmMessage.toolResult('id-1', 'ok');
      expect(t.role, LlmRole.tool);
      expect(t.toolCallId, 'id-1');
      expect(t.content, 'ok');
    });

    test('assistantToolCalls preserves calls and optional thought', () {
      final calls = [
        const ToolCall(
          id: 'a',
          name: 'tap_element',
          arguments: {'label': 'OK'},
        ),
      ];
      final m = LlmMessage.assistantToolCalls(calls, thought: 'about to tap');
      expect(m.role, LlmRole.assistant);
      expect(m.toolCalls, calls);
      expect(m.content, 'about to tap');
    });

    test('userMultimodal attaches images', () {
      final img = LlmImageContent(
        bytes: Uint8List.fromList([1, 2, 3]),
        mimeType: 'image/png',
      );
      final m = LlmMessage.userMultimodal('look', [img]);
      expect(m.role, LlmRole.user);
      expect(m.images, hasLength(1));
      expect(m.images!.first.mimeType, 'image/png');
    });
  });

  group('LlmResponse', () {
    test('isToolCall reflects toolCalls presence', () {
      const empty = LlmResponse();
      expect(empty.isToolCall, isFalse);
      const text = LlmResponse(textContent: 'hi');
      expect(text.isToolCall, isFalse);
      final calls = LlmResponse(
        toolCalls: const [ToolCall(id: 'a', name: 't', arguments: {})],
      );
      expect(calls.isToolCall, isTrue);
    });
  });

  group('LlmStreamEvent sealed hierarchy', () {
    test('matches by subtype in switch', () {
      String describe(LlmStreamEvent e) => switch (e) {
        LlmStreamText(:final delta) => 'text:$delta',
        LlmStreamToolCall(:final call) => 'tool:${call.name}',
        LlmStreamDone(:final cachedTokenCount) =>
          'done:cached=$cachedTokenCount',
      };

      expect(describe(const LlmStreamText('abc')), 'text:abc');
      expect(
        describe(
          const LlmStreamToolCall(
            ToolCall(id: 'i', name: 'tap', arguments: {}),
          ),
        ),
        'tool:tap',
      );
      expect(
        describe(const LlmStreamDone(cachedTokenCount: 12)),
        'done:cached=12',
      );
    });

    test('LlmStreamDone fields default to null', () {
      const d = LlmStreamDone();
      expect(d.cachedTokenCount, isNull);
      expect(d.promptTokenCount, isNull);
      expect(d.candidatesTokenCount, isNull);
    });
  });

  group('GeminiProvider deprecation', () {
    test('class is annotated @Deprecated and still constructs', () {
      // ignore: deprecated_member_use_from_same_package
      final legacy = GeminiProvider(apiKey: 'fake');
      expect(legacy, isA<LlmProvider>());
      legacy.dispose();
    });
  });

  group('ToolDefinition.toFunctionSchema', () {
    test('emits JSON Schema with required and properties', () {
      const def = ToolDefinition(
        name: 'book',
        description: 'book a ride',
        parameters: {
          'pickup': ToolParameter(type: 'string', description: 'from'),
          'vehicle': ToolParameter(
            type: 'string',
            description: 'kind',
            enumValues: ['auto', 'sedan'],
          ),
        },
        required: ['pickup'],
      );
      final schema = def.toFunctionSchema();
      expect(schema['name'], 'book');
      final params = schema['parameters'] as Map<String, dynamic>;
      expect(params['type'], 'object');
      expect(params['required'], ['pickup']);
      final props = params['properties'] as Map<String, dynamic>;
      expect(props['pickup']['type'], 'string');
      expect(props['vehicle']['enum'], ['auto', 'sedan']);
    });
  });
}
