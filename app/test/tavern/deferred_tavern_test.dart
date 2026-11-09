import 'dart:async';

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
}
