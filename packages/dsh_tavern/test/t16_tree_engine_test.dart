import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:test/test.dart';

void main() {
  test('tree includes inactive descendants and all current ancestors beyond sixty nodes', () async {
    final h = await _open();
    final character = await h.engine.importCard(_card());
    final chat = await h.engine.createChat(character.id);
    for (var i = 0; i < 35; i++) {
      _done(await h.engine.send(chat, 'Q$i').toList());
    }
    final original = (await h.engine.path(chat)).last;
    final alternate = _done(await h.engine.regenerate(chat, original.nodeId).toList());
    _done(await h.engine.send(chat, 'alternate continuation').toList());
    await h.engine.selectSibling(chat, original.nodeId, 0);
    final Tavern facade = h.engine;
    final before = await h.engine.path(chat, limit: 1000);
    final inspection = (await facade.inspectTurn(chat))!.toJson();
    final calls = h.model.bodies.length;
    final nodes = await facade.tree(chat);
    expect(nodes, hasLength(74));
    expect(before, hasLength(71));
    expect(nodes.where((node) => node.isCurrentPath).map((node) => node.nodeId), before.map((node) => node.nodeId));
    expect(nodes.where((node) => !node.isCurrentPath), hasLength(3));
    final ids = nodes.map((node) => node.nodeId).toSet();
    expect(nodes.every((node) => node.parentId == null || ids.contains(node.parentId)), isTrue);
    final selected = nodes.singleWhere((node) => node.nodeId == original.nodeId);
    final other = nodes.singleWhere((node) => node.nodeId == alternate.nodeId);
    expect((selected.siblingIndex, other.siblingIndex), (0, 1));
    expect((selected.siblingCount, other.siblingCount), (2, 2));
    expect((await h.engine.path(chat, limit: 1000)).map((node) => node.nodeId), before.map((node) => node.nodeId));
    expect((await facade.inspectTurn(chat))!.toJson(), inspection);
    expect(h.model.bodies, hasLength(calls));
  });

  test('previews keep sixty-four Unicode code points and exact role speaker time and visibility', () async {
    final h = await _open();
    final text = '${List.filled(40, '😀汉').join()}\nTAIL';
    final character = await h.engine.importCard(_card({'first_mes': text}));
    final chat = await h.engine.createChat(character.id);
    final message = (await h.engine.path(chat)).single;
    await h.engine.setHidden(chat, message.nodeId, true);
    final node = (await h.engine.tree(chat)).single;
    expect(node.nodeId, message.nodeId);
    expect(node.parentId, isNull);
    expect(node.preview, String.fromCharCodes(text.runes.take(64)));
    expect(node.preview.runes.length, 64);
    expect(node.preview, isNot(contains('\uFFFD')));
    expect(node.role, TavernRole.character);
    expect(node.speaker, message.speaker);
    expect(node.at, message.at);
    expect(node.isCurrentPath, isTrue);
    expect(node.hidden, isTrue);
    expect((await h.engine.path(chat)).single.text, text);
  });
  test('labels stay on independent siblings and clearing only removes their names', () async {
    final h = await _open();
    final character = await h.engine.importCard(_card());
    final chat = await h.engine.createChat(character.id);
    final first = (await h.engine.path(chat)).single;
    final second = _done(await h.engine.regenerate(chat, first.nodeId).toList());
    final selection = (await h.engine.path(chat)).map((node) => node.nodeId).toList();
    final Tavern facade = h.engine;
    final notification = facade.pathChanges(chat).first;
    await facade.nameBranch(chat, first.nodeId, '  雨夜 🌧  ');
    await notification.timeout(const Duration(seconds: 5));
    await facade.nameBranch(chat, second.nodeId, '晴天');
    var nodes = await facade.tree(chat);
    expect(nodes.singleWhere((node) => node.nodeId == first.nodeId).branchName, '雨夜 🌧');
    expect(nodes.singleWhere((node) => node.nodeId == second.nodeId).branchName, '晴天');
    expect((await facade.path(chat)).map((node) => node.nodeId), selection);
    expect(h.engine.variables(chat), isEmpty);
    await facade.nameBranch(chat, first.nodeId, ' \n\t ');
    await facade.nameBranch(chat, second.nodeId, null);
    nodes = await facade.tree(chat);
    expect(nodes.every((node) => node.branchName == null), isTrue);
    expect(nodes.map((node) => node.preview), [first.text, second.text]);
  });

  test('names preserve unknown extras through reopen and selected and alternate JSONL rows', () async {
    final h = await _open();
    final character = await h.engine.importCard(_card());
    final chat = await h.importChat(
      character.id,
      [
        {
          'name': 'Guide',
          'is_user': false,
          'is_system': false,
          'send_date': _at.toIso8601String(),
          'mes': 'FIRST',
          'extra': {
            'foreign': ['keep'],
            'dshgo': {
              'other': {'kept': true},
            },
          },
        },
      ],
      variables: {'n': 7},
    );
    final first = (await h.engine.path(chat)).single;
    final second = _done(await h.engine.regenerate(chat, first.nodeId).toList());
    await h.engine.nameBranch(chat, first.nodeId, 'FIRST LABEL');
    await h.engine.nameBranch(chat, second.nodeId, 'SECOND LABEL');
    final values = h.engine.variables(chat);
    await h.reopen();
    expect((await h.engine.tree(chat)).map((node) => node.branchName), ['FIRST LABEL', 'SECOND LABEL']);
    final documents = await h.engine.exportChat(chat);
    final imported = await h.engine.importChats(character.id, documents);
    final after = await h.engine.tree(imported.chatIds.single);
    expect(after.map((node) => node.branchName).toSet(), {'FIRST LABEL', 'SECOND LABEL'});
    expect(after.singleWhere((node) => node.isCurrentPath).branchName, 'SECOND LABEL');
    final decoded = StChatDocument.decode(documents.first.fileName, documents.first.bytes);
    final row = decoded.messages.single;
    final swipeExtras = (row['swipe_info']! as List<Object?>).map((value) => _map(_map(value)['extra']));
    final original = swipeExtras.singleWhere((extra) => _map(extra['dshgo'])['branchName'] == 'FIRST LABEL');
    expect(original['foreign'], ['keep']);
    expect(_map(original['dshgo'])['other'], {'kept': true});
    expect(h.engine.variables(chat), values);
  });
  test('unknown and foreign nodes fail without relabeling either chat', () async {
    final h = await _open();
    final character = await h.engine.importCard(_card());
    final a = await h.engine.createChat(character.id);
    final b = await h.engine.createChat(character.id);
    final node = (await h.engine.path(a)).single.nodeId;
    await h.engine.nameBranch(a, node, 'UNCHANGED');
    await expectLater(h.engine.tree('missing'), throwsStateError);
    await expectLater(h.engine.nameBranch(b, node, 'WRONG CHAT'), throwsStateError);
    await expectLater(h.engine.nameBranch(a, 'missing', 'MISSING'), throwsStateError);
    expect((await h.engine.tree(a)).single.branchName, 'UNCHANGED');
    expect((await h.engine.tree(b)).single.branchName, isNull);
    expect(h.model.bodies, isEmpty);
  });

  test('tree reads preserve generation and naming waits for the partial cancellation commit', () async {
    final h = await _open();
    final character = await h.engine.importCard(_card());
    final chat = await h.engine.createChat(character.id);
    final held = h.model.hold();
    final events = <TavernEvent>[];
    final textSeen = Completer<void>();
    final ended = Completer<void>();
    final subscription = h.engine
        .send(chat, 'Q')
        .listen(
          (event) {
            events.add(event);
            if (event is TavernTextDelta && !textSeen.isCompleted) textSeen.complete();
          },
          onError: ended.completeError,
          onDone: ended.complete,
        );
    addTearDown(subscription.cancel);
    await held.listening.future;
    held.source.add(const ModelText('PARTIAL'));
    await textSeen.future;
    final target = events.whereType<TavernTurnStarted>().single.message.nodeId;
    expect((await h.engine.tree(chat)).any((node) => node.nodeId == target), isTrue);
    expect(h.model.cancellations.single.isCancelled, isFalse);
    await h.engine.nameBranch(chat, target, 'KEEP THIS');
    await ended.future;
    expect(h.model.cancellations.single.isCancelled, isTrue);
    final failed = events.whereType<TavernTurnFailed>().single;
    expect(failed.kind, TavernFailure.cancelled);
    expect(failed.partial!.nodeId, target);
    expect(failed.partial!.text, 'PARTIAL');
    expect((await h.engine.tree(chat)).singleWhere((node) => node.nodeId == target).branchName, 'KEEP THIS');
    final inspection = await h.engine.inspectTurn(chat, nodeId: target);
    expect(inspection, isNotNull);
    await h.reopen();
    expect((await h.engine.inspectTurn(chat, nodeId: target))!.toJson(), inspection!.toJson());
    expect((await h.engine.tree(chat)).last.branchName, 'KEEP THIS');
  }, timeout: const Timeout(Duration(seconds: 15)));
  test('an empty chat exposes no nodes and deleted labels cannot be restored by naming', () async {
    final h = await _open();
    final character = await h.engine.importCard(_card());
    final chat = await h.engine.createChat(character.id);
    final root = (await h.engine.path(chat)).single.nodeId;
    await h.engine.nameBranch(chat, root, 'REMOVED');
    await h.engine.deleteFrom(chat, root);
    expect(await h.engine.tree(chat), isEmpty);
    await expectLater(h.engine.nameBranch(chat, root, 'RESTORE'), throwsStateError);
    await h.reopen();
    expect(await h.engine.tree(chat), isEmpty);
  });

  test('root alternatives and remembered descendants are marked from the selected leaf', () async {
    final h = await _open();
    final character = await h.engine.importCard(_card());
    final chat = await h.engine.createChat(character.id);
    final first = (await h.engine.path(chat)).single;
    final leaf = _done(await h.engine.send(chat, 'FIRST PATH').toList());
    final second = _done(await h.engine.regenerate(chat, first.nodeId).toList());
    await h.engine.nameBranch(chat, first.nodeId, 'OLD ROOT');
    await h.engine.nameBranch(chat, second.nodeId, 'NEW ROOT');
    var nodes = await h.engine.tree(chat);
    expect(nodes.where((node) => node.isCurrentPath).map((node) => node.nodeId), [second.nodeId]);
    expect(nodes.where((node) => node.parentId == null).map((node) => node.siblingIndex), [0, 1]);
    await h.engine.selectSibling(chat, second.nodeId, 0);
    nodes = await h.engine.tree(chat);
    expect(nodes.where((node) => node.isCurrentPath), hasLength(3));
    expect((await h.engine.path(chat)).last.nodeId, leaf.nodeId);
    expect(nodes.singleWhere((node) => node.nodeId == second.nodeId).isCurrentPath, isFalse);
  });
  test('tree hides soft-deleted siblings and undo restores labels hidden flags and sibling numbers', () async {
    final h = await _open();
    final character = await h.engine.importCard(_card());
    final chat = await h.engine.createChat(character.id);
    final first = (await h.engine.path(chat)).single;
    final second = _done(await h.engine.regenerate(chat, first.nodeId).toList());
    await h.engine.nameBranch(chat, second.nodeId, 'SAVED LABEL');
    await h.engine.setHidden(chat, second.nodeId, true);
    final token = await h.engine.deleteFrom(chat, second.nodeId);
    final visible = (await h.engine.tree(chat)).single;
    expect(visible.nodeId, first.nodeId);
    expect((visible.siblingIndex, visible.siblingCount, visible.isCurrentPath), (0, 1, true));
    await expectLater(h.engine.nameBranch(chat, second.nodeId, 'BLOCKED'), throwsStateError);
    expect(await h.engine.undoDeleteFrom(chat, token), isTrue);
    final restored = (await h.engine.tree(chat)).last;
    expect(restored.nodeId, second.nodeId);
    expect(restored.branchName, 'SAVED LABEL');
    expect(restored.hidden, isTrue);
    expect((restored.siblingIndex, restored.siblingCount, restored.isCurrentPath), (1, 2, true));
  });

  test('same branch name preserves undo selection while an actual rename advances tree revision', () async {
    final h = await _open();
    final character = await h.engine.importCard(_card());
    final chat = await h.engine.createChat(character.id);
    final first = (await h.engine.path(chat)).single;
    await h.engine.nameBranch(chat, first.nodeId, 'A');
    final second = _done(await h.engine.regenerate(chat, first.nodeId).toList());
    final firstToken = await h.engine.deleteFrom(chat, second.nodeId);
    expect((await h.engine.path(chat)).single.nodeId, first.nodeId);
    await h.engine.nameBranch(chat, first.nodeId, '  A  ');
    expect(await h.engine.undoDeleteFrom(chat, firstToken), isTrue);
    expect((await h.engine.path(chat)).single.nodeId, second.nodeId);
    final secondToken = await h.engine.deleteFrom(chat, second.nodeId);
    await h.engine.nameBranch(chat, first.nodeId, 'B');
    expect(await h.engine.undoDeleteFrom(chat, secondToken), isTrue);
    expect((await h.engine.path(chat)).single.nodeId, first.nodeId);
    expect((await h.engine.tree(chat)).first.branchName, 'B');
    expect((await h.engine.tree(chat)).singleWhere((node) => node.isCurrentPath).nodeId, first.nodeId);
  });
}

