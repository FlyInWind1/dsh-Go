import 'dart:async';
import 'dart:convert';

import 'package:dsh_app/tavern/tavern_preview.dart';
import 'package:dsh_app/tavern/tavern_provider.dart';
import 'package:dsh_app/ui/tavern/tavern_message_edit_page.dart';
import 'package:dsh_app/ui/tavern/tavern_preset_page.dart';
import 'package:dsh_app/ui/tavern/tavern_presets_page.dart';
import 'package:dsh_app/ui/theme/app_icons.dart';
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
      find.descendant(of: find.byKey(const ValueKey('tavern-preset-temperature')), matching: find.text('1.3')),
    );
    await tester.pumpAndSettle();
    final jailbreak = find.byKey(const ValueKey('tavern-preset-prompt-jailbreak'));
    await _center(tester, jailbreak);
    await tester.tap(find.descendant(of: jailbreak, matching: find.byType(Switch)));
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

  prefillAndOrder();
  promptText();
}

/// Brings [target] to the middle of the page, clear of the glass header.
Future<void> _center(WidgetTester tester, Finder target) async {
  unawaited(Scrollable.ensureVisible(tester.element(target), alignment: 0.5));
  await tester.pumpAndSettle();
}

Map<String, Object?> _prefill(Map<String, Object?> raw) => switch (raw['extensions']) {
  {'dshgo': {'prefill': final Map<String, Object?> p}} => p,
  _ => const {},
};

/// Lifts [id]'s row in the order sheet by its handle and drops it [rows]
/// rows down (up when negative), in small steps.
Future<void> _drag(WidgetTester tester, String id, int rows) async {
  final row = find.byKey(ValueKey('tavern-preset-order-$id'));
  final handle = find.descendant(of: row, matching: find.byIcon(AppIcons.dragHandle));
  final finger = await tester.startGesture(tester.getCenter(handle));
  await tester.pump(const Duration(milliseconds: 100));
  final height = tester.getSize(row).height;
  for (var i = 0; i < 12; i++) {
    await finger.moveBy(Offset(0, height * rows / 12));
    await tester.pump(const Duration(milliseconds: 16));
  }
  await tester.pump(const Duration(milliseconds: 300));
  await finger.up();
  await tester.pumpAndSettle();
}

void prefillAndOrder() {
  testWidgets('the prefill is switched on, written, and put in the thinking; each part kept', (tester) async {
    final (tavern, id) = await _open(tester);
    expect(find.text('还没写'), findsOneWidget);

    await tester.tap(
      find.descendant(of: find.byKey(const ValueKey('tavern-preset-prefill')), matching: find.byType(Switch)),
    );
    await tester.pumpAndSettle();
    expect(_prefill(await _raw(tester, tavern, id))['enabled'], isTrue);

    await tester.tap(find.byKey(const ValueKey('tavern-preset-prefill-text')));
    await tester.pumpAndSettle();
    expect(find.byType(TavernMessageEditPage), findsOneWidget);
    expect(find.text('预填充'), findsWidgets);
    await tester.enterText(find.byKey(const ValueKey('tavern-message-field')), '好的，我继续以林晚的身份写：\n第二行');
    await tester.tap(find.byKey(const ValueKey('tavern-message-save')));
    await tester.pumpAndSettle();
    expect((await _raw(tester, tavern, id))['assistant_prefill'], '好的，我继续以林晚的身份写：\n第二行');
    expect(find.text('好的，我继续以林晚的身份写：'), findsOneWidget); // its first line

    await tester.tap(
      find.descendant(of: find.byKey(const ValueKey('tavern-preset-prefill-target')), matching: find.text('思考')),
    );
    await tester.pumpAndSettle();
    final raw = await _raw(tester, tavern, id);
    expect(_prefill(raw), {'enabled': true, 'target': 'reasoning'});
    expect(raw['prompts'], isA<List<Object?>>().having((p) => p.length, 'length', 3)); // the rest kept
  });

  testWidgets('调整顺序 drags a prompt up; the order is saved, each switch with it', (tester) async {
    final (tavern, id) = await _open(tester);
    final open = find.byKey(const ValueKey('tavern-preset-order'));
    await _center(tester, open);
    await tester.tap(open);
    await tester.pumpAndSettle();
    expect(find.text('按住右边的把手拖动。提示词按这个顺序发给模型，关着的也留在原位。'), findsOneWidget);
    expect(
      find.descendant(of: find.byKey(const ValueKey('tavern-preset-order-jailbreak')), matching: find.text('已关')),
      findsOneWidget,
    );

    await _drag(tester, 'jailbreak', -2);
    final prompts = tavernPresetPrompts(await _raw(tester, tavern, id));
    expect(prompts.map((p) => p.id), ['jailbreak', 'main', 'chatHistory']);
    expect(prompts.map((p) => p.enabled), [false, true, true]);
  });
}

void promptText() {
  test('a prompt carries its text; a placeholder has none', () {
    final prompts = tavernPresetPrompts(jsonDecode(_preset) as Map<String, Object?>);
    expect(prompts.map((p) => p.content), ['你是林晚。', null, '保持角色。']);
  });

  testWidgets('a prompt opens to its text; what is saved goes to that prompt alone', (tester) async {
    final (tavern, id) = await _open(tester);
    final main = find.byKey(const ValueKey('tavern-preset-prompt-main'));
    await _center(tester, main);
    expect(find.descendant(of: main, matching: find.text('你是林晚。')), findsOneWidget);

    await tester.tap(find.descendant(of: main, matching: find.text('主提示')));
    await tester.pumpAndSettle();
    expect(find.byType(TavernMessageEditPage), findsOneWidget);
    expect(find.text('主提示'), findsWidgets); // the editor's title
    await tester.enterText(find.byKey(const ValueKey('tavern-message-field')), '你是林晚，旅店的老板娘。\n只说一半。');
    await tester.tap(find.byKey(const ValueKey('tavern-message-save')));
    await tester.pumpAndSettle();

    final raw = await _raw(tester, tavern, id);
    expect(tavernPresetPrompts(raw).map((p) => p.content), ['你是林晚，旅店的老板娘。\n只说一半。', null, '保持角色。']);
    expect(tavernPresetPrompts(raw).first.enabled, isTrue); // the switch untouched
    expect(find.descendant(of: main, matching: find.text('你是林晚，旅店的老板娘。')), findsOneWidget);
  });

  testWidgets('the switch on a prompt with text turns it off without opening it', (tester) async {
    final (tavern, id) = await _open(tester);
    final main = find.byKey(const ValueKey('tavern-preset-prompt-main'));
    await _center(tester, main);
    await tester.tap(find.descendant(of: main, matching: find.byType(Switch)));
    await tester.pumpAndSettle();
    expect(find.byType(TavernMessageEditPage), findsNothing);
    expect(tavernPresetPrompts(await _raw(tester, tavern, id)).first.enabled, isFalse);
  });
}
