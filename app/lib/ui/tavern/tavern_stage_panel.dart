// 舞台: the chat's side panel (docs/design/roleplay-ui.md §2 layer 4, §8;
// roleplay-agent.md §2–3; roleplay-roadmap.md §2). Four pages: 本局 (what
// this chat runs on and looks like, and where else to go from it), 状态 (the
// card's state: relations, numbers, things, the time and place), 导演 (the
// director's notes and next beat) and 本回合 (what went into this turn:
// lorebook entries, tokens, the cache). 状态 and 导演 wait on the engine (T17,
// T18) and say what they will hold.

import 'dart:async';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../tavern/tavern_backgrounds.dart';
import '../../tavern/tavern_provider.dart';
import '../../tavern/tavern_settings.dart';
import '../common/brief_notice.dart';
import '../features/feature_kit.dart' show QuietSpinner;
import '../settings/settings_widgets.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'tavern_character_page.dart';
import 'tavern_chat_files.dart';
import 'tavern_inspector_page.dart';
import 'tavern_lorebooks_page.dart';
import 'tavern_personas.dart';
import 'tavern_presets_page.dart';
import 'tavern_search_page.dart';
import 'tavern_storybook_page.dart';

enum TavernStageTab { session, state, director, turn }

class TavernStagePanel extends ConsumerStatefulWidget {
  const TavernStagePanel({
    super.key,
    required this.chatId,
    this.turn,
    this.topInset = 0,
    this.characterId,
    this.name = '',
    this.busy = false,
  });

  final String chatId;

  /// The newest message's node: a new one means a new turn to read.
  final String? turn;

  /// Clear of the chat's header when the panel stands beside the chat.
  final double topInset;

  /// The chat's character, and the name the export and storybook go by.
  final String? characterId;
  final String name;

  /// A reply is being written: the persona waits until it is done.
  final bool busy;

  @override
  ConsumerState<TavernStagePanel> createState() => _TavernStagePanelState();
}

class _TavernStagePanelState extends ConsumerState<TavernStagePanel> {
  /// 本局 first: what is used most.
  TavernStageTab _tab = TavernStageTab.session;
  late Future<TavernTurnInspection?> _record = _read();

  Future<TavernTurnInspection?> _read() => ref.read(tavernProvider).inspectTurn(widget.chatId);

  @override
  void didUpdateWidget(TavernStagePanel old) {
    super.didUpdateWidget(old);
    if (old.turn != widget.turn || old.chatId != widget.chatId) _record = _read();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    return ListView(
      key: const ValueKey('tavern-stage'),
      padding: EdgeInsets.fromLTRB(16, widget.topInset + 16, 16, 24),
      children: [
        Text(l10n.tavernStage, style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: 12),
        SegmentedPill<TavernStageTab>(
          key: const ValueKey('tavern-stage-tabs'),
          expand: true,
          segments: [
            PillSegment(TavernStageTab.session, l10n.tavernStageSession),
            PillSegment(TavernStageTab.state, l10n.tavernStageState),
            PillSegment(TavernStageTab.director, l10n.tavernStageDirector),
            PillSegment(TavernStageTab.turn, l10n.tavernStageTurn),
          ],
          selected: _tab,
          onChanged: (tab) => setState(() => _tab = tab),
        ),
        const SizedBox(height: 16),
        switch (_tab) {
          TavernStageTab.session => _Session(
            key: const ValueKey('tavern-stage-session'),
            chatId: widget.chatId,
            characterId: widget.characterId,
            name: widget.name,
            busy: widget.busy,
          ),
          TavernStageTab.state => _Waiting(
            key: const ValueKey('tavern-stage-state'),
            icon: AppIcons.chart,
            title: l10n.tavernStageStateEmpty,
            message: l10n.tavernStageStateNote,
          ),
          TavernStageTab.director => _Waiting(
            key: const ValueKey('tavern-stage-director'),
            icon: AppIcons.lorebook,
            title: l10n.tavernStageDirectorEmpty,
            message: l10n.tavernStageDirectorNote,
          ),
          TavernStageTab.turn => FutureBuilder<TavernTurnInspection?>(
            future: _record,
            builder: (context, snapshot) {
              if (snapshot.connectionState != ConnectionState.done) {
                return const Padding(
                  padding: EdgeInsets.all(32),
                  child: Center(child: QuietSpinner()),
                );
              }
              final record = snapshot.data;
              if (snapshot.hasError || record == null) {
                return _Waiting(
                  key: const ValueKey('tavern-stage-turn-none'),
                  icon: AppIcons.code,
                  title: l10n.tavernStageTurnNone,
                  message: l10n.tavernInspectNoneMessage,
                );
              }
              return _ThisTurn(chatId: widget.chatId, record: record);
            },
          ),
        },
      ],
    );
  }
}

