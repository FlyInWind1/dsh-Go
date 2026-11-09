import 'package:dsh_app/tavern/tavern_preview.dart';
import 'package:dsh_app/tavern/tavern_provider.dart';
import 'package:dsh_app/ui/tavern/tavern_chat_page.dart';
import 'package:dsh_app/ui/tavern/tavern_home_page.dart';
import 'package:dsh_app/ui/theme/app_icons.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/test_fonts.dart';

Widget _app() => ProviderScope(
  overrides: [tavernProvider.overrideWith((ref) => PreviewTavern(tick: const Duration(milliseconds: 1)))],
  child: MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: withTestFonts(buildLightTheme()),
    locale: const Locale('zh', 'CN'),
    supportedLocales: const [Locale('zh', 'CN'), Locale('en')],
    localizationsDelegates: GlobalMaterialLocalizations.delegates,
    home: const TavernHomePage(),
  ),
);

/// Lets a preview reply stream to the end.
Future<void> _finishReply(WidgetTester tester) async {
  for (var i = 0; i < 200; i++) {
    await tester.pump(const Duration(milliseconds: 5));
  }
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('the home lists the characters', (tester) async {
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();

    expect(find.text('酒馆'), findsWidgets);
    expect(find.text('林晚'), findsOneWidget);
    expect(find.text('星图'), findsOneWidget);
    expect(find.byKey(const ValueKey('tavern-continue')), findsNothing);
  });

  testWidgets('start a chat, send a line, swipe to a new reply', (tester) async {
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('tavern-character-sample-innkeeper')));
    await tester.pumpAndSettle();
    expect(find.text('开场白 1/2'), findsOneWidget);

    await tester.ensureVisible(find.byKey(const ValueKey('tavern-start')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('tavern-start')));
    await tester.pumpAndSettle();
    expect(find.byType(TavernChatPage), findsOneWidget);
    expect(find.textContaining('炉子还热着'), findsOneWidget);

    await tester.enterText(find.byType(TextField), '外面怎么了？');
    await tester.pump();
    await tester.tap(find.byIcon(AppIcons.send));
    await _finishReply(tester);

    expect(find.text('外面怎么了？'), findsOneWidget);
    expect(find.textContaining('地下室'), findsOneWidget);
    expect(find.text('1/1'), findsOneWidget);

    // Past the last alternative, › writes a new one.
    await tester.tap(find.byKey(const ValueKey('tavern-next')).first);
    await _finishReply(tester);
    expect(find.text('2/2'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('tavern-prev')).first);
    await tester.pumpAndSettle();
    expect(find.text('1/2'), findsNWidgets(2)); // the greeting and the reply
    expect(find.textContaining('地下室'), findsOneWidget);
  });

  testWidgets('long-press a character to delete it', (tester) async {
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();

    await tester.longPress(find.byKey(const ValueKey('tavern-character-sample-navigator')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除角色'));
    await tester.pumpAndSettle();
    expect(find.text('删除「星图」？'), findsOneWidget);
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();

    expect(find.text('星图'), findsNothing);
    expect(find.text('林晚'), findsOneWidget);
  });

  testWidgets('search and tags narrow the characters', (tester) async {
    TavernHomePage.searchFrom = 2;
    addTearDown(() => TavernHomePage.searchFrom = 6);
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '星');
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('tavern-character-sample-navigator')), findsOneWidget);
    expect(find.byKey(const ValueKey('tavern-character-sample-innkeeper')), findsNothing);

    await tester.enterText(find.byType(TextField), '');
    await tester.pumpAndSettle();
    await tester.tap(find.text('悬疑'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('tavern-character-sample-innkeeper')), findsOneWidget);
    expect(find.byKey(const ValueKey('tavern-character-sample-navigator')), findsNothing);

    await tester.enterText(find.byType(TextField), '没有这个人');
    await tester.pumpAndSettle();
    expect(find.text('没有符合的角色'), findsOneWidget);
  });
}
