import 'dart:convert';

import 'package:dsh_app/tavern/tavern_preview.dart';
import 'package:dsh_app/tavern/tavern_provider.dart';
import 'package:dsh_app/ui/tavern/tavern_preset_page.dart';
import 'package:dsh_app/ui/tavern/tavern_presets_page.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/test_fonts.dart';

/// A small ST preset: three prompts, sent as the 100001 group orders them.
final _preset = jsonEncode({
  'temperature': 1.0,
  'openai_max_context': 16384,
  'openai_max_tokens': 1000,
  'prompts': [
    {'identifier': 'main', 'name': '主提示', 'content': '你是林晚。'},
    {'identifier': 'chatHistory', 'name': 'Chat History', 'marker': true},
    {'identifier': 'jailbreak', 'name': '收尾指令', 'content': '保持角色。'},
  ],
  'prompt_order': [
    {
      'character_id': 100000,
      'order': [
        {'identifier': 'jailbreak', 'enabled': true},
      ],
    },
    {
      'character_id': 100001,
      'order': [
        {'identifier': 'main', 'enabled': true},
        {'identifier': 'chatHistory', 'enabled': true},
        {'identifier': 'jailbreak', 'enabled': false},
      ],
    },
  ],
});

Future<(PreviewTavern, String)> _open(WidgetTester tester, {Widget Function(String id)? home}) async {
  SharedPreferences.setMockInitialValues({});
  final tavern = PreviewTavern(tick: Duration.zero);
  final id = (await tester.runAsync(() => tavern.importPreset(_preset, fileName: '长篇小说.json')))!.preset.id;
  tester.view.physicalSize = const Size(390, 844) * 2;
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [tavernProvider.overrideWith((ref) => tavern)],
      child: MaterialApp(
        theme: withTestFonts(buildLightTheme()),
        locale: const Locale('zh', 'CN'),
        supportedLocales: const [Locale('zh', 'CN'), Locale('en')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        home: home?.call(id) ?? TavernPresetPage(presetId: id),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return (tavern, id);
}

Future<Map<String, Object?>> _raw(WidgetTester tester, PreviewTavern tavern, String id) async =>
    (await tester.runAsync(() => tavern.preset(id)))!.raw;

void main() {
  test('the prompts come in the 100001 group\'s order, placeholders marked', () {
    final prompts = tavernPresetPrompts(jsonDecode(_preset) as Map<String, Object?>);
    expect(prompts.map((p) => p.name), ['主提示', 'Chat History', '收尾指令']);
    expect(prompts.map((p) => p.enabled), [true, true, false]);
    expect(prompts[1].marker, isTrue);
  });

  testWidgets('the page shows the numbers and the prompts as the preset has them', (tester) async {
    await _open(tester);
    expect(find.text('长篇小说'), findsWidgets);
    final order = [
      for (final id in ['main', 'chatHistory', 'jailbreak'])
        tester.getTopLeft(find.byKey(ValueKey('tavern-preset-prompt-$id'))).dy,
    ];
    expect(order, orderedEquals([...order]..sort()));
    expect(find.text('占位'), findsOneWidget);
  });

  testWidgets('a prompt switched on, and a number changed, are saved to the preset', (tester) async {
    final (tavern, id) = await _open(tester);
    await tester.tap(
      find.descendant(of: find.byKey(const ValueKey('tavern-preset-prompt-jailbreak')), matching: find.byType(Switch)),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(of: find.byKey(const ValueKey('tavern-preset-temperature')), matching: find.text('1.3')),
    );
    await tester.pumpAndSettle();

    final raw = await _raw(tester, tavern, id);
    expect(tavernPresetPrompts(raw).last.enabled, isTrue);
    expect(raw['temperature'], 1.3);
    expect(raw['prompts'], isA<List<Object?>>().having((p) => p.length, 'length', 3)); // the rest kept
  });

  testWidgets('the library opens a preset for editing', (tester) async {
    final (_, id) = await _open(tester, home: (_) => const TavernPresetsPage());
    await tester.tap(find.byKey(ValueKey('tavern-preset-$id')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('编辑预设'));
    await tester.pumpAndSettle();
    expect(find.byType(TavernPresetPage), findsOneWidget);
  });
}
