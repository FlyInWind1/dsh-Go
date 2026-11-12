import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/tavern/tavern_card_scripts.dart';
import 'package:dsh_app/tavern/tavern_provider.dart';
import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, Object?> _card(Map<String, Object?> extensions) => {
  'spec': 'chara_card_v3',
  'spec_version': '3.0',
  'data': {'name': '林晚', 'description': '店主。', 'first_mes': '进来吧。', 'extensions': extensions},
};

Map<String, Object?> _script(
  String id, {
  bool enabled = true,
  String content = 'console.log(1);',
  Object? button,
  String? name,
}) => {
  'type': 'script',
  'enabled': enabled,
  'name': name ?? id,
  'id': id,
  'content': content,
  'info': '',
  'button': ?button,
  'data': <String, Object?>{},
};

void main() {
  test("a card's scripts that run: enabled, with code, in the tree's order, not under a folder that is off", () {
    final card = _card({
      'tavern_helper': {
        'scripts': [
          _script(
            'a',
            name: '状态栏',
            button: {
              'enabled': true,
              'buttons': [
                {'name': '前往', 'visible': true},
                {'name': '藏起来的', 'visible': false},
                {'name': '', 'visible': true},
              ],
            },
          ),
          _script('off', enabled: false),
          _script('blank', content: '   '),
          {
            'type': 'folder',
            'enabled': true,
            'name': '工具',
            'id': 'f1',
            'scripts': [
              _script('b'),
              {
                'type': 'folder',
                'enabled': false,
                'name': '关着',
                'id': 'f2',
                'scripts': [_script('hidden')],
              },
            ],
          },
          _script(
            'c',
            button: {
              'enabled': false,
              'buttons': [
                {'name': '不显示', 'visible': true},
              ],
            },
          ),
          'not a script',
          {'type': 'script', 'id': 'no-content', 'enabled': true},
        ],
      },
    });
    final scripts = tavernCardScripts(card);
    expect([for (final s in scripts) s.id], ['a', 'b', 'c']);
    expect(scripts.first.name, '状态栏');
    expect(scripts.first.buttons, ['前往']);
    expect(scripts.last.buttons, isEmpty);
    expect(scripts.first.toJson(), {
      'id': 'a',
      'name': '状态栏',
      'content': 'console.log(1);',
      'buttons': ['前往'],
    });
  });

  test('the older place for them is read too; a card without any has none', () {
    expect(
      [
        for (final s in tavernCardScripts(
          _card({
            'TavernHelper_scripts': [_script('old')],
          }),
        ))
          s.id,
      ],
      ['old'],
    );
    // The newer place wins when both are there.
    expect(
      [
        for (final s in tavernCardScripts(
          _card({
            'tavern_helper': {
              'scripts': [_script('new')],
            },
            'TavernHelper_scripts': [_script('old')],
          }),
        ))
          s.id,
      ],
      ['new'],
    );
    expect(tavernCardScripts(_card({})), isEmpty);
    expect(tavernCardScripts({'name': 'v1 card'}), isEmpty);
    expect(tavernCardScripts(null), isEmpty);
    // Fields at the top (no data wrapper) are read as well.
    expect(
      tavernCardScripts({
        'extensions': {
          'TavernHelper_scripts': [_script('top')],
        },
      }).single.id,
      'top',
    );
  });

  test("the scripts come back from the engine's own copy of the card", () async {
    final dir = await Directory.systemTemp.createTemp('card-scripts');
    final tavern = await openTavern(dir.path);
    addTearDown(() async {
      await tavern.close();
      await dir.delete(recursive: true);
    });
    final card = _card({
      'tavern_helper': {
        'scripts': [_script('s1', name: '变量初始化', content: 'await initVars();'), _script('s2', enabled: false)],
        'variables': {'hp': 10},
      },
    });
    final id = (await tavern.importCard(utf8.encode(jsonEncode(card)), fileName: 'card.json')).id;
    final container = ProviderContainer(overrides: [tavernProvider.overrideWithValue(tavern)]);
    addTearDown(container.dispose);
    final sub = container.listen(tavernCardScriptsProvider(id), (_, _) {});
    addTearDown(sub.close);
    final scripts = await container.read(tavernCardScriptsProvider(id).future);
    expect(scripts, [const TavernCardScript(id: 's1', name: '变量初始化', content: 'await initVars();')]);
  });
}
