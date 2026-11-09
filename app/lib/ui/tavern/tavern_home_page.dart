// 酒馆's home (docs/design/roleplay-ui.md §1): the chats to pick up again, then
// every character. Back returns to 工作; the 模式 key switches elsewhere.

import 'dart:async';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/app_mode_state.dart';
import '../../tavern/tavern_provider.dart';
import '../features/feature_kit.dart';
import '../modes/mode_switch.dart';
import '../shell/page_frame.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'tavern_character_page.dart';
import 'tavern_chat_page.dart';
import 'tavern_settings_page.dart';
import 'tavern_widgets.dart';

class TavernHomePage extends ConsumerWidget {
  const TavernHomePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final characters = ref.watch(tavernCharactersProvider);
    final chats = ref.watch(tavernChatsProvider(null)).value ?? const [];
    final list = characters.value;
    final byId = {for (final c in list ?? const <TavernCharacter>[]) c.id: c};
    return AppPage(
      title: l10n.tavernTitle,
      actions: [
        GlassIconButton(
          key: const ValueKey('tavern-import'),
          icon: AppIcons.add,
          tooltip: l10n.tavernImport,
          onPressed: () => unawaited(importTavernCard(context, ref)),
        ),
        GlassIconButton(
          key: const ValueKey('tavern-settings'),
          icon: AppIcons.settings,
          tooltip: l10n.tavernSettings,
          onPressed: () => Navigator.of(context).push(TavernSettingsPage.route()),
        ),
        const ModeKey(current: AppMode.tavern, size: 44, tier: GlassTier.chrome),
      ],
      slivers: [
        if (list == null)
          const SliverToBoxAdapter(child: QuietSpinner())
        else if (list.isEmpty)
          SliverFillRemaining(
            hasScrollBody: false,
            child: EmptyView(
              icon: AppIcons.tavern,
              title: l10n.tavernEmptyTitle,
              message: l10n.tavernEmptyMessage,
              actionLabel: l10n.tavernImport,
              onAction: () => unawaited(importTavernCard(context, ref)),
            ),
          )
        else ...[
          if (chats.isNotEmpty) ...[
            _SectionLabel(l10n.tavernContinue),
            SliverToBoxAdapter(
              child: SizedBox(
                height: 132,
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
          _SectionLabel(l10n.tavernCharacters),
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
      ],
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

/// A card in the grid: the picture at 2:3, the name, the tags.
class _CharacterTile extends StatelessWidget {
  const _CharacterTile({required this.character});

  final TavernCharacter character;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dsh = DshColors.of(context);
    return Semantics(
      button: true,
      label: character.name,
      child: GestureDetector(
        key: ValueKey('tavern-character-${character.id}'),
        onTap: () => Navigator.of(context).push(TavernCharacterPage.route(character.id)),
        behavior: HitTestBehavior.opaque,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: SizedBox(
                width: double.infinity,
                child: TavernPortrait(name: character.name, path: character.avatarPath),
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
class _ContinueCard extends StatelessWidget {
  const _ContinueCard({required this.chat, required this.character});

  final TavernChatSummary chat;
  final TavernCharacter? character;

  @override
  Widget build(BuildContext context) {
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
                  Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.titleSmall),
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
