import 'package:dsh_app/tavern/tavern_preview.dart';
import 'package:dsh_app/tavern/tavern_provider.dart';
import 'package:dsh_app/ui/tavern/tavern_character_page.dart';
import 'package:dsh_app/ui/tavern/tavern_chat_page.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/test_fonts.dart';

Future<void> _openCharacter(WidgetTester tester, PreviewTavern tavern) async {
  SharedPreferences.setMockInitialValues({});
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
        home: const TavernCharacterPage(characterId: 'sample-innkeeper'),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('a first visit has 开始 as its one main button', (tester) async {
    await _openCharacter(tester, PreviewTavern(tick: Duration.zero));
    expect(find.byKey(const ValueKey('tavern-continue-last')), findsNothing);
    expect(find.widgetWithText(FilledButton, '开始'), findsOneWidget);
  });

  testWidgets('back again, 继续上次 opens the newest chat; a new one is from a greeting', (tester) async {
    final tavern = PreviewTavern(tick: Duration.zero);
    await tester.runAsync(() => tavern.createChat('sample-innkeeper'));
    final newest = (await tester.runAsync(() => tavern.createChat('sample-innkeeper', greeting: 1)))!;
    await _openCharacter(tester, tavern);

    final resume = find.byKey(const ValueKey('tavern-continue-last'));
    expect(resume, findsOneWidget);
    // On the first screen, above the greetings.
    expect(
      tester.getTopLeft(resume).dy,
      lessThan(tester.getTopLeft(find.byKey(const ValueKey('tavern-greetings'))).dy),
    );
    expect(find.widgetWithText(OutlinedButton, '用这个开场白开始新对话'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, '开始'), findsNothing);

    await tester.tap(resume);
    await tester.pumpAndSettle();
    expect(tester.widget<TavernChatPage>(find.byType(TavernChatPage)).chatId, newest);
  });
}
