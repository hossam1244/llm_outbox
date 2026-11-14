# llm_outbox

[![pub.dev](https://img.shields.io/pub/v/llm_outbox.svg)](https://pub.dev/packages/llm_outbox)

**The offline-first persistence & reliability layer for LLM apps in Dart & Flutter** — a persisted prompt queue with retry and dead-lettering, resumable conversation storage, a bring-your-own-key vault, and deterministic test doubles. Works with any LLM client via a tiny endpoint interface.

> LLM clients ([llm_dart](https://pub.dev/packages/llm_dart), [openai_dart](https://pub.dev/packages/openai_dart), [langchain](https://pub.dev/packages/langchain)…) *send* requests. **llm_outbox makes sure they survive** — offline users, crashes, rate limits, and flaky streams.

```dart
final queue = PromptQueue(
  storage: FileQueueStorage(queueDir),   // durable before enqueue returns
  endpoint: myLlmClient,                 // any LlmEndpoint — see adapters below
  sink: (prompt, response) => chat.add(...),  // your delivery side-effect
);

// User goes offline? Queue it. Crash? It's already on disk.
final prompt = await queue.enqueue(
  CompletionRequest(prompt: 'Summarize this article', metadata: {'model': 'gpt-4o-mini'}),
);
await queue.flush(); // drains FIFO, retries with backoff, dead-letters the hopeless
```

## Why

Mobile LLM apps live in the real world: users ride the metro, streams die
mid-answer, providers return 429s, and crashes happen between "generated"
and "shown". The Dart ecosystem has great multi-provider *clients* and even
a failover *router* — but nobody owns what happens **between** the tap and
the token: persistence, retries that respect `Retry-After`, transcripts
that survive mid-stream crashes, and keys that never touch plain storage.

| Capability | llm_dart | flutter_llm_router | **llm_outbox** |
|---|---|---|---|
| Multi-provider client | ✅ | ✅ | via any client (adapter) |
| Failover / routing | — | ✅ | orthogonal — compose them |
| **Offline queue (persist-before-send)** | — | fails fast | ✅ |
| **Retry with backoff + Retry-After** | basic | ✅ | ✅ |
| **Dead-letter + requeue** | — | — | ✅ |
| **Conversation persistence** | — | — | ✅ (JSONL, stream checkpointing) |
| **Secure BYOK key vault** | — | — | ✅ (Keyring over SecureStorage) |
| **Deterministic test doubles** | — | — | ✅ (FakeLlmEndpoint + cassettes) |
| Startup restore of in-flight work | — | — | ✅ |

*Comparison based on the packages' published docs (Nov 2026).*

## The core: `PromptQueue`

The outbox pattern applied to LLM calls:

| Guarantee | How |
|---|---|
| **Nothing is lost** | `enqueue` persists to storage *before* returning — a crash can never lose a prompt |
| **FIFO drain** | Prompts send in `enqueuedAt` order |
| **Retry with a limit** | Transient failures back off exponentially (equal-jitter), honoring the provider's `Retry-After`; after `maxAttempts` the item is parked as **dead** — visible in `deadLetter()`, never silently dropped, never blocking the rest |
| **Terminal fast-fail** | Terminal failures (400, auth) dead-letter immediately — no pointless retries |
| **One drain** | Concurrent `flush()` calls share a single in-flight drain — nothing double-sends |
| **Startup restore** | Prompts found mid-flight after a crash are re-queued on `restore()` |
| **No duplicates** | Optional `dedupe: true` single-flights identical pending prompts |
| **Observable** | `changes` / `snapshot()` drive live "3 pending · 1 sending" badges with frozen event snapshots |

## Everything else

- **`ConversationStore`** — append-only transcripts with **partial-stream checkpointing**: tokens are persisted as they arrive, so a crash mid-answer keeps the partial message (flagged `partial`) and a resumed stream continues the same message id. File storage is newline-delimited JSON; export/import included.
- **`Keyring`** — bring-your-own-key vault over a `SecureStorage` interface: one named key per provider, rotation detection (`wasRotated`), namespaced entries. In-memory impl for tests; the README recipe below wires `flutter_secure_storage`.
- **`FakeLlmEndpoint`** — script responses or failures (kinds: transient / terminal / rate-limited, with `Retry-After`), simulate latency and offline mode.
- **`Cassette`** — record a real endpoint once, `dump()` the request→response map to JSON, replay it forever in CI: deterministic, offline, free. Cassette misses fail loudly (terminal), never hang.

## Adapting your client

Implement one method:

```dart
class MyLlmDartEndpoint implements LlmEndpoint {
  MyLlmDartEndpoint(this.provider);
  final llm.Provider provider;

  @override
  Future<CompletionResponse> complete(CompletionRequest request) async {
    try {
      final res = await provider.complete(/* map request */);
      return CompletionResponse(text: res.text);
    } on llm.RateLimitException catch (e) {
      throw LlmFailure(LlmFailureKind.rateLimited, '$e', retryAfter: e.retryAfter);
    } on llm.ApiException catch (e) {
      throw LlmFailure(
        e.isRetryable ? LlmFailureKind.transient : LlmFailureKind.terminal, '$e');
    }
  }
}
```

Classifying failures into `transient` / `terminal` / `rateLimited` is the
whole contract — the queue handles the rest.

### flutter_secure_storage adapter for `Keyring`

```dart
class SecureKeychain implements SecureStorage {
  final _fs = const FlutterSecureStorage();
  @override
  Future<String?> read(String key) => _fs.read(key: key);
  @override
  Future<void> write(String key, String value) => _fs.write(key: key, value: value);
  @override
  Future<void> delete(String key) => _fs.delete(key: key);
  @override
  Future<List<String>> listKeys() async =>
      (await _fs.readAll()).keys.toList(growable: false);
}
```

## Install

```yaml
dependencies:
  llm_outbox: ^0.1.0
```

## Run the demo

```bash
dart example/llm_outbox.dart
```

Scripts a full lifecycle with zero API keys: offline enqueue → drain with a
429 + backoff → delivery → a prompt that exhausts its retries → dead-letter
inspection → requeue → transcript with stream checkpointing.

## Test it

```bash
dart test    # 28 deterministic tests: the full queue contract, store, keyring,
             # cassettes, and an offline→online integration pass
dart analyze # clean under strict-casts / strict-inference / strict-raw-types
```

## Status

v0.1.0 — MIT. Pure Dart (Flutter-ready: `FileQueueStorage` /
`FileConversationStorage` use `dart:io`; use the memory doubles on web).
Built as the persistence & reliability sibling to
[mutation_queue](https://github.com/hossam1244/mutation_queue) and
[auth-refresh](https://github.com/hossam1244/auth-refresh).
