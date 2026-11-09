// 世界书 (read-only for now): the entries a card carries in its V3
// character_book. Each shows its name, the keys that bring it into the
// prompt, and whether it is always on or switched off; a tap opens its text.
// Read through Tavern.characterFields, so nothing here changes the card.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../tavern/tavern_provider.dart';
import '../common/smooth_size.dart';
import '../features/feature_kit.dart';
import '../settings/settings_widgets.dart';
import '../shell/page_frame.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';

class TavernLorebookPage extends ConsumerStatefulWidget {
  const TavernLorebookPage({super.key, required this.characterId});

  final String characterId;

  static Route<void> route(String characterId) =>
      MaterialPageRoute<void>(builder: (_) => TavernLorebookPage(characterId: characterId));

  @override
  ConsumerState<TavernLorebookPage> createState() => _TavernLorebookPageState();
}

class _TavernLorebookPageState extends ConsumerState<TavernLorebookPage> {
  late final Future<Map<String, Object?>?> _fields = ref.read(tavernProvider).characterFields(widget.characterId);

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return FutureBuilder<Map<String, Object?>?>(
      future: _fields,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return AppPage.list(title: l10n.tavernLorebook, children: const [QuietSpinner()]);
        }
        final book = snapshot.data?['character_book'];
        final entries = [
          if (book is Map && book['entries'] is List)
            for (final e in book['entries'] as List)
              if (e is Map) e,
        ]..sort((a, b) => _order(b).compareTo(_order(a)));
        final name = book is Map && book['name'] is String && (book['name'] as String).isNotEmpty
            ? book['name'] as String
            : l10n.tavernLorebook;
        if (entries.isEmpty) {
          return AppPage.list(
            title: l10n.tavernLorebook,
            children: [EmptyView(icon: AppIcons.lorebook, title: l10n.tavernLorebookEmpty)],
          );
        }
        return AppPage.list(
          title: name,
          children: [
            SettingsSection(
              title: l10n.tavernLorebookEntries(entries.length),
              footer: Text(l10n.tavernLorebookNote),
              children: [for (final (i, e) in entries.indexed) _EntryTile(key: ValueKey('tavern-lore-$i'), entry: e)],
            ),
          ],
        );
      },
    );
  }

  /// Higher insertion_order first, as ST lists them.
  static num _order(Map<Object?, Object?> e) => switch (e['insertion_order']) {
    final num n => n,
    _ => 0,
  };
}

class _EntryTile extends StatefulWidget {
  const _EntryTile({super.key, required this.entry});

  final Map<Object?, Object?> entry;

  @override
  State<_EntryTile> createState() => _EntryTileState();
}

class _EntryTileState extends State<_EntryTile> {
  bool _open = false;

  List<String> _strings(Object? v) => [
    if (v is List)
      for (final s in v)
        if (s is String && s.isNotEmpty) s,
  ];

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final dsh = DshColors.of(context);
    final e = widget.entry;
    final keys = _strings(e['keys']);
    final comment = e['comment'] is String ? (e['comment'] as String).trim() : '';
    final title = comment.isNotEmpty ? comment : (keys.isNotEmpty ? keys.first : '—');
    final content = e['content'] is String ? e['content'] as String : '';
    final constant = e['constant'] == true;
    final off = e['enabled'] == false;
    Widget badge(String text, Color color) => Container(
      margin: const EdgeInsets.only(left: 6),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(99)),
      child: Text(text, style: theme.textTheme.labelSmall?.copyWith(color: color)),
    );
    return InkWell(
      onTap: () => setState(() => _open = !_open),
      splashFactory: rowSplash(context),
      child: Opacity(
        opacity: off ? 0.5 : 1,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: SettingsMetrics.inset, vertical: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodyLarge),
                  ),
                  if (constant) badge(l10n.tavernLorebookConstant, theme.colorScheme.primary),
                  if (off) badge(l10n.tavernLorebookOff, dsh.textTertiary),
                ],
              ),
              if (keys.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    l10n.tavernLorebookKeys(keys.join('、')),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(color: dsh.textTertiary),
                  ),
                ),
              SmoothSize(
                duration: AppMotion.of(context, AppMotion.standard),
                curve: AppMotion.std,
                alignment: Alignment.topCenter,
                child: !_open
                    ? const SizedBox(width: double.infinity)
                    : Container(
                        width: double.infinity,
                        margin: const EdgeInsets.only(top: 8),
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.onSurface.withValues(alpha: 0.04),
                          borderRadius: BorderRadius.circular(AppShape.md),
                        ),
                        child: SelectableText(content, style: theme.textTheme.bodySmall?.copyWith(height: 1.5)),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
