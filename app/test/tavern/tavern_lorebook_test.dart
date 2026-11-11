import 'dart:async';

import 'package:dsh_app/tavern/tavern_preview.dart';
import 'package:dsh_app/tavern/tavern_provider.dart';
import 'package:dsh_app/ui/tavern/tavern_character_page.dart';
import 'package:dsh_app/ui/tavern/tavern_lorebook_page.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/test_fonts.dart';

Future<PreviewTavern> _open(WidgetTester tester, String characterId) async {
  final tavern = PreviewTavern(tick: const Duration(milliseconds: 1));
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [tavernProvider.overrideWith((ref) => tavern)],
      child: MaterialApp(
        theme: withTestFonts(buildLightTheme()),
        locale: const Locale('zh', 'CN'),
        supportedLocales: const [Locale('zh', 'CN'), Locale('en')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        home: TavernCharacterPage(characterId: characterId),
      ),
    ),
  );
  await tester.pumpAndSettle();
  // On the 配置 tab.
  await tester.tap(find.descendant(of: find.byKey(const ValueKey('tavern-character-tabs')), matching: find.text('配置')));
  await tester.pumpAndSettle();
  final row = find.byKey(const ValueKey('tavern-lorebook'));
  await tester.scrollUntilVisible(row, 200, scrollable: find.byType(Scrollable).first);
  await _center(tester, row);
  await tester.tap(row);
  await tester.pumpAndSettle();
  expect(find.byType(TavernLorebookPage), findsOneWidget);
  return tavern;
}

/// Brings [target] to the middle of the page, clear of the glass header.
Future<void> _center(WidgetTester tester, Finder target) async {
  unawaited(Scrollable.ensureVisible(tester.element(target), alignment: 0.5));
  await tester.pumpAndSettle();
}

/// The card's book entries as stored, in their own order.
Future<List<Map<String, Object?>>> _entries(PreviewTavern tavern, String id) async => [
  for (final e in (((await tavern.characterFields(id))!['character_book'] as Map?)?['entries'] as List?) ?? const [])
    e as Map<String, Object?>,
];

Finder _input(String key) => find.descendant(of: find.byKey(ValueKey(key)), matching: find.byType(TextField));

Future<void> _save(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('tavern-lore-save')));
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('the book lists its entries highest order first, each with its keys and a switch', (tester) async {
    await _open(tester, 'sample-innkeeper');
    expect(find.text('雨镇'), findsWidgets); // the book's own name is the title
    expect(find.text('2 条'), findsOneWidget);
    // insertion_order 100 before 90.
    expect(
      find.descendant(of: find.byKey(const ValueKey('tavern-lore-0')), matching: find.text('地下室')),
      findsOneWidget,
    );
    expect(find.text('关键词：地下室、酒窖'), findsOneWidget);
    expect(find.descendant(of: find.byKey(const ValueKey('tavern-lore-1')), matching: find.text('常驻')), findsOneWidget);
    expect(find.byType(Switch), findsNWidgets(2));
  });

  testWidgets('a switch turns an entry off in the card', (tester) async {
    final tavern = await _open(tester, 'sample-innkeeper');
    await tester.tap(find.descendant(of: find.byKey(const ValueKey('tavern-lore-0')), matching: find.byType(Switch)));
    await tester.pumpAndSettle();
    final cellar = (await _entries(tavern, 'sample-innkeeper')).firstWhere((e) => '${e['keys']}'.contains('地下室'));
    expect(cellar['enabled'], isFalse);
    expect(cellar['content'], '旅店地下室名义上是酒窖，钥匙只有林晚有。'); // the rest kept
  });

  testWidgets('an entry opens to edit; only what changed is written', (tester) async {
    final tavern = await _open(tester, 'sample-innkeeper');
    await tester.tap(find.text('地下室').first);
    await tester.pumpAndSettle();
    expect(find.byType(TavernLorebookEntryPage), findsOneWidget);
    expect(find.text('编辑条目'), findsWidgets);

    await tester.enterText(_input('tavern-lore-keys'), '地下室，酒窖，钥匙');
    await tester.enterText(_input('tavern-lore-content'), '地下室锁着，钥匙挂在林晚腰上。');
    await _save(tester);
    expect(find.byType(TavernLorebookEntryPage), findsNothing);
    final cellar = (await _entries(tavern, 'sample-innkeeper')).firstWhere((e) => '${e['keys']}'.contains('钥匙'));
    expect(cellar['keys'], ['地下室', '酒窖', '钥匙']);
    expect(cellar['content'], '地下室锁着，钥匙挂在林晚腰上。');
    expect(cellar['insertion_order'], 100); // untouched
    expect(find.text('关键词：地下室、酒窖、钥匙'), findsOneWidget);
  });

  testWidgets('+ adds an entry from an empty form; delete asks, then it goes', (tester) async {
    final tavern = await _open(tester, 'sample-innkeeper');
    await tester.tap(find.byKey(const ValueKey('tavern-lore-add')));
    await tester.pumpAndSettle();
    expect(find.text('新条目'), findsWidgets);
    expect(find.byKey(const ValueKey('tavern-lore-delete')), findsNothing);
    await tester.enterText(_input('tavern-lore-name'), '码头');
    await tester.enterText(_input('tavern-lore-keys'), '码头, 船');
    await tester.enterText(_input('tavern-lore-content'), '镇东有个小码头，雨天不开船。');
    await _save(tester);
    final entries = await _entries(tavern, 'sample-innkeeper');
    expect(entries, hasLength(3));
    expect(entries.last['keys'], ['码头', '船']);
    expect(entries.last['enabled'], isTrue);
    expect(find.text('3 条'), findsOneWidget);

    await tester.tap(find.text('码头').first);
    await tester.pumpAndSettle();
    final delete = find.byKey(const ValueKey('tavern-lore-delete'));
    await _center(tester, delete);
    await tester.tap(delete);
    await tester.pumpAndSettle();
    expect(find.text('删除条目「码头」？'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, '删除'));
    await tester.pumpAndSettle();
    expect(await _entries(tavern, 'sample-innkeeper'), hasLength(2));
    expect(find.text('2 条'), findsOneWidget);
  });

  testWidgets('a card without a book starts one here', (tester) async {
    final tavern = await _open(tester, 'sample-navigator');
    expect(find.byKey(const ValueKey('tavern-lore-empty')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('tavern-lore-add')));
    await tester.pumpAndSettle();
    await tester.enterText(_input('tavern-lore-keys'), '星图');
    await tester.enterText(_input('tavern-lore-content'), '舰上的星图只有领航员能看懂。');
    await _save(tester);
    expect(await _entries(tavern, 'sample-navigator'), hasLength(1));
    expect(find.byKey(const ValueKey('tavern-lore-empty')), findsNothing);
    expect(find.text('1 条'), findsOneWidget);
  });
}
