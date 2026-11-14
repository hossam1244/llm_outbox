import 'dart:convert';
import 'dart:io';

import 'queue_storage.dart';
import 'queued_prompt.dart';

/// Durable [QueueStorage] writing JSON documents to a directory: one file
/// per prompt. Writes are flushed to disk before returning, which is what
/// makes the queue's persist-before-return guarantee real on mobile/desktop.
class FileQueueStorage implements QueueStorage {
  FileQueueStorage(this.directory) {
    directory.createSync(recursive: true);
  }

  final Directory directory;

  File _fileFor(String id) => File('${directory.path}/$id.json');

  @override
  Future<List<QueuedPrompt>> load() async {
    final prompts = <QueuedPrompt>[];
    for (final entity in directory.listSync()) {
      if (entity is! File || !entity.path.endsWith('.json')) continue;
      final json =
          jsonDecode(entity.readAsStringSync()) as Map<Object?, Object?>;
      prompts.add(QueuedPrompt.fromJson(json.cast()));
    }
    return prompts;
  }

  @override
  Future<void> save(QueuedPrompt prompt) => _write(prompt);

  @override
  Future<void> update(QueuedPrompt prompt) => _write(prompt);

  Future<void> _write(QueuedPrompt prompt) async {
    final file = _fileFor(prompt.id);
    await file.writeAsString(jsonEncode(prompt.toJson()), flush: true);
  }

  @override
  Future<void> remove(String id) async {
    final file = _fileFor(id);
    if (await file.exists()) await file.delete();
  }
}
