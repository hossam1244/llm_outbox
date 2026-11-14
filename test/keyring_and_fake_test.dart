import 'package:llm_outbox/llm_outbox.dart';
import 'package:test/test.dart';

void main() {
  group('Keyring', () {
    test('set/get/remove round-trip per provider', () async {
      final ring = Keyring(MemorySecureStorage());
      await ring.setKey('openai', 'sk-a');
      await ring.setKey('anthropic', 'sk-ant-b');

      expect(await ring.getKey('openai'), 'sk-a');
      expect(await ring.getKey('anthropic'), 'sk-ant-b');
      expect(await ring.getKey('google'), isNull);

      await ring.removeKey('openai');
      expect(await ring.getKey('openai'), isNull);
    });

    test('providers lists only providers with keys', () async {
      final ring = Keyring(MemorySecureStorage());
      await ring.setKey('openai', 'sk-a');
      await ring.setKey('groq', 'gsk-b');
      expect(await ring.providers(), containsAll(['openai', 'groq']));
    });

    test('rotation is detected and reported', () async {
      final ring = Keyring(MemorySecureStorage());
      await ring.setKey('openai', 'sk-old');
      expect(ring.wasRotated('openai'), isFalse);

      await ring.setKey('openai', 'sk-new');
      expect(ring.wasRotated('openai'), isTrue);
      expect(await ring.getKey('openai'), 'sk-new');
    });

    test('keys are namespaced, not mixed with foreign secure entries',
        () async {
      final storage = MemorySecureStorage();
      await storage.write('unrelated.pref', 'x');
      final ring = Keyring(storage);
      await ring.setKey('openai', 'sk-a');

      expect(await ring.providers(), ['openai']);
    });
  });

  group('FakeLlmEndpoint + Cassette', () {
    test('scripted responses deliver in order and record requests', () async {
      final fake = FakeLlmEndpoint()
        ..enqueueText('first')
        ..enqueueText('second');

      expect(
          await fake.complete(const CompletionRequest(prompt: '1')),
          predicate<CompletionResponse>(
              (r) => r.text == 'first', 'responds with first'));
      expect(
          await fake.complete(const CompletionRequest(prompt: '2')),
          predicate<CompletionResponse>(
              (r) => r.text == 'second', 'responds with second'));
      expect(fake.requests.map((r) => r.prompt), ['1', '2']);
      expect(fake.remainingScript, 0);
    });

    test('offline mode throws transient failure for connectivity tests',
        () async {
      final fake = FakeLlmEndpoint()..offline = true;
      await expectLater(
        fake.complete(const CompletionRequest(prompt: 'x')),
        throwsA(isA<LlmFailure>()
            .having((f) => f.kind, 'kind', LlmFailureKind.transient)),
      );
    });

    test('exhausted script fails terminal, not silently looping', () async {
      final fake = FakeLlmEndpoint();
      await expectLater(
        fake.complete(const CompletionRequest(prompt: 'x')),
        throwsA(isA<LlmFailure>()
            .having((f) => f.kind, 'kind', LlmFailureKind.terminal)),
      );
    });

    test('cassette: record once, dump, replay deterministically offline',
        () async {
      final real = FakeLlmEndpoint()..enqueueText('recorded answer');
      final recorder = Cassette.record(real);

      final live = await recorder
          .complete(const CompletionRequest(prompt: 'same prompt'));
      expect(live.text, 'recorded answer');

      // Persist and replay — no inner endpoint needed.
      final dump = recorder.dump();
      final replayer = Cassette.replayFrom(dump);
      final replayed = await replayer
          .complete(const CompletionRequest(prompt: 'same prompt'));
      expect(replayed.text, 'recorded answer');

      // A prompt never recorded is an explicit miss, not a hang.
      await expectLater(
        replayer.complete(const CompletionRequest(prompt: 'never seen')),
        throwsA(isA<LlmFailure>()
            .having((f) => f.kind, 'kind', LlmFailureKind.terminal)),
      );
    });

    test('queue + fake: full offline-to-online lifecycle', () async {
      final fake = FakeLlmEndpoint()
        ..enqueueFailure(const LlmFailure(LlmFailureKind.rateLimited, '429',
            retryAfter: Duration(milliseconds: 1)))
        ..enqueueText('delivered after backoff');
      final conversation = ConversationStore(MemoryConversationStorage());
      final wired = PromptQueue(
        storage: MemoryQueueStorage(),
        endpoint: fake,
        sink: (p, r) => conversation.add(
            'chat',
            Message(
                id: 'm-${p.id}',
                role: MessageRole.assistant,
                text: r.text,
                at: DateTime.now())),
        baseDelay: const Duration(milliseconds: 1),
        maxDelay: const Duration(milliseconds: 2),
      );
      await wired.enqueue(const CompletionRequest(prompt: 'hi'));
      final report = await wired.flush();

      expect(report.delivered, 1);
      expect((await conversation.history('chat')).single.text,
          'delivered after backoff');
      expect(fake.remainingScript, 0);
    });
  });
}
