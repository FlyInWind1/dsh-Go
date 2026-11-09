// The app's one [Tavern]. Until the engine (packages/dsh_tavern, Pro's T8)
// lands this is the preview stand-in; then it opens the real one on the app's
// support directory and reads the DeepSeek key from settings.

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'tavern_preview.dart';

final tavernProvider = Provider<Tavern>((ref) {
  final tavern = PreviewTavern();
  ref.onDispose(tavern.close);
  return tavern;
});

/// Every character, as the library lists them.
final tavernCharactersProvider = StreamProvider<List<TavernCharacter>>(
  (ref) => ref.watch(tavernProvider).watchCharacters(),
);

/// Chats, newest first; one character's when the argument is its id.
final tavernChatsProvider = StreamProvider.family<List<TavernChatSummary>, String?>(
  (ref, characterId) => ref.watch(tavernProvider).watchChats(characterId: characterId),
);
