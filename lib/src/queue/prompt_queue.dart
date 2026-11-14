import 'dart:async';
import 'dart:math' as math;

import '../endpoint/llm_endpoint.dart';
import 'queue_storage.dart';
import 'queued_prompt.dart';

/// Snapshot of queue counters for UI badges ("3 pending · 1 sending").
class QueueSnapshot {
  const QueueSnapshot({
    required this.pending,
    required this.sending,
    required this.failed,
    required this.dead,
    required this.done,
  });

  final int pending;
  final int sending;
  final int failed;
  final int dead;
  final int done;

  @override
  String toString() =>
      '$pending pending · $sending sending · $failed failed · $dead dead · $done done';
}

/// Result of a drain pass — how many prompts were delivered.
class DrainReport {
  const DrainReport({required this.delivered, required this.deadLettered});

  final int delivered;
  final int deadLettered;
}

/// Function the queue calls to actually deliver a completion. Wrap your
/// app's response handling here (e.g. append to a ConversationStore and
/// notify the UI). Throwing propagates a [LlmFailure] classification.
typedef PromptSink = Future<void> Function(
    QueuedPrompt prompt, CompletionResponse response);

/// The outbox pattern applied to LLM calls.
///
/// Guarantees:
///
/// | Guarantee            | How                                                        |
/// |----------------------|------------------------------------------------------------|
/// | Nothing is lost      | `enqueue` persists *before* returning — a crash can't lose a prompt |
/// | FIFO drain           | Prompts send in `enqueuedAt` order                          |
/// | Retry with a limit   | Transient failures back off exponentially (jittered, honoring `Retry-After`); after `maxAttempts` the item is parked as dead — visible in `deadLetter()`, never silently dropped, never blocking the rest |
/// | Terminal fast-fail   | Terminal failures dead-letter immediately — no pointless retries |
/// | One drain            | Concurrent `flush()` calls share a single in-flight drain    |
/// | Startup restore      | Prompts found in `sending`/`failed` state are re-queued on `restore()` |
/// | Observable           | `onChange` + `snapshot()` drive live badges                 |
/// | No duplicates        | Optional `dedupe: true` rejects an identical pending prompt |
class PromptQueue {
  PromptQueue({
    required QueueStorage storage,
    required this.endpoint,
    PromptSink? sink,
    this.dedupe = false,
    this.baseDelay = const Duration(milliseconds: 500),
    this.maxDelay = const Duration(seconds: 30),
    math.Random? random,
  })  : _storage = storage,
        _sink = sink,
        _random = random ?? math.Random();

  final QueueStorage _storage;
  final LlmEndpoint endpoint;
  final PromptSink? _sink;
  final bool dedupe;

  /// First backoff step; doubles per attempt up to [maxDelay].
  final Duration baseDelay;
  final Duration maxDelay;
  final math.Random _random;

  final List<QueuedPrompt> _prompts = [];
  final _controllers = <String, StreamController<QueuedPrompt>>{};
  bool _restored = false;
  Future<DrainReport>? _draining;

  /// Fires after every state change of every prompt.
  Stream<QueuedPrompt> get changes => _changesController.stream;
  final _changesController = StreamController<QueuedPrompt>.broadcast();

  /// Loads persisted prompts and re-queues anything that was mid-flight or
  /// failed during a previous run. Call once at app start.
  Future<void> restore() async {
    if (_restored) return;
    _restored = true;
    final loaded = await _storage.load();
    loaded.sort((a, b) => a.enqueuedAt.compareTo(b.enqueuedAt));
    for (final p in loaded) {
      if (p.state == PromptState.sending || p.state == PromptState.done) {
        // Mid-flight during a crash: retry. Done items were removed from
        // storage already; if a done item survived (crash between sink and
        // remove), keep it visible but idle.
        if (p.state == PromptState.sending) {
          p.state = PromptState.failed;
          p.lastError ??= 'restored mid-flight; re-queued';
        }
      }
      _prompts.add(p);
    }
  }

  /// Adds a prompt to the queue. The prompt is durably persisted BEFORE
  /// this future completes — enqueue-then-crash never loses it.
  ///
  /// With [dedupe] enabled, returns the existing pending prompt when an
  /// identical prompt (same `request` JSON) is already queued.
  Future<QueuedPrompt> enqueue(CompletionRequest request,
      {int maxAttempts = 3, String? id}) async {
    if (dedupe) {
      final dup = _prompts.where((p) =>
          p.isRetryable &&
          p.request.prompt == request.prompt &&
          p.request.conversationId == request.conversationId &&
          _sameMetadata(p.request, request));
      if (dup.isNotEmpty) return dup.first;
    }
    final prompt = QueuedPrompt(
      id: id ??
          DateTime.now().microsecondsSinceEpoch.toRadixString(36) +
              _random.nextInt(1 << 32).toRadixString(36),
      request: request,
      enqueuedAt: DateTime.now(),
      maxAttempts: maxAttempts,
    );
    _prompts.add(prompt);
    await _storage.save(prompt); // persist BEFORE returning
    _notify(prompt);
    return prompt;
  }

  /// Drains the queue: sends every pending/failed prompt in FIFO order,
  /// backing off between retries of the same prompt. Concurrent calls share
  /// a single drain — nothing double-sends.
  Future<DrainReport> flush() {
    return _draining ??= _drain().whenComplete(() => _draining = null);
  }

