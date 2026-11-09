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

Future<void> _open(WidgetTester tester, String characterId) async {
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [tavernProvider.overrideWith((ref) => PreviewTavern(tick: const Duration(milliseconds: 1)))],
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
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('a card with a lorebook lists its entries, highest order first', (tester) async {
    await _open(tester, 'sample-innkeeper');
    await tester.ensureVisible(find.byKey(const ValueKey('tavern-lorebook')));
    await tester.tap(find.byKey(const ValueKey('tavern-lorebook')));
    await tester.pumpAndSettle();

    expect(find.byType(TavernLorebookPage), findsOneWidget);
    expect(find.text('雨镇'), findsWidgets); // the book's own name is the title
    expect(find.text('2 条'), findsOneWidget);
    // insertion_order 100 before 90.
    expect(
      find.descendant(of: find.byKey(const ValueKey('tavern-lore-0')), matching: find.text('地下室')),
      findsOneWidget,
    );
    expect(find.text('关键词：地下室、酒窖'), findsOneWidget);
    expect(find.descendant(of: find.byKey(const ValueKey('tavern-lore-1')), matching: find.text('常驻')), findsOneWidget);

    expect(find.byType(SelectableText), findsNothing);
    await tester.tap(find.byKey(const ValueKey('tavern-lore-0')));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(SelectableText, '旅店地下室名义上是酒窖，钥匙只有林晚有。'), findsOneWidget);
  });

  testWidgets('a card without a lorebook shows no 世界书 row', (tester) async {
    await _open(tester, 'sample-navigator');
    expect(find.byKey(const ValueKey('tavern-lorebook')), findsNothing);
  });
}
