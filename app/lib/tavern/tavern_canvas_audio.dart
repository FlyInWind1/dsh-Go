// A chat's two card players on the canvas (酒馆助手's 播放音频 pages, 'bgm'
// and 'ambient'): the lists and settings its scripts set, kept on this phone
// per chat. The page plays; what is playing goes with the page.

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

const tavernAudioChannels = ['bgm', 'ambient'];
const tavernAudioModes = {'repeat_one', 'repeat_all', 'shuffle', 'play_one_and_stop'};

/// [json] as it is kept: for each channel its list ({title, url}, every one
/// with a url) and the settings it names that are right (enabled, mode,
/// muted, volume 0–100). What is missing or wrong is left out.
Map<String, Object?> tavernAudioState(Object? json) {
  if (json is! Map) return const {};
  return {
    for (final type in tavernAudioChannels)
      if (json[type] case final Map<Object?, Object?> channel)
        type: {
          'list': [
            if (channel['list'] case final List<Object?> items)
              for (final item in items)
                if (item case {'url': final String url} when url.isNotEmpty)
                  {'title': item['title'] is String ? item['title'] : '', 'url': url},
          ],
          'settings': {
            if (channel['settings'] case final Map<Object?, Object?> s) ...{
              if (s['enabled'] case final bool enabled) 'enabled': enabled,
              if (s['mode'] case final String mode when tavernAudioModes.contains(mode)) 'mode': mode,
              if (s['muted'] case final bool muted) 'muted': muted,
              if (s['volume'] case final num volume when volume.isFinite) 'volume': volume.clamp(0, 100),
            },
          },
        },
  };
}

String _key(String chatId) => 'tavern.audio.$chatId';

/// What [chatId]'s players were left at; nothing when never set, or unreadable.
Future<Map<String, Object?>> tavernLoadAudio(String chatId) async {
  try {
    final raw = (await SharedPreferences.getInstance()).getString(_key(chatId));
    return raw == null ? const {} : tavernAudioState(jsonDecode(raw));
  } on Object {
    return const {};
  }
}

/// Keeps what [chatId]'s page says its players are now.
Future<void> tavernSaveAudio(String chatId, Object? state) async {
  await (await SharedPreferences.getInstance()).setString(_key(chatId), jsonEncode(tavernAudioState(state)));
}
