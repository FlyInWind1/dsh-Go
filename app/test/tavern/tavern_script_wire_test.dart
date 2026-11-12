import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/tavern/tavern_script_wire.dart';
import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:flutter_test/flutter_test.dart';

/// The card's page side: a request as JSON text, the reply read back from
/// JSON text — what crosses the channel.
Future<Map<String, Object?>> _ask(TavernScriptWire wire, String method, [Map<String, Object?>? params]) async {
  final request = jsonDecode(jsonEncode({'id': method, 'method': method, 'params': ?params}));
  final reply = await wire.handle(request);
  return jsonDecode(jsonEncode(reply)) as Map<String, Object?>;
}

Object? _result(Map<String, Object?> reply) {
  expect(reply['ok'], isTrue, reason: '${reply['error']}');
  return reply['result'];
}

Map<String, Object?> _error(Map<String, Object?> reply) {
  expect(reply['ok'], isFalse);
  return reply['error']! as Map<String, Object?>;
}

void main() {
  late Directory dir;
  late Tavern tavern;
  late TavernScriptWire wire;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('script-wire');
    tavern = await openTavern(dir.path);
    wire = TavernScriptWire(tavern.scripts);
  });
  tearDown(() async {
    await tavern.close();
    await dir.delete(recursive: true);
  });

  test('variables over the channel: replaced, changed by path, read back; null stays a member', () async {
    final caps = _result(await _ask(wire, 'capabilities'))! as Map<String, Object?>;
    expect(caps['simulated'], isFalse);
    expect(caps['methods'], containsAll(['getVariables', 'replaceVariables', 'mutateVariables']));
    expect(caps['scopes'], contains('global'));

    final context = _result(await _ask(wire, 'openContext', {'instanceId': 'frame'}))! as Map<String, Object?>;
    final id = context['id']! as String;
    const global = {'scope': 'global'};

    final first =
        _result(
              await _ask(wire, 'replaceVariables', {
                'contextId': id,
                'target': global,
                'value': {
                  'hp': 7,
                  'bag': ['key'],
                  'note': null,
                },
              }),
            )!
            as Map<String, Object?>;
    expect(first['value'], {
      'hp': 7,
      'bag': ['key'],
      'note': null,
    });
    expect(first['version'], isA<String>()); // opaque, as given
    expect((first['target']! as Map)['scope'], 'global');

    final changed =
        _result(
              await _ask(wire, 'mutateVariables', {
                'contextId': id,
                'target': global,
                'changes': [
                  {
                    'kind': 'set',
                    'path': ['bag', 1],
                    'value': 'map',
                  },
                  {
                    'kind': 'insertIfAbsent',
                    'path': ['hp'],
                    'value': 1,
                  },
                  {
                    'kind': 'remove',
                    'path': ['note'],
                  },
                ],
              }),
            )!
            as Map<String, Object?>;
    expect(changed['results'], [
      {
        'kind': 'set',
        'path': ['bag', 1],
        'existed': false,
        'changed': true,
      },
      {
        'kind': 'insertIfAbsent',
        'path': ['hp'],
        'existed': true,
        'changed': false,
      },
      {
        'kind': 'remove',
        'path': ['note'],
        'existed': true,
        'changed': true,
      },
    ]);
    final read = _result(await _ask(wire, 'getVariables', {'contextId': id, 'target': global}))! as Map;
    expect(read['value'], {
      'hp': 7,
      'bag': ['key', 'map'],
    });

    // The version it was read at is stale now: refused, nothing written.
    final stale = _error(
      await _ask(wire, 'replaceVariables', {
        'contextId': id,
        'target': global,
        'value': {'hp': 0},
        'expectedVersion': first['version'],
      }),
    );
    expect(stale['code'], 'revisionConflict');
    expect(stale['committed'], isFalse);
    expect(((await _ask(wire, 'getVariables', {'contextId': id, 'target': global}))['result']! as Map)['value'], {
      'hp': 7,
      'bag': ['key', 'map'],
    });
  });

  test("a chat's messages over the channel, numbered along the path", () async {
    final card = await File('assets/tavern/sample_innkeeper.json').readAsBytes();
    final character = await tavern.importCard(card, fileName: 'sample_innkeeper.json');
    final chat = await tavern.createChat(character.id);
    final context =
        _result(await _ask(wire, 'openContext', {'instanceId': 'frame', 'chatId': chat}))! as Map<String, Object?>;
    final page =
        _result(await _ask(wire, 'getChatMessages', {'contextId': context['id'], 'range': <String, Object?>{}}))!
            as Map<String, Object?>;
    expect(page['pathRevision'], isA<String>());
    final messages = page['messages']! as List;
    expect(messages, hasLength(page['totalPathLength']));
    final greeting = messages.first as Map<String, Object?>;
    expect(greeting['messageId'], 0);
    expect(greeting['role'], 'assistant');
    expect(greeting['nativeRole'], 'character');
    expect(greeting['ref'], {'chatId': chat, 'nodeId': isA<String>()});
    expect(greeting['message'], isNotEmpty);
    // No data yet: an empty object, not null.
    expect(greeting['hasData'], isFalse);
    expect(greeting['data'], <String, Object?>{});
    expect(greeting.containsKey('speakerCharacterId'), isTrue);
  });

  test('a snapshot: the path and every variable the context sees, as of its lastSeq', () async {
    final card = await File('assets/tavern/sample_innkeeper.json').readAsBytes();
    final character = await tavern.importCard(card, fileName: 'sample_innkeeper.json');
    final chat = await tavern.createChat(character.id);
    final context =
        _result(await _ask(wire, 'openContext', {'instanceId': 'frame', 'chatId': chat, 'characterId': character.id}))!
            as Map<String, Object?>;
    _result(
      await _ask(wire, 'replaceVariables', {
        'contextId': context['id'],
        'target': {'scope': 'chat'},
        'value': {'met': true},
      }),
    );
    final snapshot = _result(await _ask(wire, 'snapshot', {'contextId': context['id']}))! as Map<String, Object?>;
    expect(snapshot['lastSeq'], isA<int>());
    expect(snapshot['pathRevision'], isA<String>());
    expect((snapshot['context']! as Map)['id'], context['id']);
    expect(snapshot['messages'], isNotEmpty);
    final variables = {
      for (final v in (snapshot['variables']! as List).cast<Map<String, Object?>>()) (v['target']! as Map)['scope']: v,
    };
    expect(variables.keys, containsAll(['global', 'character', 'chat', 'message']));
    expect(variables['chat']!['value'], {'met': true});
    expect(variables['chat']!['version'], isA<String>());
    // The latest message's own variables, named by its stable ref.
    final latest = (snapshot['messages']! as List).last as Map;
    expect((variables['message']!['target']! as Map)['messageRef'], latest['ref']);
  });

  test('messages written over the channel: created, changed, hidden, moved, deleted', () async {
    final card = await File('assets/tavern/sample_innkeeper.json').readAsBytes();
    final character = await tavern.importCard(card, fileName: 'sample_innkeeper.json');
    final chat = await tavern.createChat(character.id);
    final id =
        (_result(await _ask(wire, 'openContext', {'instanceId': 'frame', 'chatId': chat}))! as Map)['id']! as String;
    Future<List<String>> texts() async {
      final page = _result(await _ask(wire, 'getChatMessages', {'contextId': id})) as Map;
      return [for (final m in page['messages'] as List) (m as Map)['message'] as String];
    }

    final greeting = (await texts()).single;
    final made =
        _result(
              await _ask(wire, 'createChatMessages', {
                'contextId': id,
                'messages': [
                  {'role': 'user', 'message': '一'},
                  {
                    'role': 'assistant',
                    'message': '二',
                    'data': {'hp': 1},
                  },
                ],
              }),
            )!
            as Map;
    expect(made['pathRevision'], isA<String>());
    expect(made['upsertMessages'], hasLength(2));
    expect(await texts(), [greeting, '一', '二']);
    _result(
      await _ask(wire, 'createChatMessages', {
        'contextId': id,
        'messages': [
          {'role': 'system', 'message': '零'},
        ],
        'insertBefore': 1,
      }),
    );
    expect(await texts(), [greeting, '零', '一', '二']);

    // Changed and hidden by floor; the engine's own field names.
    _result(
      await _ask(wire, 'setChatMessages', {
        'contextId': id,
        'patches': [
          {
            'messageId': 2,
            'fields': {'message': '一改'},
          },
          {
            'messageId': -1,
            'fields': {'hidden': true},
          },
        ],
        'options': {'refresh': 'none'},
      }),
    );
    final page = _result(await _ask(wire, 'getChatMessages', {'contextId': id})) as Map;
    final rows = [for (final m in page['messages'] as List) m as Map];
    expect([for (final m in rows) m['message']], [greeting, '零', '一改', '二']);
    expect(rows.last['hidden'], isTrue);
    expect(rows.last['data'], {'hp': 1});

    // [1,3) and [3,4) swap places; then floors 1 and 2 go.
    _result(await _ask(wire, 'rotateChatMessages', {'contextId': id, 'begin': 1, 'middle': 3, 'end': 4}));
    expect(await texts(), [greeting, '二', '零', '一改']);
    _result(
      await _ask(wire, 'deleteChatMessages', {
        'contextId': id,
        'messageIds': [1, 2],
      }),
    );
    expect(await texts(), [greeting, '一改']);

    // Refused, and named: data given as null; a field the engine does not know.
    final nullData = _error(
      await _ask(wire, 'createChatMessages', {
        'contextId': id,
        'messages': [
          {'role': 'user', 'message': 'x', 'data': null},
        ],
      }),
    );
    expect((nullData['code'], nullData['fieldPath']), ('invalidArgument', 'messages[0].data'));
    final unknown = _error(
      await _ask(wire, 'setChatMessages', {
        'contextId': id,
        'patches': [
          {
            'messageId': 1,
            'fields': {'is_hidden': true},
          },
        ],
      }),
    );
    expect(unknown['code'], 'invalidArgument');
    expect(unknown['fieldPath'], '/is_hidden');
    final badRefresh = _error(
      await _ask(wire, 'deleteChatMessages', {
        'contextId': id,
        'messageIds': [1],
        'options': {'refresh': 'sometimes'},
      }),
    );
    expect(badRefresh['fieldPath'], 'options.refresh');
    expect(await texts(), [greeting, '一改']);
  });

  test('a wrong request is told why, as an error, not a broken channel', () async {
    final id =
        (_result(await _ask(wire, 'openContext', {'instanceId': 'frame'}))! as Map<String, Object?>)['id']! as String;
    Future<Map<String, Object?>> refused(String method, [Map<String, Object?>? params]) async =>
        _error(await _ask(wire, method, params));

    expect((await refused('runScript'))['code'], 'unsupportedCapability');
    expect((await refused('getVariables', {'contextId': id}))['fieldPath'], 'target');
    expect(
      (await refused('getVariables', {
        'contextId': id,
        'target': {'scope': 'everywhere'},
      }))['fieldPath'],
      'target.scope',
    );
    final notObject = await refused('replaceVariables', {
      'contextId': id,
      'target': {'scope': 'global'},
      'value': [1],
    });
    expect((notObject['code'], notObject['fieldPath']), ('invalidArgument', 'value'));
    // A version is the string it was handed out as, never a number.
    final numeric = await refused('replaceVariables', {
      'contextId': id,
      'target': {'scope': 'global'},
      'value': <String, Object?>{},
      'expectedVersion': 3,
    });
    expect(numeric['fieldPath'], 'expectedVersion');
    expect(
      (await refused('mutateVariables', {
        'contextId': id,
        'target': {'scope': 'global'},
        'changes': [
          {
            'kind': 'set',
            'path': [-1],
            'value': 1,
          },
        ],
      }))['fieldPath'],
      'changes[0].path',
    );
    // The engine's own refusals come through with their code.
    expect(
      (await refused('getVariables', {
        'contextId': 'nobody',
        'target': {'scope': 'global'},
      }))['code'],
      isIn(['noContext', 'closedContext']),
    );
    // Not even an object: still an answer.
    final reply = await wire.handle('hello');
    expect(reply['ok'], isFalse);
    expect(jsonEncode(reply), isA<String>());
  });
}
