// 酒馆's home (docs/design/roleplay-ui.md §1, roleplay-roadmap.md §4), in four
// sections: 书架 (the chats to pick up again, then every character), 对话
// (every chat, newest first), 资源库 (what a story is built with) and 我的
// (酒馆设置). Back returns to 工作; the 模式 key switches elsewhere.

import 'dart:async';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/app_mode_state.dart';
import '../../tavern/tavern_provider.dart';
import '../../tavern/tavern_shelf.dart';
import '../../tavern/tavern_quick_replies.dart';
import '../bots/bot_format.dart' show shortTime;
import '../common/app_sheet.dart';
import '../common/capsule_chip.dart';
import '../common/search_capsule.dart';
import '../features/feature_kit.dart';
import '../modes/mode_switch.dart';
import '../settings/settings_widgets.dart';
import '../shell/page_frame.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'tavern_character_edit_page.dart';
import 'tavern_character_page.dart';
import 'tavern_chat_page.dart';
import 'tavern_lorebooks_page.dart';
import 'tavern_personas.dart';
import 'tavern_presets_page.dart';
import 'tavern_regex_page.dart';
import 'tavern_quick_replies_page.dart';
import 'tavern_settings_page.dart';
import 'tavern_widgets.dart';

/// The home's four sections.
enum TavernSection { shelf, chats, library, me }

class TavernHomePage extends ConsumerStatefulWidget {
  const TavernHomePage({super.key});

  /// From this many characters on, the home offers search and tag filters.
  @visibleForTesting
  static int searchFrom = 6;

  @override
  ConsumerState<TavernHomePage> createState() => _TavernHomePageState();
}

class _TavernHomePageState extends ConsumerState<TavernHomePage> {
  final _search = TextEditingController();
  String _query = '';
  String? _tag;
  var _section = TavernSection.shelf;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  /// 导入 (a file or a link), then the card's page.
  Future<void> _import() async {
    final navigator = Navigator.of(context);
    final character = await showTavernImport(context, ref);
    if (character != null && mounted) unawaited(navigator.push(TavernCharacterPage.route(character.id)));
  }

  /// Imports the sample card and opens it, as an imported card would be.
  Future<void> _trySample() async {
    final navigator = Navigator.of(context);
    final character = await importSampleTavernCard(context, ref);
    if (character != null && mounted) unawaited(navigator.push(TavernCharacterPage.route(character.id)));
  }

