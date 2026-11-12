import 'dart:async';
import 'dart:io';

import 'package:dsh_app/tavern/deferred_tavern.dart';
import 'package:dsh_app/tavern/tavern_preview.dart';
import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('calls and streams wait for the tavern to open; configure reaches it then', () async {
    final opening = Completer<Tavern>();
    final deferred = DeferredTavern(opening.future)
      ..configure(TavernModelConfig(apiKey: () async => 'k', thinking: true));

    final characters = deferred.watchCharacters().first;
    final chat = deferred.createChat('sample-innkeeper');
    deferred.stop('nothing yet'); // no turn can run before it opens

    final preview = PreviewTavern(tick: const Duration(milliseconds: 1));
    opening.complete(preview);

    expect((await characters).map((c) => c.name), containsAll(['林晚', '星图']));
    final events = await deferred.send(await chat, '你好').toList();
    // The thinking set before it opened applies: the reply thinks first.
    expect(events.whereType<TavernReasoningDelta>(), isNotEmpty);
    expect(events.last, isA<TavernTurnDone>());
  });

  test('card scripts: one bridge; before it opens it claims nothing; the host set early reaches it', () async {
    final opening = Completer<Tavern>();
    final deferred = DeferredTavern(opening.future);
    final bridge = deferred.scripts;
    expect(identical(bridge, deferred.scripts), isTrue);
    expect(bridge.capabilities.methods, isEmpty);
    expect(bridge.capabilities.simulated, isFalse);
    bridge.attachHost(_Host());
    expect(bridge.capabilities.hostAttached, isTrue);
    final refused = bridge.getVariables('c', const TavernVariableTarget(scope: TavernVariableScope.global));

    final preview = PreviewTavern(tick: Duration.zero);
    opening.complete(preview);
    await expectLater(
      refused,
      throwsA(isA<TavernScriptException>().having((e) => e.code, 'code', TavernScriptErrorCode.unsupportedCapability)),
    );
    // Open: what the preview says, with the host handed over.
    expect(bridge.capabilities.simulated, isTrue);
    expect(bridge.capabilities.hostAttached, isTrue);
    expect(preview.scripts.capabilities.hostAttached, isTrue);
    bridge.attachHost(null);
    expect(preview.scripts.capabilities.hostAttached, isFalse);
  });

  test('card scripts reach the real engine: a global variable written, read back, and kept', () async {
    final dir = await Directory.systemTemp.createTemp('deferred-scripts');
    addTearDown(() => dir.delete(recursive: true));
    const global = TavernVariableTarget(scope: TavernVariableScope.global);
    final opening = Completer<Tavern>();
    final deferred = DeferredTavern(opening.future);
    final context = deferred.scripts.openContext(const TavernScriptContextSpec(instanceId: 'frame'));
    opening.complete(await openTavern(dir.path));

    final id = (await context).id;
    final value = <String, Object?>{
      'hp': 7,
      'bag': ['key'],
    };
    final saved = await deferred.scripts.replaceVariables(id, global, value);
    // The engine took it as it was at the call.
    (value['bag']! as List).add('map');
    expect(saved.value, {
      'hp': 7,
      'bag': ['key'],
    });
    expect(deferred.scripts.capabilities.simulated, isFalse);
    expect(deferred.scripts.capabilities.methods, contains('replaceVariables'));
    await deferred.close();

    // Opened again: still there.
    final again = DeferredTavern(openTavern(dir.path));
    addTearDown(again.close);
    final reopened = await again.scripts.openContext(const TavernScriptContextSpec(instanceId: 'frame'));
    expect((await again.scripts.getVariables(reopened.id, global)).value, {
      'hp': 7,
      'bag': ['key'],
    });
  });

  test('B2 reaches the real engine too: a prompt injected for a chat is listed, then taken out', () async {
    final dir = await Directory.systemTemp.createTemp('deferred-b2');
    addTearDown(() => dir.delete(recursive: true));
    final opening = Completer<Tavern>();
    final deferred = DeferredTavern(opening.future);
    addTearDown(deferred.close);
    // Nothing can be generating before it opens.
    expect(deferred.scripts.stopGenerationById('nothing'), isFalse);
    opening.complete(await openTavern(dir.path));
    final card = await File('assets/tavern/sample_innkeeper.json').readAsBytes();
    final character = await deferred.importCard(card, fileName: 'sample_innkeeper.json');
    final chat = await deferred.createChat(character.id);
    final context = await deferred.scripts.openContext(TavernScriptContextSpec(instanceId: 'frame', chatId: chat));

    await deferred.scripts.injectPrompts(context.id, [TavernScriptInjection(id: 'weather', content: '外面在下雨。')]);
    final listed = await deferred.scripts.listInjections(context.id);
    expect(listed.map((v) => v.injection?.content), contains('外面在下雨。'));
    await deferred.scripts.uninjectPrompts(context.id, ['weather']);
    expect(
      (await deferred.scripts.listInjections(context.id)).map((v) => v.injection?.content),
      isNot(contains('外面在下雨。')),
    );
    expect(deferred.scripts.stopGenerationById('nothing'), isFalse);
  });

  test('the preview says it does not simulate B2 either', () async {
    final preview = PreviewTavern(tick: Duration.zero);
    await expectLater(
      preview.scripts.listInjections('c'),
      throwsA(isA<TavernScriptException>().having((e) => e.code, 'code', TavernScriptErrorCode.unsupportedCapability)),
    );
    expect(preview.scripts.stopGenerationById('g'), isFalse);
  });

  test('card scripts before it opens: a value is copied at the call; a cycle is refused there', () async {
    final opening = Completer<Tavern>();
    final deferred = DeferredTavern(opening.future);
    const global = TavernVariableTarget(scope: TavernVariableScope.global);
    final loop = <String, Object?>{};
    loop['self'] = loop;
    await expectLater(
      deferred.scripts.replaceVariables('c', global, loop),
      throwsA(isA<TavernScriptException>().having((e) => e.code, 'code', TavernScriptErrorCode.invalidJson)),
    );
    // A plain value waits, copied: the preview then refuses it as unsimulated.
    final value = <String, Object?>{'hp': 7};
    final waiting = deferred.scripts.replaceVariables('c', global, value);
    value['hp'] = 0;
    opening.complete(PreviewTavern(tick: Duration.zero));
    await expectLater(waiting, throwsA(isA<TavernScriptException>()));
  });

  test('the libraries and the display pass reach the engine once it opens (T20, T21)', () async {
    final preview = PreviewTavern(tick: Duration.zero);
    final chat = await preview.createChat('sample-innkeeper');
    final deferred = DeferredTavern(Future.value(preview));

    expect(await deferred.listPresets(), isEmpty);
    expect(await deferred.watchPresets().first, isEmpty);
    expect((await deferred.presetSelection(chatId: chat)).source, PresetSelectionSource.stDefault);
    expect(await deferred.listRegexScripts(), isEmpty);
    expect(await deferred.listLorebooks(), isEmpty);
    expect((await deferred.displayText(chat, text: '*她笑了*')).text, '*她笑了*');
    // Presets and lorebooks go through to the preview's own.
    final imported = await deferred.importPreset('{"temperature": 1}', fileName: 'a.json');
    expect((await deferred.listPresets()).single.id, imported.preset.id);
    final book = await deferred.importLorebook('{"entries": {"0": {"content": "x"}}}', fileName: 'w.json');
    expect((await deferred.listLorebooks()).single.id, book.book.id);
  });
}

/// A host that never answers: only its presence is looked at.
class _Host implements TavernScriptHost {
  @override
  Object? noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
