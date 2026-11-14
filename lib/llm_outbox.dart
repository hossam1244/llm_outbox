/// llm_outbox — the offline-first persistence & reliability layer for LLM
/// apps in Dart and Flutter.
///
/// See the individual libraries for details:
/// - [PromptQueue] — persisted, retrying, dead-lettering prompt queue.
/// - [ConversationStore] — append-only transcripts with stream
///   checkpointing.
/// - [Keyring] — bring-your-own-key vault with rotation events.
/// - [FakeLlmEndpoint] / [Cassette] — deterministic LLM test doubles.
library;

export 'src/endpoint/llm_endpoint.dart';
export 'src/conversation/conversation_storage.dart';
export 'src/conversation/conversation_store.dart';
export 'src/conversation/message.dart';
export 'src/keyring/keyring.dart';
export 'src/queue/file_queue_storage.dart';
export 'src/queue/prompt_queue.dart';
export 'src/queue/queued_prompt.dart';
export 'src/queue/queue_storage.dart';
export 'src/testing/fake_llm_endpoint.dart';
