// 舞台: the chat's side panel (docs/design/roleplay-ui.md §2 layer 4, §8;
// roleplay-agent.md §2–3; roleplay-roadmap.md §2). Four pages: 本局 (what
// this chat runs on and looks like, and where else to go from it), 状态 (the
// card's state: relations, numbers, things, the time and place), 导演 (the
// director's notes and next beat) and 本回合 (what went into this turn:
// lorebook entries, tokens, the cache). 状态 and 导演 wait on the engine (T17,
// T18) and say what they will hold.

import 'dart:async';
import 'dart:convert';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../tavern/tavern_backgrounds.dart';
import '../../tavern/tavern_card_theme.dart';
import '../../tavern/tavern_provider.dart';
import '../../tavern/tavern_session_usage.dart';
import '../../tavern/tavern_settings.dart';
import '../common/app_sheet.dart';
import '../common/brief_notice.dart';
import '../common/sheet_title_bar.dart';
import '../features/feature_kit.dart' show QuietSpinner;
import '../settings/settings_widgets.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'tavern_branches_page.dart';
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

  /// The variables saved at the current message (engine T16), read again
  /// whenever the latest message changes.
  late Future<Map<String, Object?>> _variables = _readVariables();

  Future<TavernTurnInspection?> _read() => ref.read(tavernProvider).inspectTurn(widget.chatId);

  Future<Map<String, Object?>> _readVariables() => ref.read(tavernProvider).readVariables(widget.chatId);

  /// The current line's replies added up (本局用量), read again each turn.
  late Future<TavernSessionUsage> _usage = tavernSessionUsage(ref.read(tavernProvider), widget.chatId);

  @override
  void didUpdateWidget(TavernStagePanel old) {
    super.didUpdateWidget(old);
    if (old.turn != widget.turn || old.chatId != widget.chatId) {
      _record = _read();
      _variables = _readVariables();
      _usage = tavernSessionUsage(ref.read(tavernProvider), widget.chatId);
    }
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
            usage: _usage,
            chatId: widget.chatId,
            characterId: widget.characterId,
            name: widget.name,
            busy: widget.busy,
          ),
          // Until a card defines its state (engine T17), what its macros saved.
          TavernStageTab.state => FutureBuilder<Map<String, Object?>>(
            future: _variables,
            builder: (context, snapshot) => switch (snapshot.data) {
              final variables? when variables.isNotEmpty => _Variables(
                key: const ValueKey('tavern-stage-variables'),
                variables: variables,
              ),
              _ => _Waiting(
                key: const ValueKey('tavern-stage-state'),
                icon: AppIcons.chart,
                title: l10n.tavernStageStateEmpty,
                message: l10n.tavernStageStateNote,
              ),
            },
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
  const _Session({
    super.key,
    required this.usage,
    required this.chatId,
    required this.characterId,
    required this.name,
    required this.busy,
  });

  final Future<TavernSessionUsage> usage;
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
        FutureBuilder<TavernSessionUsage>(
          future: usage,
          builder: (context, snapshot) => switch (snapshot.data) {
            final usage? => _SessionUsageView(usage: usage),
            null => const SizedBox.shrink(),
          },
        ),
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
              selected: own ?? ref.watch(tavernCardThemeProvider(characterId))?.layout ?? settings.layout,
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
              key: const ValueKey('tavern-chat-branches'),
              icon: AppIcons.fork,
              tinted: false,
              title: l10n.tavernBranches,
              onTap: () => open(TavernBranchesPage.route(chatId)),
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
/// The variables a chat's macros saved ({{setvar}} and the like), as of the
/// current message, read-only; a tap shows one whole.
class _Variables extends StatelessWidget {
  const _Variables({super.key, required this.variables});

  final Map<String, Object?> variables;

  /// [value] on a line: text as written, the rest as compact JSON.
  static String _line(Object? value) => switch (value) {
    final String text => text,
    null => 'null',
    _ => jsonEncode(value),
  };

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final keys = variables.keys.toList()..sort();
    return SettingsSection(
      title: l10n.tavernStateVariables,
      footer: Text(l10n.tavernStateVariablesNote),
      margin: EdgeInsets.zero,
      children: [
        for (final key in keys)
          InkWell(
            key: ValueKey('tavern-variable-$key'),
            onTap: () => unawaited(_open(context, key, variables[key])),
            splashFactory: rowSplash(context),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: SettingsMetrics.inset, vertical: 10),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 120),
                    child: Text(key, style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      _line(variables[key]),
                      textAlign: TextAlign.end,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurface.withValues(alpha: 0.72),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  Future<void> _open(BuildContext context, String key, Object? value) => showAppSheet<void>(
    context,
    isScrollControlled: true,
    builder: (sheet) => SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(sheet).height * 0.7),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SheetTitleBar(key),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(SheetTitleBar.inset + 12, 0, SheetTitleBar.inset + 12, 16),
                child: SelectableText(
                  value is String ? value : const JsonEncoder.withIndent('  ').convert(value),
                  key: const ValueKey('tavern-variable-whole'),
                  style: Theme.of(sheet).textTheme.bodySmall?.copyWith(fontFamily: 'monospace', height: 1.5),
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

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
/// 本局用量: what the current line's replies took, added up.
class _SessionUsageView extends StatelessWidget {
  const _SessionUsageView({required this.usage});

  final TavernSessionUsage usage;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final quiet = theme.textTheme.bodySmall?.copyWith(color: DshColors.of(context).textTertiary);
    final zh = Localizations.localeOf(context).languageCode == 'zh';
    return Padding(
      key: const ValueKey('tavern-session-usage'),
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Titled as the sections under it are.
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
            child: Semantics(
              header: true,
              child: Text(l10n.tavernSessionUsage, style: SettingsSection.titleStyle(context)),
            ),
          ),
          if (usage.replies == 0)
            Padding(
              padding: const EdgeInsets.only(left: 8),
              child: Text(l10n.tavernSessionUsageNone, style: quiet),
            )
          else ...[
            Row(
              children: [
                _Figure(
                  label: l10n.tavernStageTokensIn,
                  value: tavernTokenCount(usage.prompt, zh: zh),
                ),
                const SizedBox(width: 8),
                _Figure(
                  label: l10n.tavernStageCache,
                  value: usage.prompt == 0 ? '—' : '${(100 * usage.cacheHit / usage.prompt).round()}%',
                ),
                const SizedBox(width: 8),
                _Figure(
                  label: l10n.tavernStageTokensOut,
                  value: tavernTokenCount(usage.completion, zh: zh),
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.only(left: 8, top: 6),
              child: Text(l10n.tavernSessionUsageNote(usage.replies), style: quiet),
            ),
          ],
        ],
      ),
    );
  }
}

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
