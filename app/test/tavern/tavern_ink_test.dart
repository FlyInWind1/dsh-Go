import 'package:dsh_app/tavern/tavern_settings.dart';
import 'package:dsh_app/ui/chat/render/markdown_body.dart';
import 'package:dsh_app/ui/common/streaming_cursor.dart';
import 'package:dsh_app/ui/tavern/tavern_ink.dart';
import 'package:dsh_app/ui/tavern/tavern_reading.dart';
import 'package:dsh_app/ui/tavern/tavern_settings_page.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/test_fonts.dart';

Future<void> _pump(WidgetTester tester, Widget home) async {
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        theme: withTestFonts(buildLightTheme()),
        locale: const Locale('zh', 'CN'),
        supportedLocales: const [Locale('zh', 'CN'), Locale('en')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        home: Scaffold(body: home),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// Every piece of text drawn, with the colour it is drawn in.
Map<String, Color?> _drawn(WidgetTester tester) {
  final out = <String, Color?>{};
  for (final rich in tester.widgetList<RichText>(find.byType(RichText))) {
    rich.text.visitChildren((span) {
      if (span is TextSpan && (span.text?.trim().isNotEmpty ?? false)) out[span.text!.trim()] = span.style?.color;
      return true;
    });
  }
  return out;
}

const _line = '*她笑了笑* 「进来吧。」雨还在下。';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('each set has its own colours, light and dark; 素 has none', () {
    expect(TavernInk.of(TavernPalette.plain, Brightness.light).plain, isTrue);
    final light = TavernInk.of(TavernPalette.ember, Brightness.light);
    final dark = TavernInk.of(TavernPalette.ember, Brightness.dark);
    expect(light.dialogue, isNot(dark.dialogue));
    expect(light.dialogue, isNot(light.action));
    expect(TavernInk.of(TavernPalette.rose, Brightness.light).dialogue, isNot(light.dialogue));
  });

  testWidgets('what is said and what is done get their colours; the narration keeps the page\'s', (tester) async {
    await _pump(tester, const TavernReading(child: MarkdownBody(text: _line, selectable: false)));
    final ink = TavernInk.of(TavernPalette.ember, Brightness.light);
    final drawn = _drawn(tester);
    expect(drawn['「进来吧。」'], ink.dialogue);
    expect(drawn['她笑了笑'], ink.action);
    expect(drawn['雨还在下。'], isNot(ink.dialogue));
    expect(drawn['雨还在下。'], isNot(ink.action));
    // No asterisks left: it reads as italics.
    expect(drawn.keys.any((t) => t.contains('*')), isFalse);
  });

  testWidgets('素 draws the text as the app does', (tester) async {
    SharedPreferences.setMockInitialValues({TavernSettingsController.paletteKey: 'plain'});
    await _pump(tester, const TavernReading(child: MarkdownBody(text: _line, selectable: false)));
    final ink = TavernInk.of(TavernPalette.ember, Brightness.light);
    final drawn = _drawn(tester);
    expect(drawn['「进来吧。」'], isNot(ink.dialogue));
  });

  testWidgets('quotes in an HTML attribute are left alone', (tester) async {
    await _pump(tester, const TavernReading(child: MarkdownBody(text: '她说"好"。', selectable: false)));
    expect(_drawn(tester)['"好"'], TavernInk.of(TavernPalette.ember, Brightness.light).dialogue);
    expect(tavernInkPattern.pattern.allMatches('<span class="hp">').map((m) => m[0]), isNot(contains('"hp"')));
  });

  testWidgets('a reply being written keeps its cursor', (tester) async {
    // The cursor breathes for as long as the reply is written: one frame, not settling.
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: withTestFonts(buildLightTheme()),
          home: const Scaffold(
            body: TavernReading(child: MarkdownBody(text: '「进来吧」她说', streaming: true, selectable: false)),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.byType(StreamingCursor), findsOneWidget);
    expect(_drawn(tester)['「进来吧」'], TavernInk.of(TavernPalette.ember, Brightness.light).dialogue);
  });

  testWidgets('酒馆设置 picks the colours, kept', (tester) async {
    await _pump(tester, const TavernSettingsPage());
    await tester.ensureVisible(find.byKey(const ValueKey('tavern-palette')));
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(of: find.byKey(const ValueKey('tavern-palette')), matching: find.text('冷')));
    await tester.pumpAndSettle();
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(TavernSettingsController.paletteKey), 'ocean');
  });
}
