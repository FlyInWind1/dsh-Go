import 'package:dsh_app/tavern/tavern_preview.dart';
import 'package:dsh_app/tavern/tavern_provider.dart';
import 'package:dsh_app/ui/tavern/tavern_chat_page.dart';
import 'package:dsh_app/ui/theme/app_icons.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/test_fonts.dart';

/// The sample chat after one exchange: the greeting, your line, her reply.
Future<void> _openAfterOneExchange(WidgetTester tester) async {
  SharedPreferences.setMockInitialValues({});
  final tavern = PreviewTavern(tick: const Duration(milliseconds: 1));
  final chat = (await tester.runAsync(() => tavern.createChat('sample-innkeeper')))!;
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
        home: TavernChatPage(chatId: chat),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.enterText(find.byType(TextField), '外面怎么了？');
  await tester.pump();
  await tester.tap(find.byIcon(AppIcons.send));
  for (var i = 0; i < 200; i++) {
    await tester.pump(const Duration(milliseconds: 5));
  }
  await tester.pumpAndSettle();
  expect(find.textContaining('地下室', findRichText: true), findsWidgets);
}

/// Long-presses [text] and picks 删除这条及以后.
Future<void> _deleteFrom(WidgetTester tester, String text) async {
  await tester.longPress(find.textContaining(text, findRichText: true).last);
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const ValueKey('tavern-menu-delete')));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('deleting from a message says how many go and asks first', (tester) async {
    await _openAfterOneExchange(tester);

    // Your line and her reply: two.
    await _deleteFrom(tester, '外面怎么了');
    expect(find.text('删除这 2 条消息？'), findsOneWidget);
    expect(find.textContaining('找不回来'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, '取消'));
    await tester.pumpAndSettle();
    expect(find.textContaining('外面怎么了', findRichText: true), findsWidgets); // kept

    await _deleteFrom(tester, '外面怎么了');
    await tester.tap(find.widgetWithText(TextButton, '删除'));
    await tester.pumpAndSettle();
    expect(find.textContaining('外面怎么了', findRichText: true), findsNothing);
    expect(find.textContaining('地下室', findRichText: true), findsNothing);
  });

  testWidgets('the last message alone is one', (tester) async {
    await _openAfterOneExchange(tester);
    await _deleteFrom(tester, '地下室');
    expect(find.text('删除这条消息？'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, '取消'));
    await tester.pumpAndSettle();
    expect(find.textContaining('地下室', findRichText: true), findsWidgets);
  });
}
