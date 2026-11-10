// 舞台: the chat's side panel (docs/design/roleplay-ui.md §2 layer 4, §8;
// roleplay-agent.md §2–3). Three pages: 状态 (the card's state: relations,
// numbers, things, the time and place), 导演 (the director's notes and next
// beat) and 本回合 (what went into this turn: lorebook entries, tokens, the
// cache). The first two wait on the engine (T17, T18) and say what they will
// hold; 本回合 reads the turn's record now.

import 'dart:async';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../tavern/tavern_provider.dart';
import '../features/feature_kit.dart' show QuietSpinner;
import '../settings/settings_widgets.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'tavern_inspector_page.dart';

enum TavernStageTab { state, director, turn }

class TavernStagePanel extends ConsumerStatefulWidget {
  const TavernStagePanel({super.key, required this.chatId, this.turn, this.topInset = 0});

  final String chatId;

  /// The newest message's node: a new one means a new turn to read.
  final String? turn;

  /// Clear of the chat's header when the panel stands beside the chat.
  final double topInset;

  @override
  ConsumerState<TavernStagePanel> createState() => _TavernStagePanelState();
}

class _TavernStagePanelState extends ConsumerState<TavernStagePanel> {
  /// 本回合 first: it has something in it today.
  TavernStageTab _tab = TavernStageTab.turn;
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
            PillSegment(TavernStageTab.state, l10n.tavernStageState),
            PillSegment(TavernStageTab.director, l10n.tavernStageDirector),
            PillSegment(TavernStageTab.turn, l10n.tavernStageTurn),
          ],
          selected: _tab,
          onChanged: (tab) => setState(() => _tab = tab),
        ),
        const SizedBox(height: 16),
        switch (_tab) {
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
