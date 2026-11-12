import 'dart:io';

import 'package:dsh_app/tavern/tavern_canvas_calls.dart';
import 'package:dsh_app/tavern/tavern_preview.dart';
import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test("a page's calls run in its chat's own context, opened once, and closed with it", () async {
    final dir = await Directory.systemTemp.createTemp('canvas-calls');
    final tavern = await openTavern(dir.path);
    addTearDown(() async {
      await tavern.close();
      await dir.delete(recursive: true);
    });
    final card = await File('assets/tavern/sample_innkeeper.json').readAsBytes();
    final character = await tavern.importCard(card, fileName: 'sample_innkeeper.json');
    final chat = await tavern.createChat(character.id);
    final calls = TavernCanvasCalls(tavern.scripts, chatId: chat, characterId: () => character.id);

    // No context named: this chat's own is used.
    final saved = await calls.handle({
      'id': 1,
      'method': 'replaceVariables',
      'params': {
        'target': {'scope': 'chat'},
        'value': {'met': true},
      },
    });
    expect(saved['ok'], isTrue, reason: '${saved['error']}');
    final target = (saved['result']! as Map)['target']! as Map;
    expect(target['chatId'], chat);
    final read = await calls.handle({
      'id': 2,
      'method': 'getVariables',
      'params': {
        'target': {'scope': 'chat'},
      },
    });
    expect((read['result']! as Map)['value'], {'met': true});
    final messages = await calls.handle({'id': 3, 'method': 'getChatMessages', 'params': <String, Object?>{}});
    expect(((messages['result']! as Map)['messages']! as List).first, containsPair('role', 'assistant'));
    // Asking what is there needs no context.
    expect((await calls.handle({'id': 4, 'method': 'capabilities'}))['ok'], isTrue);

    // Closed with the page; a later call opens a new one and still works.
    await calls.close();
    final again = await calls.handle({
      'id': 5,
      'method': 'getVariables',
      'params': {
        'target': {'scope': 'chat'},
      },
    });
    expect((again['result']! as Map)['value'], {'met': true});
    await calls.close();
  });

  test('no context to be had (the preview): told so; asked again, it tries again', () async {
    final preview = PreviewTavern(tick: Duration.zero);
    final chat = await preview.createChat('sample-innkeeper');
    final calls = TavernCanvasCalls(preview.scripts, chatId: chat, characterId: () => 'sample-innkeeper');
    for (final id in [1, 2]) {
      final reply = await calls.handle({
        'id': id,
        'method': 'getVariables',
        'params': {
          'target': {'scope': 'chat'},
        },
      });
      expect(reply['id'], id);
      expect((reply['error']! as Map)['code'], 'unsupportedCapability');
    }
    await calls.close();
  });
}
