import 'dart:io';

import 'package:llm_outbox/llm_outbox.dart';
import 'package:test/test.dart';

void main() {
  group('ConversationStore', () {
    test('append-only history, oldest first', () async {
      final store = ConversationStore(MemoryConversationStorage());
      await store.add(
          'c1',
          Message(
              id: 'm1',
              role: MessageRole.user,
              text: 'hi',
              at: DateTime.now()));
      await store.add(
          'c1',
          Message(
              id: 'm2',
              role: MessageRole.assistant,
              text: 'hello',
              at: DateTime.now()));

      final history = await store.history('c1');
      expect(history.map((m) => m.text), ['hi', 'hello']);
    });

    test('stream checkpointing: one growing message, not fragments', () async {
      final store = ConversationStore(MemoryConversationStorage());
      await store.checkpoint('c1', 'a1', 'Hel');
      await store.checkpoint('c1', 'a1', 'Hello');
      await store.checkpoint('c1', 'a1', 'Hello, wor');
      await store.completeStream('c1', 'a1');

      final history = await store.history('c1');
      expect(history.length, 1);
      expect(history.single.text, 'Hello, wor');
      expect(history.single.partial, isFalse);
    });

    test('mid-stream crash keeps the partial transcript visible', () async {
      final store = ConversationStore(MemoryConversationStorage());
      await store.add(
          'c1',
          Message(
              id: 'u1', role: MessageRole.user, text: 'q', at: DateTime.now()));
      await store.checkpoint('c1', 'a1', 'partial answ');
      // Crash: no completeStream — simulate "keep what landed".
      await store.keepPartial('c1', 'a1');

      final history = await store.history('c1');
      expect(history.last.text, 'partial answ');
      expect(history.last.partial, isTrue);
    });

    test('resumed stream appends to the same message id', () async {
      final store = ConversationStore(MemoryConversationStorage());
      await store.checkpoint('c1', 'a1', 'partial answ');
      await store.keepPartial('c1', 'a1');
      // Resume: continue into the same id.
      await store.checkpoint('c1', 'a1', 'partial answer, continued');
      await store.completeStream('c1', 'a1');

      final history = await store.history('c1');
      expect(history.length, 1);
      expect(history.single.text, 'partial answer, continued');
    });

    test('file storage survives reload; export/import round-trips', () async {
      final dir = await Directory.systemTemp.createTemp('llm_outbox_conv');
      final store = ConversationStore(FileConversationStorage(dir));
      await store.add(
          'c9',
          Message(
              id: 'm1',
              role: MessageRole.user,
              text: 'persist me',
              at: DateTime(2026, 1, 1)));
      await store.checkpoint('c9', 'a1', 'sure');
      await store.completeStream('c9', 'a1');

      // Fresh store over the same directory sees the transcript.
      final reloaded = ConversationStore(FileConversationStorage(dir));
      final history = await reloaded.history('c9');
      expect(history.length, 2);

      // Export → clear → import round-trip.
      final json = await reloaded.export('c9');
      await reloaded.clear('c9');
      expect(await reloaded.history('c9'), isEmpty);
      await reloaded.import('c9', json);
      expect((await reloaded.history('c9')).length, 2);

      await dir.delete(recursive: true);
    });

    test('conversations are isolated', () async {
      final store = ConversationStore(MemoryConversationStorage());
      await store.add(
          'a',
          Message(
              id: '1',
              role: MessageRole.user,
              text: 'in a',
              at: DateTime.now()));
      await store.add(
          'b',
          Message(
              id: '2',
              role: MessageRole.user,
              text: 'in b',
              at: DateTime.now()));

      expect((await store.history('a')).single.text, 'in a');
      expect((await store.history('b')).single.text, 'in b');
    });
  });
}
