// The app's one [Tavern]. Until the engine (packages/dsh_tavern, Pro's T8)
// lands this is the preview stand-in; then it opens the real one on the app's
// support directory. Either way it follows 酒馆设置 and reads the app's
// DeepSeek key on every call.

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/settings_state.dart';
import 'tavern_preview.dart';
import 'tavern_settings.dart';

final tavernProvider = Provider<Tavern>((ref) {
  final tavern = PreviewTavern();
  ref.onDispose(tavern.close);
  void configure(TavernSettings settings) => tavern.configure(
    TavernModelConfig(
      apiKey: () async => ref.read(settingsProvider).apiKey.trim().isEmpty ? null : ref.read(settingsProvider).apiKey,
      model: settings.model,
      thinking: settings.thinking,
    ),
  );
  configure(ref.read(tavernSettingsProvider));
  ref.listen(tavernSettingsProvider, (_, next) => configure(next));
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
