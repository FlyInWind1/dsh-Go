import 'package:dsh_app/ui/common/brief_notice.dart';
import 'package:dsh_app/ui/tavern/tavern_toasts.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<ScaffoldMessengerState> _messenger(WidgetTester tester) async {
  await tester.pumpWidget(const MaterialApp(home: Scaffold(body: SizedBox.expand())));
  return tester.state<ScaffoldMessengerState>(find.byType(ScaffoldMessenger));
}

final _toast = find.byKey(const ValueKey('tavern-canvas-toast'));

void main() {
  testWidgets("a card's toastr is the app's notice; a second takes the first one's place", (tester) async {
    final messenger = await _messenger(tester);
    final toasts = TavernToasts();
    toasts.show(messenger, {'type': 'toast', 'level': 'info', 'title': '', 'message': '   '});
    await tester.pump();
    expect(_toast, findsNothing);

    toasts.show(messenger, {'type': 'toast', 'level': 'success', 'title': '存档', 'message': '已保存'});
    await tester.pumpAndSettle();
    expect(_toast, findsOneWidget);
    expect(find.text('存档\n已保存'), findsOneWidget);
    // The title is the heading.
    final words = tester.widget<Text>(find.byKey(const ValueKey('tavern-canvas-toast-text'))).textSpan! as TextSpan;
    expect((words.children!.first as TextSpan).style?.fontWeight, FontWeight.w600);
    expect((words.children!.last as TextSpan).style, isNull);

    toasts.show(messenger, {'type': 'toast', 'level': 'info', 'title': '', 'message': '又一条'});
    await tester.pump();
    expect(_toast, findsOneWidget);
    expect(find.text('又一条'), findsOneWidget);
    expect(find.text('存档\n已保存'), findsNothing);

    // A tap puts it away; the next is a new notice.
    await tester.tap(find.text('又一条'));
    await tester.pumpAndSettle();
    expect(_toast, findsNothing);
    toasts.show(messenger, {'type': 'toast', 'level': 'error', 'title': '出错', 'message': ''});
    await tester.pumpAndSettle();
    expect(find.text('出错'), findsOneWidget);
    // An error stays up four seconds.
    await tester.pump(const Duration(milliseconds: 3500));
    expect(find.text('出错'), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(_toast, findsNothing);
    toasts.dispose();
  });

  testWidgets("the app's own notice is not put away for one: it waits its turn", (tester) async {
    final messenger = await _messenger(tester);
    final toasts = TavernToasts();
    messenger.showBriefNotice('已复制');
    await tester.pumpAndSettle();
    toasts.show(messenger, {'type': 'toast', 'level': 'info', 'title': '', 'message': '卡说话了'});
    await tester.pump();
    expect(find.text('已复制'), findsOneWidget);
    expect(_toast, findsNothing);

    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
    expect(find.text('已复制'), findsNothing);
    expect(find.text('卡说话了'), findsOneWidget);
    toasts.dispose();
  });

  testWidgets('done with while one is up: it reads its words until it goes', (tester) async {
    final messenger = await _messenger(tester);
    final toasts = TavernToasts();
    toasts.show(messenger, {'type': 'toast', 'level': 'info', 'title': '', 'message': '还在'});
    await tester.pumpAndSettle();
    toasts.dispose();
    toasts.show(messenger, {'type': 'toast', 'level': 'info', 'title': '', 'message': '不再'});
    await tester.pump();
    expect(find.text('还在'), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
    expect(_toast, findsNothing);
    toasts.dispose();
  });
}
