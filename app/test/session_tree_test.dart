import 'package:flutter_test/flutter_test.dart';
import 'package:edge_ai/session/session_store.dart';

ChatSession legacySession() => ChatSession.fromJson({
  'version': 1,
  'id': 'legacy',
  'title': 'Hello',
  'createdAt': '2026-01-01T00:00:00.000Z',
  'updatedAt': '2026-01-01T00:00:01.000Z',
  'messages': [
    {'role': 'user', 'text': 'one'},
    {'role': 'assistant', 'text': 'two'},
    {'role': 'user', 'text': 'three'},
    {'role': 'assistant', 'text': 'four'},
  ],
});

void main() {
  test('legacy linear session migrates to a flat tree', () {
    final session = legacySession();
    expect(session.messages, hasLength(4));
    expect(session.messages.every((m) => m.id.isNotEmpty), isTrue);
    expect(session.messages[0].parentId, isNull);
    expect(session.messages[1].parentId, session.messages[0].id);
    expect(session.messages[2].parentId, session.messages[1].id);
    expect(session.messages[3].parentId, session.messages[2].id);
    expect(session.activeLeafId, session.messages.last.id);
    expect(session.activePath.map((m) => m.text), [
      'one',
      'two',
      'three',
      'four',
    ]);
  });

  test('branches share a parent and can be switched', () {
    final session = legacySession();
    final user = session.messages[2];
    final first = session.messages[3];
    final second = StoredMessage(
      id: 'branch-2',
      parentId: user.id,
      role: 'assistant',
      text: 'alternate',
      createdAt: first.createdAt.add(const Duration(seconds: 1)),
    );
    session.messages.add(second);
    session.activeLeafId = second.id;

    expect(session.childrenOf(user.id), hasLength(2));
    expect(session.siblingsOf(first), hasLength(2));
    expect(session.activePath.map((m) => m.text), [
      'one',
      'two',
      'three',
      'alternate',
    ]);
    expect(session.latestLeaf(first.id), first.id);
  });

  test('flat tree round-trips without losing branches', () {
    final session = legacySession();
    final user = session.messages[2];
    final first = session.messages[3];
    final second = StoredMessage(
      id: 'branch-2',
      parentId: user.id,
      role: 'assistant',
      text: 'alternate',
    );
    session.messages.add(second);
    session.activeLeafId = second.id;

    final restored = ChatSession.fromJson(session.toJson());
    expect(restored.messages, hasLength(5));
    expect(restored.activeLeafId, 'branch-2');
    expect(restored.childrenOf(user.id), hasLength(2));
    expect(restored.activePath.last.text, 'alternate');
    expect(restored.messages.firstWhere((m) => m.id == first.id).text, 'four');
  });
}
