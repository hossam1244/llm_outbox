import 'dart:async';
import 'dart:io';

import 'package:llm_outbox/llm_outbox.dart';
import 'package:test/test.dart';

void main() {
  group('PromptQueue contract', () {
    test('persist-before-return: prompt is in storage when enqueue resolves',
        () async {
      final storage = MemoryQueueStorage();

      final seen = <String>[];
      final persisted = <String>[];
      // A sink that inspects storage the moment a prompt arrives.
      final probeQueue = PromptQueue(
        storage: storage,
        endpoint: FakeLlmEndpoint(),
        sink: (prompt, _) async {
          seen.add(prompt.request.prompt);
        },
      );
      // enqueue must persist before returning: after the future completes,
      // storage already holds the prompt even though nothing drained yet.
      await probeQueue.enqueue(
          CompletionRequest(prompt: 'hello', metadata: {'model': 'x'}));
      final loaded = await storage.load();
      persisted.addAll(loaded.map((p) => p.request.prompt));
      expect(persisted, contains('hello'));
      expect(seen, isEmpty); // nothing drained
    });

    test('FIFO: prompts deliver in enqueue order', () async {
      final fake = FakeLlmEndpoint()
        ..enqueueText('r1')
        ..enqueueText('r2')
        ..enqueueText('r3');
      final delivered = <String>[];
      final queue = PromptQueue(
        storage: MemoryQueueStorage(),
        endpoint: fake,
        sink: (p, r) async => delivered.add(p.request.prompt),
      );
      await queue.enqueue(const CompletionRequest(prompt: 'a'));
      await queue.enqueue(const CompletionRequest(prompt: 'b'));
      await queue.enqueue(const CompletionRequest(prompt: 'c'));

      final report = await queue.flush();

      expect(report.delivered, 3);
      expect(delivered, ['a', 'b', 'c']);
      expect(fake.requests.map((r) => r.prompt).toList(), ['a', 'b', 'c']);
    });

    test('retry after transient failure, then deliver', () async {
      final fake = FakeLlmEndpoint()
        ..enqueueFailure(const LlmFailure(LlmFailureKind.transient, 'boom'))
        ..enqueueText('ok');
      final queue = PromptQueue(
        storage: MemoryQueueStorage(),
        endpoint: fake,
        baseDelay: Duration.zero,
        maxDelay: Duration.zero,
      );
      final prompt = await queue.enqueue(const CompletionRequest(prompt: 'x'));

      final report = await queue.flush();

      expect(report.delivered, 1);
      expect(prompt.state, PromptState.done);
      expect(prompt.attempts, 2);
      expect(prompt.lastError, isNull);
    });

    test('dead-letter after max attempts; later drains keep flowing', () async {
      final fake = FakeLlmEndpoint()
        ..enqueueFailure(const LlmFailure(LlmFailureKind.transient, 'a-1'))
        ..enqueueFailure(const LlmFailure(LlmFailureKind.transient, 'a-2'))
        ..enqueueFailure(const LlmFailure(LlmFailureKind.transient, 'a-3'));
      final queue = PromptQueue(
        storage: MemoryQueueStorage(),
        endpoint: fake,
        baseDelay: Duration.zero,
        maxDelay: Duration.zero,
      );
      final a = await queue.enqueue(const CompletionRequest(prompt: 'a'),
          maxAttempts: 3);

      final first = await queue.flush();
      expect(first.deadLettered, 1);
      expect(first.delivered, 0);
      expect(a.state, PromptState.dead);
      expect(a.lastError, 'a-3');
      expect(queue.deadLetter().map((p) => p.request.prompt), ['a']);

      // A dead letter never blocks the queue: a later prompt drains fine.
      fake.enqueueText('b-ok');
      final b = await queue.enqueue(const CompletionRequest(prompt: 'b'));
      final second = await queue.flush();
      expect(second.delivered, 1);
      expect(b.state, PromptState.done);
    });

    test('terminal failures dead-letter immediately without retries', () async {
      final fake = FakeLlmEndpoint()
        ..enqueueFailure(
            const LlmFailure(LlmFailureKind.terminal, 'bad request'))
        ..enqueueText('next');
      final queue = PromptQueue(
        storage: MemoryQueueStorage(),
        endpoint: fake,
        baseDelay: Duration.zero,
      );
      final t = await queue.enqueue(const CompletionRequest(prompt: 't'),
          maxAttempts: 5);

      await queue.flush();

      expect(t.state, PromptState.dead);
      expect(t.attempts, 1); // no retries on terminal
    });

    test('rate limit honors Retry-After when it exceeds computed backoff',
        () async {
      final fake = FakeLlmEndpoint()
        ..enqueueFailure(const LlmFailure(LlmFailureKind.rateLimited, '429',
            retryAfter: Duration(milliseconds: 50)))
        ..enqueueText('ok');
      final queue = PromptQueue(
        storage: MemoryQueueStorage(),
        endpoint: fake,
        baseDelay: const Duration(milliseconds: 1), // tiny computed backoff
        maxDelay: const Duration(milliseconds: 2),
      );
      await queue.enqueue(const CompletionRequest(prompt: 'r'));

      final sw = Stopwatch()..start();
      await queue.flush();
      sw.stop();

      // Retry-After is a minimum wait: 50ms must beat the 1-2ms backoff.
      expect(sw.elapsed >= const Duration(milliseconds: 45), isTrue,
          reason: 'drain must wait out the Retry-After hint');
      expect(sw.elapsed < const Duration(seconds: 5), isTrue);
    });

    test('single shared drain under concurrent flushes', () async {
      final fake = FakeLlmEndpoint();
      for (var i = 0; i < 3; i++) {
        fake.enqueueText('r$i');
      }
      final queue = PromptQueue(
        storage: MemoryQueueStorage(),
        endpoint: fake,
        sink: (p, r) async {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        },
      );
      await queue.enqueue(const CompletionRequest(prompt: '1'));
      await queue.enqueue(const CompletionRequest(prompt: '2'));
      await queue.enqueue(const CompletionRequest(prompt: '3'));

      // Three concurrent flushes share ONE drain: every caller receives
      // the same report and the endpoint sees each prompt exactly once.
      final reports =
          await Future.wait([queue.flush(), queue.flush(), queue.flush()]);

      expect(reports.map((r) => r.delivered), everyElement(3));
      expect(fake.requests.length, 3);
    });

    test('startup restore re-queues prompts mid-flight during a crash',
        () async {
      final dir = await Directory.systemTemp.createTemp('llm_outbox_restore');
      final storage = FileQueueStorage(dir);
      final crashed = PromptQueue(
          storage: storage, endpoint: FakeLlmEndpoint()..offline = true);
      final p1 =
          await crashed.enqueue(const CompletionRequest(prompt: 'survivor'));
      // Simulate crash mid-send: storage says sending, process dies.
      p1.state = PromptState.sending;
      await storage.update(p1);

      final revived = PromptQueue(
        storage: storage,
        endpoint: FakeLlmEndpoint()..enqueueText('ok'),
      );
      await revived.restore();

      final report = await revived.flush();
      expect(report.delivered, 1);
      await dir.delete(recursive: true);
    });

    test('dedupe rejects identical pending prompt, accepts different one',
        () async {
      final queue = PromptQueue(
        storage: MemoryQueueStorage(),
        endpoint: FakeLlmEndpoint()..enqueueText('a'),
        dedupe: true,
      );
      final first =
          await queue.enqueue(const CompletionRequest(prompt: 'same'));
      final second =
          await queue.enqueue(const CompletionRequest(prompt: 'same'));
      final other =
          await queue.enqueue(const CompletionRequest(prompt: 'different'));

      expect(second.id, first.id); // single-flight style dedup
      expect(other.id, isNot(first.id));
    });

    test('snapshot counts drive UI badges', () async {
      final queue = PromptQueue(
        storage: MemoryQueueStorage(),
        endpoint: FakeLlmEndpoint()
          ..enqueueFailure(const LlmFailure(LlmFailureKind.terminal, 'x')),
      );
      await queue.enqueue(const CompletionRequest(prompt: '1'));
      await queue.enqueue(const CompletionRequest(prompt: '2'));
      expect(queue.snapshot().pending, 2);
      await queue.flush();
      final snap = queue.snapshot();
      expect(snap.dead, 2);
      expect(snap.pending, 0);
    });

    test('cancel removes a pending prompt before send', () async {
      final fake = FakeLlmEndpoint();
      final storage = MemoryQueueStorage();
      final queue = PromptQueue(storage: storage, endpoint: fake);
      final p = await queue.enqueue(const CompletionRequest(prompt: 'bye'));
      await queue.cancel(p.id);

      expect(queue.snapshot().pending, 0);
      expect(storage.count, 0); // removed from storage too
      await queue.flush();
      expect(fake.requests, isEmpty);
    });

    test('requeue revives a dead prompt with fresh attempts', () async {
      final fake = FakeLlmEndpoint()
        ..enqueueFailure(const LlmFailure(LlmFailureKind.terminal, 'nope'))
        ..enqueueText('alive');
      final queue = PromptQueue(
        storage: MemoryQueueStorage(),
        endpoint: fake,
        baseDelay: Duration.zero,
      );
      final p = await queue.enqueue(const CompletionRequest(prompt: 'p'),
          maxAttempts: 1);
      await queue.flush();
      expect(p.state, PromptState.dead);

      await queue.requeue(p.id, maxAttempts: 2);
      final report = await queue.flush();
      expect(report.delivered, 1);
      expect(p.state, PromptState.done);
    });

    test('changes stream emits state transitions', () async {
      final queue = PromptQueue(
        storage: MemoryQueueStorage(),
        endpoint: FakeLlmEndpoint()..enqueueText('ok'),
        baseDelay: Duration.zero,
      );
      final states = <PromptState>[];
      final sub = queue.changes.listen((p) => states.add(p.state));
      await queue.enqueue(const CompletionRequest(prompt: 's'));
      await queue.flush();
      await Future<void>.delayed(Duration.zero);
      sub.cancel();

      expect(
          states,
          containsAll(
              [PromptState.pending, PromptState.sending, PromptState.done]));
    });
  });
}
