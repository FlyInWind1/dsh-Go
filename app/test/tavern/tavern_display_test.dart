import 'package:dsh_app/tavern/tavern_preview.dart';
import 'package:dsh_app/tavern/tavern_provider.dart';
import 'package:dsh_app/ui/tavern/tavern_chat_page.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/test_fonts.dart';

/// The preview, its display pass rewriting one phrase as a display regex
/// would; or failing, when [broken].
class _Displayed extends PreviewTavern {
  _Displayed({this.broken = false}) : super(tick: Duration.zero);

  final bool broken;

  @override
  Future<TavernDisplayResult> displayText(
    String chatId, {
    String? nodeId,
    String? text,
    TavernRole? role,
    String? speaker,
    num? depth,
    bool reasoning = false,
  }) async {
    if (broken) throw StateError('worker gone');
    final stored = await super.displayText(chatId, nodeId: nodeId, text: text);
    return TavernDisplayResult(text: stored.text.replaceAll('冷雨', '冷雨【显示正则】'), replacements: 1);
  }
}

Future<(PreviewTavern, String)> _open(WidgetTester tester, PreviewTavern tavern, String layout) async {
  SharedPreferences.setMockInitialValues({'tavern.layout': layout});
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
  return (tavern, chat);
}

void main() {
  for (final layout in ['bubble', 'novel']) {
    testWidgets('$layout: a message shows through the display regex; what is stored does not change', (tester) async {
      final (tavern, chat) = await _open(tester, _Displayed(), layout);
      expect(find.textContaining('冷雨【显示正则】', findRichText: true), findsOneWidget);
      final stored = await tester.runAsync(() => tavern.path(chat));
      expect(stored!.first.text, contains('冷雨'));
      expect(stored.first.text, isNot(contains('显示正则')));
    });
  }

  testWidgets('when the display pass fails, the text shows as written', (tester) async {
    await _open(tester, _Displayed(broken: true), 'bubble');
    expect(find.textContaining('带进一阵冷雨', findRichText: true), findsOneWidget);
    expect(find.textContaining('显示正则', findRichText: true), findsNothing);
  });
}
