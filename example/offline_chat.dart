// Offline-first LLM chat demo — run with:
//   dart example/offline_chat.dart
//
// Demonstrates the full llm_outbox lifecycle in two clean phases: a prompt
// queued offline that survives a 429 and delivers with backoff, then a
// hopeless prompt that dead-letters, gets inspected, and is requeued with a
// fresh budget — plus a conversation transcript with mid-stream
// checkpointing. All against a scripted fake endpoint: zero API keys.
import 'dart:io';

import 'package:llm_outbox/llm_outbox.dart';

Future<void> main() async {
  final dir = await Directory.systemTemp.createTemp('llm_outbox_demo');
  print('── llm_outbox demo (storage: ${dir.path}) ──\n');

  // 1) BYOK vault: keys live behind a SecureStorage interface.
  final keyring = Keyring(MemorySecureStorage());
  await keyring.setKey('openai', 'sk-demo');
  print('keyring: key stored for providers ${await keyring.providers()}\n');

  // Scripted provider: phase A gets a 429 then success; phase B fails
  // terminally-ish (transient ×3) so the prompt dead-letters.
  final fake = FakeLlmEndpoint()
    ..enqueueFailure(const LlmFailure(
        LlmFailureKind.rateLimited, '429 slow down',
        retryAfter: Duration(milliseconds: 20)))
    ..enqueueText('Cairo is the capital of Egypt.')
    ..enqueueFailure(const LlmFailure(LlmFailureKind.transient, 'upstream 503'))
    ..enqueueFailure(const LlmFailure(LlmFailureKind.transient, 'upstream 503'))
    ..enqueueFailure(
        const LlmFailure(LlmFailureKind.transient, 'upstream 503'));

  final queue = PromptQueue(
    storage: FileQueueStorage(Directory('${dir.path}/queue')),
    endpoint: fake,
    sink: (prompt, response) async {
      print('   delivered "${prompt.request.prompt}"');
    },
    baseDelay: const Duration(milliseconds: 5),
    maxDelay: const Duration(milliseconds: 40),
  );

  // ── Phase A: offline → queue → 429 → backoff → delivered ──
  print('phase A — user goes offline, asks a question:');
  await queue.enqueue(const CompletionRequest(
      prompt: 'What is the capital of Egypt?',
      metadata: {'model': 'gpt-4o-mini'}));
  print('   enqueued while offline → ${queue.snapshot()} (already on disk)');

  print('   connectivity returns, draining…');
  final first = await queue.flush();
  print(
      '   report: delivered=${first.delivered} deadLettered=${first.deadLettered}\n');

  // ── Phase B: hopeless prompt → dead-letter → inspect → requeue ──
  print('phase B — a prompt that keeps failing:');
  final doomed = await queue.enqueue(const CompletionRequest(
      prompt: 'This one will keep failing',
      metadata: {'model': 'gpt-4o-mini'}));
  final second = await queue.flush();
  print(
      '   report: delivered=${second.delivered} deadLettered=${second.deadLettered}');
  print('   dead after ${doomed.attempts} attempts — "${doomed.lastError}"');

  fake.enqueueText('Recovered on requeue!');
  await queue.requeue(doomed.id, maxAttempts: 2);
  final third = await queue.flush();
  print(
      '   after requeue: delivered=${third.delivered}, state=${doomed.state.name}\n');

  // ── Transcript with mid-stream checkpointing ──
  final chat =
      ConversationStore(FileConversationStorage(Directory('${dir.path}/chat')));
  await chat.add(
      'demo',
      Message(
          id: 'u1',
          role: MessageRole.user,
          text: 'What is the capital of Egypt?',
          at: DateTime.now()));
  await chat.checkpoint('demo', 'a1', 'Cairo is the cap'); // tokens land…
  await chat.checkpoint('demo', 'a1', 'Cairo is the capital of Egypt.');
  await chat.completeStream('demo', 'a1');
  // Crash mid-stream instead? keepPartial('demo', 'a1') preserves what landed.
  print('transcript (${(await chat.history('demo')).length} messages):');
  for (final m in await chat.history('demo')) {
    print('   ${m.role.name.padRight(9)} '
        '${m.partial ? "(partial) " : ""}${m.text}');
  }
  print('\nfinal snapshot: ${queue.snapshot()}');

  queue.dispose();
  await dir.delete(recursive: true);
}