/// 本局: what this chat runs on, how it looks, and where else to go from it.
class _Session extends ConsumerWidget {
  const _Session({super.key, required this.chatId, required this.characterId, required this.name, required this.busy});

  final String chatId;
  final String? characterId;
  final String name;
  final bool busy;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final settings = ref.watch(tavernSettingsProvider);
    final model = ref.read(tavernSettingsProvider.notifier);
    final own = ref.watch(tavernChatLayoutProvider(chatId));
    final layout = ref.read(tavernChatLayoutProvider(chatId).notifier);
    final scene = ref.watch(tavernChatBackgroundProvider(chatId));
    final persona = ref.watch(tavernPersonaSelectionProvider(chatId)).value?.persona;
    final preset = ref.watch(tavernPresetSelectionProvider(chatId)).value;
    final presets = ref.watch(tavernPresetsProvider).value ?? const <TavernPresetSummary>[];
    final characterId = this.characterId;

    /// On a phone the panel is a drawer: close it on the way to a page.
    void open(Route<void> route) {
      Scaffold.maybeOf(context)?.closeEndDrawer();
      unawaited(Navigator.of(context).push(route));
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsSection(
          title: l10n.tavernSessionUsing,
          margin: const EdgeInsets.only(bottom: 12),
          children: [
            SettingsSegmentTile<String>(
              key: const ValueKey('tavern-session-model'),
              title: l10n.tavernSettingsModel,
              tinted: false,
              segments: [
                PillSegment(tavernModels[0], l10n.tavernModelFlash),
                PillSegment(tavernModels[1], l10n.tavernModelPro),
              ],
              selected: settings.model,
              onChanged: (value) => unawaited(model.setModel(value)),
            ),
            SettingsSwitchTile(
              key: const ValueKey('tavern-session-thinking'),
              title: l10n.tavernThinking,
              value: settings.thinking,
              onChanged: (on) => unawaited(model.setThinking(on)),
            ),
            SettingsTile(
              key: const ValueKey('tavern-chat-persona'),
              icon: AppIcons.profile,
              tinted: false,
              title: l10n.tavernPersona,
              value: Text(persona?.name ?? l10n.tavernPersonaNone),
              onTap: busy ? null : () => unawaited(showTavernPersonaPicker(context, chatId)),
            ),
            SettingsTile(
              key: const ValueKey('tavern-chat-preset'),
              icon: AppIcons.article,
              tinted: false,
              title: l10n.tavernPresets,
              // A long name stops short of the title; the picker says which the default is.
              value: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 150),
                child: Text(
                  switch (preset) {
                    null => '',
                    TavernPresetSelection(:final boundPresetId?) => tavernPresetName(context, presets, boundPresetId),
                    _ => l10n.tavernPresetFollow,
                  },
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              onTap: busy ? null : () => unawaited(showTavernPresetPicker(context, chatId)),
            ),
            TavernLorebookBindingTile(
              key: const ValueKey('tavern-chat-lorebooks'),
              scope: (source: WorldInfoSource.chat, id: chatId),
              title: l10n.tavernLorebooks,
              sheetTitle: l10n.tavernLorebookForChat,
              note: l10n.tavernLorebookChatNote,
              enabled: !busy,
            ),
          ],
        ),
        SettingsSection(
          title: l10n.tavernSessionLook,
          margin: const EdgeInsets.only(bottom: 12),
          children: [
            SettingsSegmentTile<TavernLayout>(
              key: const ValueKey('tavern-chat-layout'),
              title: l10n.tavernChatLayout,
              tinted: false,
              segments: [
                PillSegment(TavernLayout.bubble, l10n.tavernLayoutBubble),
                PillSegment(TavernLayout.novel, l10n.tavernLayoutNovel),
                PillSegment(TavernLayout.visualNovel, l10n.tavernLayoutVisualNovel),
              ],
              selected: own ?? settings.layout,
              onChanged: (value) => unawaited(layout.set(value)),
            ),
            if (own != null)
              SettingsTile(
                key: const ValueKey('tavern-chat-layout-follow'),
                icon: AppIcons.restart,
                tinted: false,
                title: l10n.tavernFollowSettings,
                onTap: () => unawaited(layout.set(null)),
              ),
            SettingsTile(
              key: const ValueKey('tavern-chat-background'),
              icon: AppIcons.addImage,
              tinted: false,
              title: l10n.tavernBackground,
              value: Text(scene == null ? l10n.tavernBackgroundNone : l10n.tavernBackgroundChange),
              onTap: () => unawaited(chooseTavernBackground(context, ref, chatId)),
            ),
            if (scene != null)
              SettingsTile(
                key: const ValueKey('tavern-chat-background-remove'),
                icon: AppIcons.remove,
                tinted: false,
                title: l10n.tavernBackgroundRemove,
                chevron: false,
                onTap: () => unawaited(ref.read(tavernChatBackgroundProvider(chatId).notifier).remove()),
              ),
          ],
        ),
        SettingsSection(
          title: l10n.tavernSessionMore,
          margin: EdgeInsets.zero,
          children: [
            if (characterId != null)
              SettingsTile(
                key: const ValueKey('tavern-character-details'),
                icon: AppIcons.info,
                tinted: false,
                title: l10n.tavernCharacterDetails,
                onTap: () => open(TavernCharacterPage.route(characterId)),
              ),
            SettingsTile(
              key: const ValueKey('tavern-chat-search'),
              icon: AppIcons.search,
              tinted: false,
              title: l10n.tavernSearchChat,
              onTap: () => open(TavernSearchPage.route(chatId)),
            ),
            SettingsTile(
              key: const ValueKey('tavern-chat-inspect'),
              icon: AppIcons.code,
              tinted: false,
              title: l10n.tavernInspectLatest,
              onTap: () => open(TavernInspectorPage.route(chatId)),
            ),
            SettingsTile(
              key: const ValueKey('tavern-chat-export'),
              icon: AppIcons.share,
              tinted: false,
              title: l10n.tavernExportChat,
              onTap: () => unawaited(exportTavernChat(context, ref, chatId, title: name)),
            ),
            SettingsTile(
              key: const ValueKey('tavern-chat-storybook'),
              icon: AppIcons.bookmark,
              tinted: false,
              title: l10n.tavernStorybookMenu,
              onTap: () => open(
                TavernStorybookPage.route(
                  chatId: chatId,
                  character: name,
                  avatarPath: ref
                      .read(tavernCharactersProvider)
                      .value
                      ?.where((c) => c.id == characterId)
                      .firstOrNull
                      ?.avatarPath,
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// A picture from the gallery under [chatId]; says so when one can't be used.
Future<void> chooseTavernBackground(BuildContext context, WidgetRef ref, String chatId) async {
  final l10n = context.l10n;
  final messenger = ScaffoldMessenger.maybeOf(context);
  final problem = await ref.read(tavernChatBackgroundProvider(chatId).notifier).choose();
  final text = switch (problem) {
    null || LaunchImportProblem.cancelled => null,
    LaunchImportProblem.unavailable => l10n.wallpaperUnavailable,
    LaunchImportProblem.tooLarge || LaunchImportProblem.overLimit => l10n.wallpaperTooLarge,
    LaunchImportProblem.unsupported => l10n.wallpaperUnsupported,
    LaunchImportProblem.unreadable => l10n.wallpaperUnreadable,
  };
  if (text != null) messenger?.showBriefNotice(text);
}

/// A page whose contents the engine doesn't give yet: what will be here.
class _Waiting extends StatelessWidget {
  const _Waiting({super.key, required this.icon, required this.title, required this.message});

  final IconData icon;
  final String title;
  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dsh = DshColors.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 24, color: dsh.textTertiary),
          const SizedBox(height: 10),
          Text(title, style: theme.textTheme.titleSmall),
          const SizedBox(height: 6),
          Text(message, style: theme.textTheme.bodySmall?.copyWith(color: dsh.textTertiary, height: 1.5)),
        ],
      ),
    );
  }
}

/// 本回合: its tokens and cache, and the lorebook entries that went in.
class _ThisTurn extends StatelessWidget {
  const _ThisTurn({required this.chatId, required this.record});

  final String chatId;
  final TavernTurnInspection record;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final usage = record.reportedUsage;
    final hits = [
      for (final hit in (record.worldInfo['activated'] as List?) ?? const [])
        if (hit is Map) hit,
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (usage == null)
          Text(
            l10n.tavernInspectNoUsage,
            key: const ValueKey('tavern-stage-no-usage'),
            style: Theme.of(context).textTheme.bodySmall?.copyWith(color: DshColors.of(context).textTertiary),
          )
        else
          Row(
            key: const ValueKey('tavern-stage-usage'),
            children: [
              _Figure(label: l10n.tavernStageTokensIn, value: '${usage.promptTokens}'),
              const SizedBox(width: 8),
              _Figure(
                label: l10n.tavernStageCache,
                value: usage.promptTokens == 0 ? '—' : '${(100 * usage.cacheHitTokens / usage.promptTokens).round()}%',
              ),
              const SizedBox(width: 8),
              _Figure(label: l10n.tavernStageTokensOut, value: '${usage.completionTokens}'),
            ],
          ),
        const SizedBox(height: 12),
        SettingsSection(
          title: l10n.tavernStageWorld,
          margin: EdgeInsets.zero,
          children: [
            if (hits.isEmpty)
              SettingsTile(key: const ValueKey('tavern-stage-world-none'), title: l10n.tavernStageWorldNone)
            else
              for (final hit in hits) TavernWorldHitTile(hit: hit),
          ],
        ),
        const SizedBox(height: 12),
        SettingsSection(
          margin: EdgeInsets.zero,
          children: [
            SettingsTile(
              key: const ValueKey('tavern-stage-inspect'),
              icon: AppIcons.code,
              tinted: false,
              title: l10n.tavernStageInspect,
              onTap: () => unawaited(Navigator.of(context).push(TavernInspectorPage.route(chatId))),
            ),
          ],
        ),
      ],
    );
  }
}

/// One number, under what it is.
class _Figure extends StatelessWidget {
  const _Figure({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Expanded(
      child: GlassSurface(
        tier: GlassTier.card,
        borderRadius: AppShape.radiusMd,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        child: Column(
          children: [
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall?.copyWith(color: DshColors.of(context).textTertiary),
            ),
            const SizedBox(height: 4),
            Text(value, style: AppType.tabular(theme.textTheme.titleMedium!.copyWith(fontWeight: FontWeight.w600))),
          ],
        ),
      ),
    );
  }
}
