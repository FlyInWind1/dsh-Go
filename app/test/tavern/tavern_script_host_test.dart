import 'dart:async';
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
      ..deliver = (d) async {
        seen.add(jsonDecode(jsonEncode(d)) as Map<String, Object?>);
        return true;
      };
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

  test("a lifecycle event waits for the page's handlers, and says how they went", () async {
    final pages = TavernScriptPages();
    final put = <Map<String, Object?>>[];
    var ready = true;
    pages.add('ctx', (d) async {
      put.add(d);
      return ready;
    });
    TavernScriptDispatch event(String id) => TavernScriptDispatch(
      kind: TavernScriptDispatchKind.lifecycle,
      eventId: id,
      contextId: 'ctx',
      seq: 1,
      namespace: 'tavern',
      name: 'MESSAGE_RECEIVED',
      args: [3, 'normal'],
    );

    // Held until the page answers; its failure comes back as an issue.
    var answered = false;
    final first = pages.dispatch(event('e1'), _Never())..then((_) => answered = true);
    await Future<void>.delayed(Duration.zero);
    expect(answered, isFalse);
    expect(put.single, containsPair('name', 'MESSAGE_RECEIVED'));
    expect(put.single['args'], [3, 'normal']);
    pages.acknowledge('e1', {
      'status': 'failed',
      'issues': [
        {'code': 'hookFailure', 'message': 'boom'},
      ],
    });
    final ack = await first;
    expect((ack.eventId, ack.status), ('e1', TavernScriptAckStatus.failed));
    expect(
      (ack.issues.single.code, ack.issues.single.message, ack.issues.single.eventId),
      ('hookFailure', 'boom', 'e1'),
    );

    // The engine cancels: answered as cancelled; a late answer changes nothing.
    final cancel = _Cancel();
    final second = pages.dispatch(event('e2'), cancel);
    await Future<void>.delayed(Duration.zero);
    cancel.cancel();
    expect((await second).status, TavernScriptAckStatus.cancelled);
    pages.acknowledge('e2', {'status': 'completed'});

    // The page goes before answering: failed, said why.
    final third = pages.dispatch(event('e3'), _Never());
    await Future<void>.delayed(Duration.zero);
    pages.drop('ctx');
    final lost = await third;
    expect((lost.status, lost.issues.single.code), (TavernScriptAckStatus.failed, 'pageGone'));

    // Not ready yet: no handlers ran, and that is the answer.
    ready = false;
    expect((await pages.dispatch(event('e4'), _Never())).status, TavernScriptAckStatus.completed);
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

class _Cancel implements TavernScriptCancellation {
  final _done = Completer<void>();
  void cancel() => _done.complete();

  @override
  bool get isCancelled => _done.isCompleted;

  @override
  Future<void> get whenCancelled => _done.future;
}

class _Never implements TavernScriptCancellation {
  @override
  bool get isCancelled => false;

  @override
  Future<void> get whenCancelled => Future<void>.delayed(const Duration(days: 1));
}
