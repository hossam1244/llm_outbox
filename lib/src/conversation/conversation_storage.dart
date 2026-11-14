import 'dart:convert';
import 'dart:io';

import 'message.dart';

/// Persistence edge for [ConversationStore]. Implementations append in
/// order per conversation; partial checkpointing upserts by message id.
abstract interface class ConversationStorage {
  Future<void> append(String conversationId, Message message);
  Future<void> upsertPartial(
      String conversationId, String messageId, String partialText);
  Future<void> finalizePartial(String conversationId, String messageId,
      {bool keepPartial = false});
  Future<List<Message>> load(String conversationId);
  Future<void> clear(String conversationId);
}

/// In-memory [ConversationStorage].
class MemoryConversationStorage implements ConversationStorage {
  final Map<String, List<Message>> _conversations = {};

  @override
  Future<void> append(String conversationId, Message message) async {
    _conversations.putIfAbsent(conversationId, () => []).add(message);
  }

  @override
  Future<void> upsertPartial(
      String conversationId, String messageId, String partialText) async {
    final list = _conversations.putIfAbsent(conversationId, () => []);
    for (var i = 0; i < list.length; i++) {
      if (list[i].id == messageId) {
        list[i] = list[i].copyWith(text: partialText, partial: true);
        return;
      }
    }
    list.add(Message(
        id: messageId,
        role: MessageRole.assistant,
        text: partialText,
        at: DateTime.now(),
        partial: true));
  }

  @override
  Future<void> finalizePartial(String conversationId, String messageId,
      {bool keepPartial = false}) async {
    final list = _conversations[conversationId] ?? const [];
    for (var i = 0; i < list.length; i++) {
      if (list[i].id == messageId) {
        list[i] = list[i].copyWith(partial: keepPartial);
        return;
      }
    }
  }

  @override
  Future<List<Message>> load(String conversationId) async =>
      List.of(_conversations[conversationId] ?? const []);

  @override
  Future<void> clear(String conversationId) async =>
      _conversations.remove(conversationId);
}

/// Durable one-file-per-conversation [ConversationStorage] (dart:io).
class FileConversationStorage implements ConversationStorage {
  FileConversationStorage(this.directory) {
    directory.createSync(recursive: true);
  }

  final Directory directory;

  File _fileFor(String conversationId) =>
      File('${directory.path}/$conversationId.jsonl');

  Future<List<Message>> _read(String conversationId) async {
    final file = _fileFor(conversationId);
    if (!await file.exists()) return const [];
    final messages = <Message>[];
    for (final line in await file.readAsLines()) {
      if (line.trim().isEmpty) continue;
      messages.add(
          Message.fromJson((jsonDecode(line) as Map<Object?, Object?>).cast()));
    }
    return messages;
  }

  Future<void> _write(String conversationId, List<Message> messages) async {
    final buffer = StringBuffer();
    for (final m in messages) {
      buffer.writeln(jsonEncode(m.toJson()));
    }
    await _fileFor(conversationId)
        .writeAsString(buffer.toString(), flush: true);
  }

  @override
  Future<void> append(String conversationId, Message message) async {
    final messages = [...await _read(conversationId), message];
    await _write(conversationId, messages);
  }

  @override
  Future<void> upsertPartial(
      String conversationId, String messageId, String partialText) async {
    final messages = [...await _read(conversationId)];
    var replaced = false;
    for (var i = 0; i < messages.length; i++) {
      if (messages[i].id == messageId) {
        messages[i] = messages[i].copyWith(text: partialText, partial: true);
        replaced = true;
        break;
      }
    }
    if (!replaced) {
      messages.add(Message(
          id: messageId,
          role: MessageRole.assistant,
          text: partialText,
          at: DateTime.now(),
          partial: true));
    }
    await _write(conversationId, messages);
  }

  @override
  Future<void> finalizePartial(String conversationId, String messageId,
      {bool keepPartial = false}) async {
    final messages = [...await _read(conversationId)];
    for (var i = 0; i < messages.length; i++) {
      if (messages[i].id == messageId) {
        messages[i] = messages[i].copyWith(partial: keepPartial);
        break;
      }
    }
    await _write(conversationId, messages);
  }

  @override
  Future<List<Message>> load(String conversationId) => _read(conversationId);

  @override
  Future<void> clear(String conversationId) async {
    final file = _fileFor(conversationId);
    if (await file.exists()) await file.delete();
  }
}