  bool _matches(TavernCharacter c) {
    if (_tag != null && !c.tags.contains(_tag)) return false;
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return true;
    return [c.name, ?c.nickname, ?c.creator, ...c.tags].any((field) => field.toLowerCase().contains(q));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final characters = ref.watch(tavernCharactersProvider);
    final chats = ref.watch(tavernChatsProvider(null)).value ?? const [];
    final byId = {for (final c in characters.value ?? const <TavernCharacter>[]) c.id: c};
    return AppPage(
      title: l10n.tavernTitle,
      actions: [
        GlassIconButton(
          key: const ValueKey('tavern-import'),
          icon: AppIcons.add,
          tooltip: l10n.tavernImport,
          onPressed: () => unawaited(_import()),
        ),
        const ModeKey(current: AppMode.tavern, size: 44, tier: GlassTier.chrome),
      ],
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: SegmentedPill<TavernSection>(
              key: const ValueKey('tavern-sections'),
              expand: true,
              segments: [
                PillSegment(TavernSection.shelf, l10n.tavernSectionShelf),
                PillSegment(TavernSection.chats, l10n.tavernSectionChats),
                PillSegment(TavernSection.library, l10n.tavernSectionLibrary),
                PillSegment(TavernSection.me, l10n.tavernSectionMe),
              ],
              selected: _section,
              onChanged: (section) => setState(() => _section = section),
            ),
          ),
        ),
        ...switch (_section) {
          TavernSection.shelf => _shelf(characters, chats, byId),
          TavernSection.chats => _chats(chats, byId),
          TavernSection.library => [_library()],
          // 酒馆设置, right here.
          TavernSection.me => [
            SliverPadding(
              key: const ValueKey('tavern-me'),
              padding: const EdgeInsets.only(bottom: 24),
              sliver: SliverList.list(children: tavernSettingsGroups(context, ref)),
            ),
          ],
        },
      ],
    );
  }

  /// 书架: the chats to pick up again, then every character.
  List<Widget> _shelf(
    AsyncValue<List<TavernCharacter>> characters,
    List<TavernChatSummary> chats,
    Map<String, TavernCharacter> byId,
  ) {
    final l10n = context.l10n;
    final all = characters.value;
    final searchable = (all?.length ?? 0) >= TavernHomePage.searchFrom;
    final filtering = _tag != null || _query.trim().isNotEmpty;
    final shelf = ref.watch(tavernShelfProvider);
    final list = all == null ? null : tavernShelfSort(all.where(_matches).toList(), shelf);
    final tags = _topTags(all ?? const []);
    return [
      // The engine could not open its folder or database: say so, and let
      // a retry open it afresh rather than spin forever.
      if (list == null && characters.hasError)
        SliverFillRemaining(
          hasScrollBody: false,
          child: EmptyView(
            key: const ValueKey('tavern-open-failed'),
            icon: AppIcons.error,
            title: l10n.tavernOpenFailed,
            message: l10n.tavernOpenFailedMessage,
            actionLabel: l10n.commonRetry,
            onAction: () => ref.invalidate(tavernProvider),
          ),
        )
      else if (list == null)
        const SliverToBoxAdapter(child: QuietSpinner())
      else if (all!.isEmpty)
        SliverFillRemaining(
          hasScrollBody: false,
          child: EmptyView(
            icon: AppIcons.tavern,
            title: l10n.tavernEmptyTitle,
            message: l10n.tavernEmptyMessage,
            action: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                OutlinedButton(
                  key: const ValueKey('tavern-empty-import'),
                  onPressed: () => unawaited(_import()),
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(0, 44),
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                  ),
                  child: Text(l10n.tavernImport),
                ),
                const SizedBox(height: 8),
                // A card to start from before you have your own.
                TextButton(
                  key: const ValueKey('tavern-try-sample'),
                  onPressed: () => unawaited(_trySample()),
                  child: Text(l10n.tavernTrySample),
                ),
              ],
            ),
          ),
        )
      else ...[
        if (searchable)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SearchCapsule(
                    key: const ValueKey('tavern-search'),
                    controller: _search,
                    hint: l10n.tavernSearchHint,
                    onChanged: (q) => setState(() => _query = q),
                    onClear: () => setState(() {
                      _search.clear();
                      _query = '';
                    }),
                  ),
                  if (tags.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
                          for (final tag in [null, ...tags]) ...[
                            CapsuleChoiceChip(
                              label: tag ?? l10n.tavernAllTags,
                              selected: _tag == tag,
                              onSelected: () => setState(() => _tag = tag),
                            ),
                            const SizedBox(width: 8),
                          ],
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        if (chats.isNotEmpty && !filtering) ...[
          _SectionLabel(l10n.tavernContinue),
          SliverToBoxAdapter(
            child: SizedBox(
              // The card's text grows with the system's; its padding doesn't.
              height: MediaQuery.textScalerOf(context).scale(108) + 24,
              child: ListView.separated(
                key: const ValueKey('tavern-continue'),
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                itemCount: chats.length.clamp(0, 8),
                separatorBuilder: (_, _) => const SizedBox(width: 10),
                itemBuilder: (context, i) => _ContinueCard(chat: chats[i], character: byId[chats[i].characterId]),
              ),
            ),
          ),
        ],
        _ShelfLabel(order: shelf.order),
        if (list.isEmpty)
          SliverToBoxAdapter(
            child: EmptyView(icon: AppIcons.noResults, title: l10n.tavernNoMatch, compact: true),
          ),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
          sliver: SliverGrid.builder(
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 220,
              mainAxisSpacing: 12,
              crossAxisSpacing: 12,
              childAspectRatio: 0.62,
            ),
            itemCount: list.length,
            itemBuilder: (context, i) => _CharacterTile(character: list[i]),
          ),
        ),
      ],
    ];
  }

  /// 对话: every chat, the newest first.
  List<Widget> _chats(List<TavernChatSummary> chats, Map<String, TavernCharacter> byId) {
    final l10n = context.l10n;
    if (chats.isEmpty) {
      return [
        SliverFillRemaining(
          hasScrollBody: false,
          child: EmptyView(
            key: const ValueKey('tavern-no-chats'),
            icon: AppIcons.tavern,
            title: l10n.tavernNoChats,
            message: l10n.tavernNoChatsMessage,
          ),
        ),
      ];
    }
    return [
      SliverPadding(
        key: const ValueKey('tavern-chats'),
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
        sliver: SliverList.separated(
          itemCount: chats.length,
          separatorBuilder: (_, _) => const SizedBox(height: 10),
          itemBuilder: (context, i) => _ChatRow(chat: chats[i], character: byId[chats[i].characterId]),
        ),
      ),
    ];
  }

  /// 资源库: what stories are built with: presets, lorebooks, regex scripts,
  /// personas and quick replies (roleplay-roadmap.md §4).
  Widget _library() {
    final l10n = context.l10n;
    final persona = ref.watch(tavernPersonaSelectionProvider(null)).value?.persona;
    return SliverToBoxAdapter(
      child: SheetGroup(
        key: const ValueKey('tavern-library'),
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        children: [
          SettingsTile(
            key: const ValueKey('tavern-library-presets'),
            icon: AppIcons.article,
            title: l10n.tavernPresets,
            value: Text(switch (ref.watch(tavernPresetsProvider).value?.length ?? 0) {
              0 => l10n.tavernPersonaNotSet,
              final n => l10n.tavernPresetCount(n),
            }),
            onTap: () => unawaited(Navigator.of(context).push(TavernPresetsPage.route())),
          ),
          SettingsTile(
            key: const ValueKey('tavern-library-lorebooks'),
            icon: AppIcons.lorebook,
            title: l10n.tavernLorebooks,
            value: Text(switch (ref.watch(tavernLorebooksProvider).value?.books.length ?? 0) {
              0 => l10n.tavernPersonaNotSet,
              final n => l10n.tavernLorebookCount(n),
            }),
            onTap: () => unawaited(Navigator.of(context).push(TavernLorebooksPage.route())),
          ),
          SettingsTile(
            key: const ValueKey('tavern-library-regex'),
            icon: AppIcons.code,
            title: l10n.tavernRegex,
            value: Text(switch (ref.watch(tavernRegexProvider).value?.length ?? 0) {
              0 => l10n.tavernPersonaNotSet,
              final n => l10n.tavernRegexCount(n),
            }),
            onTap: () => unawaited(Navigator.of(context).push(TavernRegexPage.route())),
          ),
          SettingsTile(
            key: const ValueKey('tavern-library-personas'),
            icon: AppIcons.profile,
            title: l10n.tavernDefaultPersona,
            value: Text(persona?.name ?? l10n.tavernPersonaNotSet),
            onTap: () => unawaited(Navigator.of(context).push(TavernPersonasPage.route())),
          ),
          SettingsTile(
            key: const ValueKey('tavern-library-quick-replies'),
            icon: AppIcons.reply,
            title: l10n.tavernQuickReplies,
            value: Text(switch (ref.watch(tavernQuickRepliesProvider).length) {
              0 => l10n.tavernPersonaNotSet,
              final n => l10n.tavernQuickReplyCount(n),
            }),
            onTap: () => unawaited(Navigator.of(context).push(TavernQuickRepliesPage.route())),
          ),
        ],
      ),
    );
  }
}

