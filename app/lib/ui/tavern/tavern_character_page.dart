// A character (docs/design/roleplay-ui.md §1): the picture, the greetings to
// start from, the chats so far, and what the card says about itself.

import 'dart:async';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../tavern/tavern_provider.dart';
import '../chat/render/markdown_body.dart';
import '../common/app_sheet.dart';
import '../features/feature_kit.dart';
import '../settings/settings_widgets.dart';
import '../shell/page_frame.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'tavern_chat_page.dart';
import 'tavern_home_page.dart' show plainPreview;
import 'tavern_widgets.dart';

class TavernCharacterPage extends ConsumerStatefulWidget {
  const TavernCharacterPage({super.key, required this.characterId});

  final String characterId;

  static Route<void> route(String characterId) =>
      MaterialPageRoute<void>(builder: (_) => TavernCharacterPage(characterId: characterId));

  @override
  ConsumerState<TavernCharacterPage> createState() => _TavernCharacterPageState();
}

class _TavernCharacterPageState extends ConsumerState<TavernCharacterPage> {
  final _greetings = PageController(viewportFraction: 0.9);
  int _greeting = 0;
  bool _starting = false;

  @override
  void dispose() {
    _greetings.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    if (_starting) return;
    setState(() => _starting = true);
    final navigator = Navigator.of(context);
    try {
      final id = await ref.read(tavernProvider).createChat(widget.characterId, greeting: _greeting);
      if (mounted) unawaited(navigator.push(TavernChatPage.route(id)));
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  Future<void> _delete(TavernCharacter character) async {
    final navigator = Navigator.of(context);
    if (await deleteTavernCharacter(context, ref, character) && mounted) navigator.pop();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final dsh = DshColors.of(context);
    final characters = ref.watch(tavernCharactersProvider).value;
    final character = characters?.where((c) => c.id == widget.characterId).firstOrNull;
    if (characters == null) return AppPage.list(title: l10n.tavernTitle, children: const [QuietSpinner()]);
    if (character == null) {
      return AppPage.list(
        title: l10n.tavernTitle,
        children: [EmptyView(icon: AppIcons.tavern, title: l10n.tavernCharacterGone)],
      );
    }
    final chats = ref.watch(tavernChatsProvider(character.id)).value ?? const <TavernChatSummary>[];
    final greetings = character.greetings.isEmpty ? const [''] : character.greetings;
    return AppPage(
      title: character.name,
      showLargeTitle: false,
      actions: [
        GlassIconButton(
          key: const ValueKey('tavern-character-more'),
          icon: AppIcons.more,
          tooltip: l10n.commonMore,
          onPressed: () => unawaited(_showMore(character)),
        ),
      ],
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
            child: Column(
              children: [
                SizedBox(
                  width: 168,
                  height: 252,
                  child: TavernPortrait(name: character.name, path: character.avatarPath, initialSize: 64),
                ),
                const SizedBox(height: 16),
                Text(character.name, style: theme.textTheme.headlineSmall, textAlign: TextAlign.center),
                if (character.creator != null || character.tags.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    [?character.creator, ...character.tags.take(4)].join(' · '),
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall?.copyWith(color: dsh.textTertiary),
                  ),
                ],
              ],
            ),
          ),
        ),
        SliverToBoxAdapter(
          child: Column(
            children: [
              SizedBox(
                height: 168,
                child: PageView.builder(
                  key: const ValueKey('tavern-greetings'),
                  controller: _greetings,
                  itemCount: greetings.length,
                  onPageChanged: (i) => setState(() => _greeting = i),
                  itemBuilder: (context, i) => Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: GlassSurface(
                      tier: GlassTier.card,
                      borderRadius: AppShape.radiusLg,
                      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
                      child: Text(
                        plainPreview(greetings[i]),
                        maxLines: 6,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium?.copyWith(height: 1.55),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                greetings.length > 1 ? l10n.tavernGreetingOf(_greeting + 1, greetings.length) : l10n.tavernGreeting,
                style: AppType.tabular(theme.textTheme.labelSmall!.copyWith(color: dsh.textTertiary)),
              ),
              const SizedBox(height: 16),
              FilledButton(
                key: const ValueKey('tavern-start'),
                onPressed: _starting ? null : _start,
                child: Text(l10n.tavernStart),
              ),
              const SizedBox(height: 24),
            ],
          ),
        ),
        if (chats.isNotEmpty)
          SliverToBoxAdapter(
            child: SheetGroup(
              title: l10n.tavernChats,
              margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              children: [
                for (final chat in chats)
                  GestureDetector(
                    onLongPress: () => unawaited(
                      showTavernActions(context, [
                        (AppIcons.delete, l10n.tavernDeleteChat, () => deleteTavernChat(context, ref, chat.id)),
                      ]),
                    ),
                    child: SettingsTile(
                      key: ValueKey('tavern-chat-${chat.id}'),
                      icon: AppIcons.chat,
                      tinted: false,
                      title: plainPreview(chat.lastText ?? chat.title),
                      subtitle: l10n.tavernMessageCount(chat.messageCount),
                      onTap: () => Navigator.of(context).push(TavernChatPage.route(chat.id)),
                    ),
                  ),
              ],
            ),
          ),
        if (character.description.isNotEmpty || character.creatorNotes.isNotEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (character.creatorNotes.isNotEmpty)
                    _Section(title: l10n.tavernCreatorNotes, text: character.creatorNotes),
                  if (character.description.isNotEmpty)
                    _Section(title: l10n.tavernDefinition, text: character.description),
                ],
              ),
            ),
          ),
      ],
    );
  }

  Future<void> _showMore(TavernCharacter character) => showAppSheet<void>(
    context,
    builder: (sheet) => SafeArea(
      top: false,
      child: SheetGroup(
        margin: const EdgeInsets.fromLTRB(16, 16, 16, 12),
        children: [
          SettingsTile(
            icon: AppIcons.delete,
            danger: true,
            title: context.l10n.tavernDeleteCharacter,
            onTap: () {
              Navigator.of(sheet).pop();
              unawaited(_delete(character));
            },
          ),
        ],
      ),
    ),
  );
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.text});

  final String title;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
            child: Text(title, style: theme.textTheme.titleSmall?.copyWith(color: DshColors.of(context).textTertiary)),
          ),
          GlassSurface(
            tier: GlassTier.card,
            borderRadius: AppShape.radiusLg,
            padding: const EdgeInsets.all(16),
            child: MarkdownBody(text: text),
          ),
        ],
      ),
    );
  }
}
