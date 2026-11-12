import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/tavern/tavern_canvas_calls.dart';
import 'package:dsh_app/tavern/tavern_script_host.dart';
import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory dir;
  late Tavern tavern;
  late String chat;
  late String character;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('script-host');
    tavern = await openTavern(dir.path);
    final card = await File('assets/tavern/sample_innkeeper.json').readAsBytes();
    character = (await tavern.importCard(card, fileName: 'sample_innkeeper.json')).id;
    chat = await tavern.createChat(character);
  });
  tearDown(() async {
    await tavern.close();
    await dir.delete(recursive: true);
  });

  Future<Map<String, Object?>> write(TavernCanvasCalls calls, String scope, Map<String, Object?> value) =>
      calls.handle({
        'id': scope,
        'method': 'replaceVariables',
        'params': {
          'target': {'scope': scope},
          'value': value,
        },
      });

  Map<String, Object?>? variablesIn(List<Map<String, Object?>> deliveries, String scope) {
    for (final d in deliveries.reversed) {
      for (final v in ((d['delta'] as Map?)?['variables'] as List?) ?? const []) {
        if (((v as Map)['target']! as Map)['scope'] == scope) return v['value']! as Map<String, Object?>;
      }
    }
    return null;
  }

  test("the engine's changes reach the page holding the context, in order, as JSON", () async {
    final pages = TavernScriptPages();
    final seen = <Map<String, Object?>>[];
    final page = TavernCanvasCalls(tavern.scripts, chatId: chat, characterId: () => character, pages: pages)
      ..deliver = (d) async => seen.add(jsonDecode(jsonEncode(d)) as Map<String, Object?>);
    final other = TavernCanvasCalls(
      tavern.scripts,
      chatId: chat,
      characterId: () => character,
      instanceId: 'other',
      pages: pages,
    );
    expect(tavern.scripts.capabilities.hostAttached, isFalse);

    // Its own write comes back to it as the engine kept it.
    expect((await write(page, 'chat', {'hp': 7}))['ok'], isTrue);
    expect(tavern.scripts.capabilities.hostAttached, isTrue);
    expect(seen, isNotEmpty);
    expect(seen.every((d) => d['kind'] == 'cache'), isTrue);
    expect(variablesIn(seen, 'chat'), {'hp': 7});

    // Another page's write to what this one sees reaches it too.
    final before = seen.length;
    expect((await write(other, 'global', {'coins': 3}))['ok'], isTrue);
    expect(seen.length, greaterThan(before));
    expect(variablesIn(seen, 'global'), {'coins': 3});
    final seqs = [for (final d in seen) d['seq']! as int];
    expect(seqs, orderedEquals([...seqs]..sort()));

    // Closed: nothing more for it.
    await page.close();
    final after = seen.length;
    expect((await write(other, 'global', {'coins': 4}))['ok'], isTrue);
    expect(seen.length, after);
    await other.close();
  });

  test('what the app does not do for scripts yet is refused, not faked', () async {
    final pages = TavernScriptPages();
    final cancel = _Never();
    await expectLater(
      pages.interact(TavernScriptUiRequest(requestId: 'r', contextId: 'c', executionId: 'e', kind: 'input'), cancel),
      throwsA(isA<TavernScriptException>().having((e) => e.code, 'code', TavernScriptErrorCode.unsupportedCapability)),
    );
    // A delivery for a context no page holds is acknowledged, nothing run.
    final ack = await pages.dispatch(
      TavernScriptDispatch(kind: TavernScriptDispatchKind.lifecycle, eventId: 'ev', contextId: 'nobody', seq: 1),
      cancel,
    );
    expect((ack.eventId, ack.status), ('ev', TavernScriptAckStatus.completed));
    expect(ack.issues, isEmpty);
  });
}

class _Never implements TavernScriptCancellation {
  @override
  bool get isCancelled => false;

  @override
  Future<void> get whenCancelled => Future<void>.delayed(const Duration(days: 1));
}
