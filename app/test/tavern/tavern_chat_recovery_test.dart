import 'package:dsh_app/tavern/tavern_preview.dart';
import 'package:dsh_app/tavern/tavern_provider.dart';
import 'package:dsh_app/ui/tavern/tavern_chat_page.dart';
import 'package:dsh_app/ui/theme/app_icons.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/test_fonts.dart';

/// The preview, except the first send fails before anything is stored.
class _FlakyTavern extends PreviewTavern {
  _FlakyTavern() : super(tick: const Duration(milliseconds: 1));

  var failed = false;

  @override
  Stream<TavernEvent> send(String chatId, String text) {
    if (failed) return super.send(chatId, text);
    failed = true;
    return Stream.value(const TavernTurnFailed(TavernFailure.network));
  }
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 200; i++) {
    await tester.pump(const Duration(milliseconds: 5));
  }
  await tester.pumpAndSettle();
}

Future<String> _open(WidgetTester tester, PreviewTavern tavern) async {
  final chat = await tavern.createChat('sample-innkeeper');
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
  return chat;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('a send that stored nothing puts the line back and offers 重试', (tester) async {
    await _open(tester, _FlakyTavern());

    await tester.enterText(find.byType(TextField), '外面怎么了？');
    await tester.pump();
    await tester.tap(find.byIcon(AppIcons.send));
    await _settle(tester);

    expect(find.text('连不上，检查网络后重试'), findsOneWidget);
    expect(find.widgetWithText(TextField, '外面怎么了？'), findsOneWidget);

    await tester.tap(find.text('重试'));
    await _settle(tester);
    expect(find.byKey(const ValueKey('tavern-error')), findsNothing);
    expect(find.textContaining('地下室'), findsOneWidget);
  });

  testWidgets('switching an earlier message offers to undo', (tester) async {
    await _open(tester, PreviewTavern(tick: const Duration(milliseconds: 1)));
    await tester.enterText(find.byType(TextField), '你好');
    await tester.pump();
    await tester.tap(find.byIcon(AppIcons.send));
    await _settle(tester);

    // The greeting (1/2) is the earlier message; the list is built newest first.
    await tester.tap(find.byKey(const ValueKey('tavern-next')).last);
    await tester.pumpAndSettle();
    expect(find.text('切到了另一条分支'), findsOneWidget);
    expect(find.text('你好'), findsNothing);

    await tester.tap(find.text('撤销'));
    await tester.pumpAndSettle();
    expect(find.text('你好'), findsOneWidget);
  });
}
