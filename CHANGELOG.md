# Changelog

## 0.1.0

- Initial release.
- `PromptQueue`: persisted FIFO prompt queue — persist-before-return, retry
  with exponential backoff and jitter (honoring a Retry-After hint),
  dead-letter after max attempts, single shared drain, startup restore,
  observability, per-item cancellation, optional dedup of identical pending
  prompts.
- `ConversationStore`: append-only message log per conversation with
  partial-stream checkpointing and JSON export/import.
- `Keyring`: bring-your-own-key vault interface with rotation events,
  in-memory implementation, and a flutter_secure_storage adapter recipe.
- `FakeLlmEndpoint` + cassettes: programmable responses, latency/failure
  simulation, record/replay for deterministic tests.