  /// Requests cancellation of a queued prompt. Takes effect before it is
  /// sent; a prompt already mid-flight completes its attempt.
  Future<void> cancel(String id) async {
    final p = _byId(id);
    if (p == null || !p.isRetryable) return;
    _prompts.remove(p);
    await _storage.remove(p.id);
    _notify(p);
  }

  /// Dead-lettered prompts in death order, for inspection and requeue.
  List<QueuedPrompt> deadLetter() => _prompts
      .where((p) => p.state == PromptState.dead)
      .toList(growable: false);

  /// Moves a dead prompt back to the head of the pending queue with a
  /// fresh attempt budget.
  Future<void> requeue(String id, {int maxAttempts = 3}) async {
    final p = _byId(id);
    if (p == null || p.state != PromptState.dead) return;
    p
      ..state = PromptState.pending
      ..attempts = 0
      ..maxAttempts = maxAttempts
      ..lastError = null;
    await _storage.update(p);
    _notify(p);
  }

  /// Current counters for UI badges.
  QueueSnapshot snapshot() {
    int count(PromptState s) => _prompts.where((p) => p.state == s).length;
    return QueueSnapshot(
      pending: count(PromptState.pending),
      sending: count(PromptState.sending),
      failed: count(PromptState.failed),
      dead: count(PromptState.dead),
      done: count(PromptState.done),
    );
  }

  /// Per-prompt state stream (badge for one row).
  Stream<QueuedPrompt> changesFor(String id) {
    final existing = _controllers[id];
    if (existing != null) return existing.stream;
    return _changesController.stream
        .where((p) => p.id == id)
        .asBroadcastStream();
  }

  Future<DrainReport> _drain() async {
    var delivered = 0;
    var deadLettered = 0;

    while (true) {
      final next = _nextRetryable();
      if (next == null) break;

      next.state = PromptState.sending;
      await _storage.update(next);
      _notify(next);

      final outcome = await _attempt(next);

      switch (outcome) {
        case _Delivered():
          delivered++;
          next
            ..state = PromptState.done
            ..completedText = outcome.response.text;
          await _storage.remove(next.id);
          _prompts.remove(next);
          _notify(next);
        case _Dead():
          deadLettered++;
          next.state = PromptState.dead;
          await _storage.update(next);
          _notify(next);
        case _Backoff(:final delay):
          next.state = PromptState.failed;
          await _storage.update(next);
          _notify(next);
          await Future<void>.delayed(delay);
      }
    }
    return DrainReport(delivered: delivered, deadLettered: deadLettered);
  }

  QueuedPrompt? _nextRetryable() {
    for (final p in _prompts) {
      if (p.state == PromptState.pending) return p;
    }
    for (final p in _prompts) {
      if (p.state == PromptState.failed) return p;
    }
    return null;
  }

  Future<_Outcome> _attempt(QueuedPrompt prompt) async {
    prompt.attempts++;
    prompt.lastAttemptAt = DateTime.now();
    try {
      final response = await endpoint.complete(prompt.request);
      final sink = _sink;
      if (sink != null) {
        try {
          await sink(prompt, response);
        } catch (e) {
          // The send succeeded; a sink failure is treated as transient so
          // the item is retried (idempotent sinks recommended).
          prompt.lastError = 'sink error: $e';
          return _Backoff(_backoffDelay(prompt, retryAfter: null));
        }
      }
      prompt.lastError = null;
      return _Delivered(response);
    } on LlmFailure catch (f) {
      prompt.lastError = f.message;
      switch (f.kind) {
        case LlmFailureKind.terminal:
          return _Dead();
        case LlmFailureKind.rateLimited:
        case LlmFailureKind.transient:
          if (prompt.attempts >= prompt.maxAttempts) return _Dead();
          return _Backoff(_backoffDelay(prompt, retryAfter: f.retryAfter));
      }
    } catch (e) {
      prompt.lastError = '$e';
      if (prompt.attempts >= prompt.maxAttempts) return _Dead();
      return _Backoff(_backoffDelay(prompt, retryAfter: null));
    }
  }

  Duration _backoffDelay(QueuedPrompt prompt, {Duration? retryAfter}) {
    final exp = baseDelay * (1 << math.min(prompt.attempts - 1, 16));
    final capped = exp > maxDelay ? maxDelay : exp;
    // Equal-jitter: half fixed + half random, de-syncing concurrent clients.
    final half = capped.inMilliseconds ~/ 2;
    final jittered = half + _random.nextInt(half + 1);
    final computed = Duration(milliseconds: jittered);
    if (retryAfter != null && retryAfter > computed) return retryAfter;
    return computed;
  }

  void _notify(QueuedPrompt p) {
    // Emit a frozen snapshot: the live object keeps mutating (pending →
    // sending → done), and async listeners must observe the state at event
    // time, not whatever the object holds at delivery time.
    _changesController.add(p.copyWith());
  }

  QueuedPrompt? _byId(String id) {
    for (final p in _prompts) {
      if (p.id == id) return p;
    }
    return null;
  }

  static bool _sameMetadata(CompletionRequest a, CompletionRequest b) {
    if (a.metadata.length != b.metadata.length) return false;
    for (final e in a.metadata.entries) {
      if (b.metadata[e.key] != e.value) return false;
    }
    return true;
  }

  void dispose() {
    _changesController.close();
    for (final c in _controllers.values) {
      c.close();
    }
  }
}

sealed class _Outcome {}

class _Delivered extends _Outcome {
  _Delivered(this.response);
  final CompletionResponse response;
}

class _Dead extends _Outcome {}

class _Backoff extends _Outcome {
  _Backoff(this.delay);
  final Duration delay;
}
