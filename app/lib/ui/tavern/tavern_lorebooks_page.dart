// 资源库 › 世界书 (docs/design/roleplay-roadmap.md P0, engine T21): standalone
// lorebooks, exported from SillyTavern, imported as they are; each can be
// used in every chat (the global binding), exported or deleted. A card's own
// lorebook goes with the card (its page shows it), not here.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../tavern/tavern_provider.dart';
import '../common/app_sheet.dart';
import '../common/brief_notice.dart';
import '../features/feature_kit.dart';
import '../settings/settings_widgets.dart';
import '../shell/page_frame.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'tavern_chat_files.dart';
import 'tavern_presets_page.dart' show tavernTextOf;
import 'tavern_widgets.dart';

/// The standalone lorebooks, and which of them every chat uses.
final tavernLorebooksProvider = FutureProvider.autoDispose<({List<TavernLorebookSummary> books, List<String> global})>((
  ref,
) async {
  final tavern = ref.watch(tavernProvider);
  final books = await tavern.listLorebooks();
  final settings = await tavern.readSettings();
  final bound = switch (settings['lorebooks']) {
    {'global': final List<Object?> ids} => [for (final id in ids) '$id'],
    _ => const <String>[],
  };
  return (books: books, global: bound);
});

class TavernLorebooksPage extends ConsumerWidget {
  const TavernLorebooksPage({super.key});

  static Route<void> route() => MaterialPageRoute<void>(builder: (_) => const TavernLorebooksPage());

  Future<void> _import(BuildContext context, WidgetRef ref) async {
    final l10n = context.l10n;
    final messenger = ScaffoldMessenger.maybeOf(context);
    final tavern = ref.read(tavernProvider);
    for (final file in await ref.read(tavernChatPickerProvider)()) {
      try {
        final result = await tavern.importLorebook(tavernTextOf(file.bytes), fileName: file.fileName);
        messenger?.showBriefNotice(l10n.tavernLorebookImported(result.book.name, result.book.entryCount));
      } on Object catch (e) {
        messenger?.showBriefNotice(
          l10n.tavernPresetImportFailed(e is FormatException ? l10n.tavernPresetNotText : '$e'),
        );
      }
    }
    ref.invalidate(tavernLorebooksProvider);
  }

  /// [id] in or out of the global binding: every chat's lorebooks.
  Future<void> _setGlobal(WidgetRef ref, List<String> global, String id, bool on) async {
    final ids = [
      for (final b in global)
        if (b != id) b,
      if (on) id,
    ];
    await ref.read(tavernProvider).bindLorebooks(ids);
    ref.invalidate(tavernLorebooksProvider);
  }

  Future<void> _export(WidgetRef ref, TavernLorebookSummary book) async {
    final text = await ref.read(tavernProvider).exportLorebook(book.id);
    final bytes = Uint8List.fromList(utf8.encode(text));
    await ref.read(tavernChatSinkProvider)([TavernChatFile(fileName: '${book.name}.json', bytes: bytes)]);
  }

  Future<void> _delete(BuildContext context, WidgetRef ref, List<String> global, TavernLorebookSummary book) async {
    final l10n = context.l10n;
    final ok = await confirmTavernDelete(
      context,
      title: l10n.tavernLorebookDeleteTitle(book.name),
      message: l10n.tavernLorebookDeleteMessage,
    );
    if (!ok) return;
    final tavern = ref.read(tavernProvider);
    // Out of every chat first, then gone.
    if (global.contains(book.id)) {
      await tavern.bindLorebooks([
        for (final b in global)
          if (b != book.id) b,
      ]);
    }
    await tavern.deleteLorebook(book.id);
    ref.invalidate(tavernLorebooksProvider);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final library = ref.watch(tavernLorebooksProvider).value;
    return AppPage.list(
      title: l10n.tavernLorebooks,
      actions: [
        GlassIconButton(
          key: const ValueKey('tavern-lorebook-import'),
          icon: AppIcons.add,
          tooltip: l10n.tavernLorebookImport,
          onPressed: () => unawaited(_import(context, ref)),
        ),
      ],
      children: [
        if (library == null)
          const QuietSpinner()
        else if (library.books.isEmpty)
          Padding(
            key: const ValueKey('tavern-lorebooks-empty'),
            padding: const EdgeInsets.fromLTRB(28, 8, 28, 16),
            child: Text(
              '${l10n.tavernLorebooksEmpty}。${l10n.tavernLorebooksEmptyMessage}',
              style: theme.textTheme.bodySmall?.copyWith(color: DshColors.of(context).textTertiary, height: 1.5),
            ),
          )
        else
          SheetGroup(
            margin: const EdgeInsets.fromLTRB(16, 0, 16, 24),
            children: [
              for (final book in library.books)
                () {
                  final global = library.global.contains(book.id);
                  return SettingsTile(
                    key: ValueKey('tavern-lorebook-${book.id}'),
                    icon: AppIcons.lorebook,
                    tinted: false,
                    title: book.name,
                    subtitle: l10n.tavernLorebookEntries(book.entryCount),
                    value: Text(global ? l10n.tavernLorebookGlobal : ''),
                    onTap: () => unawaited(
                      showTavernActions(context, [
                        (
                          global ? AppIcons.remove : AppIcons.selected,
                          global ? l10n.tavernLorebookUnbindGlobal : l10n.tavernLorebookBindGlobal,
                          () => unawaited(_setGlobal(ref, library.global, book.id, !global)),
                        ),
                        (AppIcons.share, l10n.tavernLorebookExport, () => unawaited(_export(ref, book))),
                        (
                          AppIcons.delete,
                          l10n.tavernLorebookDelete,
                          () => unawaited(_delete(context, ref, library.global, book)),
                        ),
                      ]),
                    ),
                  );
                }(),
            ],
          ),
      ],
    );
  }
}
