import 'queued_prompt.dart';

/// Persistence edge for the [PromptQueue]. Implementations MUST be
/// durable-before-return: once `save`/`update`/`remove` completes, the
/// change survives a crash.
///
/// The queue calls these synchronously in the sense that it awaits each one
/// before proceeding — a storage that buffers writes behind its back breaks
/// the persist-before-return guarantee.
abstract interface class QueueStorage {
  /// Loads every persisted prompt (pending, sending, failed and dead) in any
  /// order — the queue re-sorts by [QueuedPrompt.enqueuedAt].
  Future<List<QueuedPrompt>> load();

  /// Persists a newly enqueued prompt. MUST be durable before returning.
  Future<void> save(QueuedPrompt prompt);

  /// Persists a mutation (attempt count, state transitions, last error).
  Future<void> update(QueuedPrompt prompt);

  /// Removes a prompt permanently (after successful send or cancellation).
  Future<void> remove(String id);
}

/// In-memory [QueueStorage] — tests, previews, and non-durable setups.
class MemoryQueueStorage implements QueueStorage {
  final Map<String, QueuedPrompt> _prompts = {};

  @override
  Future<List<QueuedPrompt>> load() async =>
      _prompts.values.toList(growable: false);

  @override
  Future<void> save(QueuedPrompt prompt) async => _prompts[prompt.id] = prompt;

  @override
  Future<void> update(QueuedPrompt prompt) async =>
      _prompts[prompt.id] = prompt;

  @override
  Future<void> remove(String id) async => _prompts.remove(id);

  /// Number of prompts currently held (test introspection).
  int get count => _prompts.length;
}