final _at = DateTime.utc(2026, 11, 10, 12);

Future<_Harness> _open({double Function()? random}) async {
  final directory = await Directory.systemTemp.createTemp('dsh-t16-tree-');
  final model = _Model();
  final config = TavernModelConfig(apiKey: () async => 'fixture-only', model: 'fixture');
  final draw = random ?? () => 0.25;
  final engine = await TavernEngine.openDirectory(
    directory,
    config: config,
    modelClient: model,
    clock: () => _at,
    random: draw,
  );
  final h = _Harness(directory, config, model, engine, draw);
  addTearDown(h.dispose);
  return h;
}

class _Harness {
  _Harness(this.directory, this.config, this.model, this.engine, this.random);
  final Directory directory;
  final TavernModelConfig config;
  final _Model model;
  TavernEngine engine;
  final double Function() random;

  Future<String> importChat(
    String characterId,
    List<Map<String, Object?>> rows, {
    Map<String, Object?> variables = const {},
  }) async {
    final document = StChatDocument(
      fileName: 'main.jsonl',
      header: {
        'user_name': 'User',
        'character_name': 'Guide',
        'chat_metadata': {'variables': variables},
      },
      messages: rows,
    );
    return (await engine.importChats(characterId, [
      TavernChatFile(fileName: document.fileName, bytes: document.encode()),
    ])).chatIds.single;
  }

