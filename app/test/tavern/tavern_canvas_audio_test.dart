import 'package:dsh_app/tavern/tavern_canvas_audio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test("a chat's players are kept as their lists and right settings, nothing else", () {
    expect(
      tavernAudioState({
        'bgm': {
          'list': [
            {'title': '雨夜', 'url': 'https://example.com/rain.mp3'},
            {'url': 'https://example.com/inn.ogg'},
            {'title': 'no url'},
            {'url': ''},
            'not a track',
          ],
          'settings': {'enabled': false, 'mode': 'shuffle', 'muted': true, 'volume': 140, 'extra': 1},
        },
        'ambient': {
          'list': 'not a list',
          'settings': {'mode': 'loud', 'volume': double.nan, 'enabled': 'yes'},
        },
        'voice': {'list': <Object?>[]},
      }),
      {
        'bgm': {
          'list': [
            {'title': '雨夜', 'url': 'https://example.com/rain.mp3'},
            {'title': '', 'url': 'https://example.com/inn.ogg'},
          ],
          'settings': {'enabled': false, 'mode': 'shuffle', 'muted': true, 'volume': 100},
        },
        'ambient': {'list': <Object?>[], 'settings': <String, Object?>{}},
      },
    );
    expect(tavernAudioState(null), isEmpty);
    expect(tavernAudioState({'bgm': 'x'}), isEmpty);
  });

  test('kept per chat on this phone; a chat never set has nothing', () async {
    SharedPreferences.setMockInitialValues({});
    expect(await tavernLoadAudio('c1'), isEmpty);
    await tavernSaveAudio('c1', {
      'bgm': {
        'list': [
          {'title': 'a', 'url': 'u1'},
        ],
        'settings': {'volume': 40},
      },
    });
    expect(await tavernLoadAudio('c1'), {
      'bgm': {
        'list': [
          {'title': 'a', 'url': 'u1'},
        ],
        'settings': {'volume': 40},
      },
    });
    expect(await tavernLoadAudio('c2'), isEmpty);

    SharedPreferences.setMockInitialValues({'tavern.audio.c3': '{not json'});
    expect(await tavernLoadAudio('c3'), isEmpty);
  });
}
