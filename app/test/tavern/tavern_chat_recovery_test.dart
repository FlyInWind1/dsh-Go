import 'package:dsh_app/tavern/tavern_preview.dart';
import 'package:dsh_app/tavern/tavern_provider.dart';
import 'package:dsh_app/ui/chat/widgets/thinking_pill.dart';
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
  _FlakyTavern([this.kind = TavernFailure.network]) : super(tick: const Duration(milliseconds: 1));

  final TavernFailure kind;

  var failed = false;

  @override
  Stream<TavernEvent> send(String chatId, String text) {
    if (failed) return super.send(chatId, text);
    failed = true;
    return Stream.value(TavernTurnFailed(kind));
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

  testWidgets('no key: the error offers 设置, not a retry that cannot work', (tester) async {
    await _open(tester, _FlakyTavern(TavernFailure.noKey));

    await tester.enterText(find.byType(TextField), '外面怎么了？');
    await tester.pump();
    await tester.tap(find.byIcon(AppIcons.send));
    await _settle(tester);

    expect(find.text('先在设置里填 DeepSeek API Key'), findsOneWidget);
    expect(find.widgetWithText(TextField, '外面怎么了？'), findsOneWidget);
    final banner = find.byKey(const ValueKey('tavern-error'));
    expect(find.descendant(of: banner, matching: find.text('设置')), findsOneWidget);
    expect(find.descendant(of: banner, matching: find.text('重试')), findsNothing);
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

  testWidgets('with 思考 on, the thinking shows above the reply and stays folded after', (tester) async {
    final tavern = PreviewTavern(tick: const Duration(milliseconds: 1))
      ..configure(TavernModelConfig(apiKey: () async => 'k', thinking: true));
    await _open(tester, tavern);
    await tester.enterText(find.byType(TextField), '你好');
    await tester.pump();
    await tester.tap(find.byIcon(AppIcons.send));
    await _settle(tester);

    expect(find.byType(ThinkingPill), findsOneWidget);
    expect(find.textContaining('地下室').evaluate().isEmpty, isTrue); // a greeting reply, not the question one
    expect(find.textContaining('炉子'), findsOneWidget);
  });

  testWidgets('视觉小说 pages through paragraphs and follows a new reply', (tester) async {
    SharedPreferences.setMockInitialValues({'tavern.layout': 'visualNovel'});
    await _open(tester, PreviewTavern(tick: const Duration(milliseconds: 1)));

    // The greeting is two paragraphs; the newest one shows.
    expect(find.text('2/2'), findsOneWidget);
    await tester.fling(find.byKey(const ValueKey('tavern-vn-box')), const Offset(300, 0), 1000);
    await tester.pumpAndSettle();
    expect(find.text('1/2'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('tavern-vn-box')));
    await tester.pumpAndSettle();
    expect(find.text('2/2'), findsOneWidget);

    await tester.enterText(find.byType(TextField), '外面怎么了？');
    await tester.pump();
    await tester.tap(find.byIcon(AppIcons.send));
    await _settle(tester);
    expect(find.textContaining('地下室'), findsOneWidget);
  });

  testWidgets('the title opens a quick look where this chat picks its own layout', (tester) async {
    final chat = await _open(tester, PreviewTavern(tick: const Duration(milliseconds: 1)));

    await tester.tap(find.byKey(const ValueKey('bot-title')));
    await tester.pumpAndSettle();
    expect(find.text('角色详情'), findsOneWidget);
    await tester.tap(find.descendant(of: find.byKey(const ValueKey('tavern-chat-layout')), matching: find.text('小说')));
    await tester.pumpAndSettle();

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('tavern.layout.$chat'), 'novel');
    expect(find.text('跟随酒馆设置'), findsOneWidget);
  });

  testWidgets('视觉小说 opens the backlog and closes it again', (tester) async {
    SharedPreferences.setMockInitialValues({'tavern.layout': 'visualNovel'});
    await _open(tester, PreviewTavern(tick: const Duration(milliseconds: 1)));

    await tester.tap(find.byKey(const ValueKey('tavern-vn-log')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('tavern-vn-backlog')), findsOneWidget);
    expect(find.textContaining('旅店的门被风推开'), findsWidgets);

    await tester.tap(find.byIcon(AppIcons.close));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('tavern-vn-backlog')), findsNothing);
  });
}
