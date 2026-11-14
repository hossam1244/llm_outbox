import 'dart:convert';

import 'conversation_storage.dart';
import 'message.dart';

/// Append-only conversation log with partial-stream checkpointing.
///
/// LLM streams die mid-answer — the app backgrounds, the socket drops, the
/// user kills the app. [ConversationStore] persists tokens as they arrive,
/// so a crash keeps the partial transcript and the next turn resumes from
/// what actually landed.
class ConversationStore {
  ConversationStore(this.storage);

  final ConversationStorage storage;

  /// Appends a completed message.
  Future<void> add(String conversationId, Message message) =>
      storage.append(conversationId, message);

  /// Persists a partial assistant message as it streams. Each call updates
  /// the same in-flight message (identified by [messageId]) rather than
  /// appending, so the transcript shows one growing message, never token
  /// fragments.
  Future<void> checkpoint(
          String conversationId, String messageId, String partialText) =>
      storage.upsertPartial(conversationId, messageId, partialText);

  /// Finalizes a streamed message that completed.
  Future<void> completeStream(String conversationId, String messageId) =>
      storage.finalizePartial(conversationId, messageId);

  /// Marks a partial message as interrupted but visible (crash case). It
  /// stays in the transcript flagged [Message.partial]; a resumed generation
  /// can append to it via [checkpoint] with the same [messageId].
  Future<void> keepPartial(String conversationId, String messageId) =>
      storage.finalizePartial(conversationId, messageId, keepPartial: true);

  /// Full transcript for a conversation, oldest first.
  Future<List<Message>> history(String conversationId) =>
      storage.load(conversationId);

  /// Deletes a conversation entirely.
  Future<void> clear(String conversationId) => storage.clear(conversationId);

  /// JSON export — backups, debugging, migration between storage impls.
  Future<String> export(String conversationId) async {
    final messages = await history(conversationId);
    return jsonEncode(messages.map((m) => m.toJson()).toList());
  }

  /// Imports a previously exported transcript (appends).
  Future<void> import(String conversationId, String json) async {
    final list =
        (jsonDecode(json) as List<Object?>).cast<Map<Object?, Object?>>();
    for (final m in list) {
      await storage.append(conversationId, Message.fromJson(m.cast()));
    }
  }
}
