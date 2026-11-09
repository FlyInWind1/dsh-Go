import 'dart:convert';

import 'package:dsh_app/tavern/tavern_preview.dart';
import 'package:dsh_app/tavern/tavern_provider.dart';
import 'package:dsh_app/ui/tavern/tavern_character_page.dart';
import 'package:dsh_app/ui/tavern/tavern_home_page.dart';
import 'package:dsh_app/ui/tavern/tavern_widgets.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/test_fonts.dart';

/// The preview, accepting a card import.
class _Importing extends PreviewTavern {
  _Importing() : super(tick: const Duration(milliseconds: 1));

  final imported = <({String? fileName, Uint8List bytes})>[];

  @override
  Future<TavernCharacter> importCard(Uint8List bytes, {String? fileName}) async {
    imported.add((fileName: fileName, bytes: bytes));
    return TavernCharacter(id: 'sample-innkeeper', name: '林晚', importedAt: DateTime.now());
  }
}

Future<List<Uri>> _importLink(WidgetTester tester, _Importing tavern, String link, http.Response reply) async {
  final asked = <Uri>[];
  // An empty clipboard, answered at once.
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    SystemChannels.platform,
    (call) async => call.method == 'Clipboard.getData' ? <String, Object?>{'text': ''} : null,
  );
  addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        tavernProvider.overrideWith((ref) => tavern),
        tavernHttpClientProvider.overrideWithValue(
          MockClient((request) async {
            asked.add(request.url);
            return reply;
          }),
        ),
      ],
      child: MaterialApp(
        theme: withTestFonts(buildLightTheme()),
        locale: const Locale('zh', 'CN'),
        supportedLocales: const [Locale('zh', 'CN'), Locale('en')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        home: const TavernHomePage(),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const ValueKey('tavern-import')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const ValueKey('tavern-import-link')));
  await tester.pumpAndSettle();
  await tester.enterText(find.byKey(const ValueKey('tavern-link-field')), link);
  await tester.tap(find.byKey(const ValueKey('tavern-link-go')));
  await tester.pumpAndSettle();
  return asked;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  final card = utf8.encode(
    jsonEncode({
      'spec': 'chara_card_v3',
      'data': {'name': '林晚'},
    }),
  );

  testWidgets('a link to a card file downloads, imports and opens the card', (tester) async {
    final tavern = _Importing();
    final asked = await _importLink(
      tester,
      tavern,
      'https://example.com/cards/innkeeper.json',
      http.Response.bytes(card, 200, headers: {'content-type': 'application/json'}),
    );

    expect(asked.single.toString(), 'https://example.com/cards/innkeeper.json');
    expect(tavern.imported.single.fileName, 'innkeeper.json');
    expect(tavern.imported.single.bytes, card);
    expect(find.byType(TavernCharacterPage), findsOneWidget);
  });

  testWidgets('a web page instead of a card file says how to get the file', (tester) async {
    final tavern = _Importing();
    await _importLink(
      tester,
      tavern,
      'https://example.com/characters/innkeeper',
      http.Response('<html></html>', 200, headers: {'content-type': 'text/html; charset=utf-8'}),
    );
    expect(tavern.imported, isEmpty);
    expect(find.textContaining('这是网页，不是卡文件'), findsOneWidget);
  });

  testWidgets('a failed download says the status', (tester) async {
    final tavern = _Importing();
    await _importLink(tester, tavern, 'https://example.com/missing.png', http.Response('', 404));
    expect(tavern.imported, isEmpty);
    expect(find.text('下载失败（HTTP 404）'), findsOneWidget);
  });

  testWidgets('something that is not a web address is not fetched', (tester) async {
    final tavern = _Importing();
    final asked = await _importLink(tester, tavern, '林晚的卡', http.Response('', 200));
    expect(asked, isEmpty);
    expect(find.text('这不是一个网址'), findsOneWidget);
  });
}