/// A chat in 对话: who, when, how long, and the last line on its path.
class _ChatRow extends ConsumerWidget {
  const _ChatRow({required this.chat, required this.character});

  final TavernChatSummary chat;
  final TavernCharacter? character;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final dsh = DshColors.of(context);
    final name = character?.name ?? chat.title;
    return GlassSurface(
      key: ValueKey('tavern-chat-row-${chat.id}'),
      tier: GlassTier.card,
      borderRadius: AppShape.radiusLg,
      padding: const EdgeInsets.all(12),
      onTap: () => Navigator.of(context).push(TavernChatPage.route(chat.id)),
      onLongPress: () => unawaited(
        showTavernActions(context, [
          (AppIcons.delete, context.l10n.tavernDeleteChat, () => deleteTavernChat(context, ref, chat.id)),
        ]),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 44,
            height: 44,
            child: TavernPortrait(name: name, path: character?.avatarPath, radius: AppShape.md, initialSize: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleSmall,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      '${context.l10n.tavernMessageCount(chat.messageCount)} · ${shortTime(chat.updatedAt)}',
                      style: AppType.tabular(theme.textTheme.labelSmall!.copyWith(color: dsh.textTertiary)),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  plainPreview(chat.lastText ?? ''),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(color: dsh.textTertiary, height: 1.4),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => SliverToBoxAdapter(
    child: Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 10),
      child: Text(
        text,
        style: Theme.of(context).textTheme.titleSmall?.copyWith(color: DshColors.of(context).textTertiary),
      ),
    ),
  );
}

/// 角色, and how they are ordered: a tap picks another order.
class _ShelfLabel extends ConsumerWidget {
  const _ShelfLabel({required this.order});

