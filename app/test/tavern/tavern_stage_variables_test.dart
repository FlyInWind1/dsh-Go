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

/// The preview, its macros having saved [variables].
class _Saved extends PreviewTavern {
  _Saved(this.variables) : super(tick: Duration.zero);

  Map<String, Object?> variables;
  int reads = 0;

  @override
  Future<Map<String, Object?>> readVariables(String chatId) async {
    reads++;
    return {...variables};
  }
}

Future<void> _open(WidgetTester tester, PreviewTavern tavern, {Size size = const Size(390, 844)}) async {
  SharedPreferences.setMockInitialValues({});
  final chat = (await tester.runAsync(() => tavern.createChat('sample-innkeeper')))!;
  tester.view.physicalSize = size * 2;
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
}

Future<void> _stateTab(WidgetTester tester) async {
  await tester.tap(find.descendant(of: find.byKey(const ValueKey('tavern-stage-tabs')), matching: find.text('状态')));
  await tester.pumpAndSettle();
}

Finder _row(String key) => find.byKey(ValueKey('tavern-variable-$key'));

void main() {
  testWidgets('状态 lists what the macros saved, sorted; one opens whole', (tester) async {
    await _open(
      tester,
      _Saved({
        'location': '旅店',
        'affection': 5,
        'stat_data': {
          'hp': 10,
          'items': ['钥匙'],
        },
      }),
    );
    await tester.tap(find.byKey(const ValueKey('bot-action')));
    await tester.pumpAndSettle();
    await _stateTab(tester);

    expect(find.byKey(const ValueKey('tavern-stage-variables')), findsOneWidget);
    expect(find.descendant(of: _row('affection'), matching: find.text('5')), findsOneWidget);
    expect(find.descendant(of: _row('location'), matching: find.text('旅店')), findsOneWidget);
    expect(find.descendant(of: _row('stat_data'), matching: find.text('{"hp":10,"items":["钥匙"]}')), findsOneWidget);
    expect(tester.getTopLeft(_row('affection')).dy, lessThan(tester.getTopLeft(_row('location')).dy)); // sorted by name

    await tester.tap(_row('stat_data'));
    await tester.pumpAndSettle();
    final whole = tester.widget<SelectableText>(find.byKey(const ValueKey('tavern-variable-whole')));
    expect(whole.data, contains('"hp": 10'));
    expect(whole.data, contains('"钥匙"'));
  });

  testWidgets('with nothing saved, 状态 says what will be there', (tester) async {
    await _open(tester, _Saved({}));
    await tester.tap(find.byKey(const ValueKey('bot-action')));
    await tester.pumpAndSettle();
    await _stateTab(tester);
    expect(find.byKey(const ValueKey('tavern-stage-variables')), findsNothing);
    expect(find.byKey(const ValueKey('tavern-stage-state')), findsOneWidget);
  });

  testWidgets('beside the story, a new message reads them again', (tester) async {
    final tavern = _Saved({'affection': 5});
    await _open(tester, tavern, size: const Size(1200, 900));
    await _stateTab(tester);
    expect(find.descendant(of: _row('affection'), matching: find.text('5')), findsOneWidget);

    tavern.variables = {'affection': 6};
    await tester.enterText(find.byType(TextField), '外面怎么了？');
    await tester.pump();
    await tester.tap(find.byIcon(AppIcons.send));
    for (var i = 0; i < 100; i++) {
      await tester.pump(const Duration(milliseconds: 5));
    }
    await tester.pumpAndSettle();
    expect(find.descendant(of: _row('affection'), matching: find.text('6')), findsOneWidget);
  });
}