  Future<void> reopen() async {
    await engine.close();
    engine = await TavernEngine.openDirectory(
      directory,
      config: config,
      modelClient: model,
      clock: () => _at,
      random: random,
    );
  }

  Future<void> dispose() async {
    await engine.close();
    for (final value in model.held) {
      if (!value.source.isClosed) {
        unawaited(value.source.close());
      }
    }
    await directory.delete(recursive: true);
  }
}

class _Held {
  _Held() {
    source = StreamController<ModelDelta>(sync: true, onListen: listening.complete);
  }
  final listening = Completer<void>();
  late final StreamController<ModelDelta> source;
}

class _Model extends TavernModelClient {
  final bodies = <Map<String, Object?>>[];
  final cancellations = <ModelCancellation>[];
  final held = <_Held>[];
  _Held? next;

  _Held hold() {
    final value = _Held();
    held.add(value);
    next = value;
    return value;
  }

  @override
  Stream<ModelDelta> generate({
    required TavernModelConfig config,
    required Map<String, Object?> body,
    required ModelCancellation cancellation,
  }) {
    bodies.add(_map(body));
    cancellations.add(cancellation);
    final waiting = next;
    next = null;
    return waiting?.source.stream ?? Stream.fromIterable(const [ModelText('OK'), ModelFinished('stop')]);
  }
}

Map<String, Object?> _map(Object? value) =>
    value is Map<String, Object?> ? jsonDecode(jsonEncode(value)) as Map<String, Object?> : {};

TavernMessage _done(List<TavernEvent> events) {
  expect(events.whereType<TavernTurnFailed>(), isEmpty);
  return events.whereType<TavernTurnDone>().single.message;
}

Uint8List _card([Map<String, Object?> fields = const {}]) => Uint8List.fromList(
  utf8.encode(
    jsonEncode({
      'spec': 'chara_card_v3',
      'spec_version': '3.0',
      'data': {
        'name': 'Guide',
        'description': '',
        'personality': '',
        'scenario': '',
        'first_mes': 'G',
        'mes_example': '',
        'creator_notes': '',
        'system_prompt': '',
        'post_history_instructions': '',
        'alternate_greetings': <String>[],
        'tags': <String>[],
        'creator': '',
        'character_version': '',
        'extensions': <String, Object?>{},
        ...fields,
      },
    }),
  ),
);