  final TavernShelfOrder order;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final dsh = DshColors.of(context);
    String name(TavernShelfOrder o) => switch (o) {
      TavernShelfOrder.recent => l10n.tavernShelfOrderRecent,
      TavernShelfOrder.name => l10n.tavernShelfOrderName,
      TavernShelfOrder.imported => l10n.tavernShelfOrderImported,
    };
    final shelf = ref.read(tavernShelfProvider.notifier);
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 8, 2),
        child: Row(
          children: [
            Expanded(
              child: Text(l10n.tavernCharacters, style: theme.textTheme.titleSmall?.copyWith(color: dsh.textTertiary)),
            ),
            TextButton.icon(
              key: const ValueKey('tavern-shelf-sort'),
              onPressed: () => unawaited(
                showTavernActions(context, [
                  for (final o in TavernShelfOrder.values)
                    (o == order ? AppIcons.radioOn : AppIcons.radioOff, name(o), () => unawaited(shelf.setOrder(o))),
                ]),
              ),
              iconAlignment: IconAlignment.end,
              icon: Icon(AppIcons.dropdown, size: 16, color: dsh.textTertiary),
              label: Text(
                name(order),
                semanticsLabel: '${l10n.tavernShelfSort}：${name(order)}',
                style: theme.textTheme.labelMedium?.copyWith(color: dsh.textTertiary),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A card in the grid: the picture at 2:3, the name, the tags.
class _CharacterTile extends ConsumerWidget {
  const _CharacterTile({required this.character});

  final TavernCharacter character;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final dsh = DshColors.of(context);
    final l10n = context.l10n;
    final favorite = ref.watch(tavernShelfProvider.select((s) => s.favorites.contains(character.id)));
    return Semantics(
      button: true,
      label: favorite ? '${character.name}，${l10n.tavernFavorited}' : character.name,
      child: GestureDetector(
        key: ValueKey('tavern-character-${character.id}'),
        onTap: () => Navigator.of(context).push(TavernCharacterPage.route(character.id)),
        onLongPress: () => unawaited(
          showTavernActions(context, [
            (
              favorite ? AppIcons.favoriteActive : AppIcons.favorite,
              favorite ? l10n.tavernUnfavorite : l10n.tavernFavorite,
              () => unawaited(ref.read(tavernShelfProvider.notifier).setFavorite(character.id, !favorite)),
            ),
            (
              AppIcons.edit,
              context.l10n.commonEdit,
              () => unawaited(Navigator.of(context).push(TavernCharacterEditPage.route(character.id))),
            ),
            (AppIcons.delete, context.l10n.tavernDeleteCharacter, () => deleteTavernCharacter(context, ref, character)),
          ]),
        ),
        behavior: HitTestBehavior.opaque,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  TavernPortrait(name: character.name, path: character.avatarPath),
                  if (favorite)
                    Positioned(
                      key: ValueKey('tavern-favorite-${character.id}'),
                      top: 6,
                      right: 6,
                      child: DecoratedBox(
                        decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.32), shape: BoxShape.circle),
                        child: const Padding(
                          padding: EdgeInsets.all(5),
                          child: Icon(AppIcons.favoriteActive, size: 14, color: Colors.white),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Text(character.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.titleSmall),
            Text(
              character.tags.isEmpty ? (character.creator ?? '') : character.tags.take(3).join(' · '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall?.copyWith(color: dsh.textTertiary),
            ),
          ],
        ),
      ),
    );
  }
}

/// A chat to pick up again: who, and the last line on its path.
class _ContinueCard extends ConsumerWidget {
  const _ContinueCard({required this.chat, required this.character});

  final TavernChatSummary chat;
  final TavernCharacter? character;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final dsh = DshColors.of(context);
    final name = character?.name ?? chat.title;
    return SizedBox(
      width: 236,
      child: GlassSurface(
        key: ValueKey('tavern-continue-${chat.id}'),
        tier: GlassTier.card,
        borderRadius: AppShape.radiusLg,
        padding: const EdgeInsets.all(12),
        onTap: () => Navigator.of(context).push(TavernChatPage.route(chat.id)),
        onLongPress: () => unawaited(
          showTavernActions(context, [
            (AppIcons.delete, context.l10n.tavernDeleteChat, () => deleteTavernChat(context, ref, chat.id)),
          ]),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 56,
              height: 84,
              child: TavernPortrait(name: name, path: character?.avatarPath, radius: AppShape.md, initialSize: 24),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleSmall,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        shortTime(chat.updatedAt),
                        style: AppType.tabular(theme.textTheme.labelSmall!.copyWith(color: dsh.textTertiary)),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    plainPreview(chat.lastText ?? ''),
                    maxLines: 4,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(color: dsh.textTertiary, height: 1.4),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A message as one quiet line: Markdown emphasis and tags dropped, runs of
/// white space folded.
String plainPreview(String text) =>
    text.replaceAll(RegExp(r'<[^>]*>'), '').replaceAll(RegExp(r'[*_`#>]'), '').replaceAll(RegExp(r'\s+'), ' ').trim();

/// The most used tags, most used first.
List<String> _topTags(List<TavernCharacter> characters, {int limit = 8}) {
  final counts = <String, int>{};
  for (final c in characters) {
    for (final tag in c.tags) {
      counts[tag] = (counts[tag] ?? 0) + 1;
    }
  }
  final tags = counts.keys.toList()..sort((a, b) => counts[b]!.compareTo(counts[a]!));
  return tags.take(limit).toList();
}
