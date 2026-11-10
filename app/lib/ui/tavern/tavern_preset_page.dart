// 资源库 › 预设 › one preset (docs/design/roleplay-roadmap.md P0, engine T20):
// its numbers (context, reply length, temperature), its prefill (the text a
// reply starts from, and whether it goes in the reply or the thinking), and
// its prompts in the order they are sent: each opened to edit its text,
// switched on or off, the order changed by dragging, as the engine edits them.

import 'dart:async';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../tavern/tavern_generation.dart';
import '../../tavern/tavern_provider.dart';
import '../common/app_sheet.dart';
import '../common/brief_notice.dart';
import '../common/list_page_row.dart';
import '../common/sheet_title_bar.dart';
import '../features/feature_kit.dart';
import '../settings/settings_widgets.dart';
import '../shell/page_frame.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'tavern_message_edit_page.dart';
import 'tavern_presets_page.dart';

/// One preset, as it is now; again when the library changes.
final tavernPresetProvider = FutureProvider.autoDispose.family<TavernPreset?, String>((ref, id) {
  ref.watch(tavernPresetsProvider);
  return ref.watch(tavernProvider).preset(id);
});

/// A prompt as the order sends it; [content] is null for a placeholder.
typedef TavernPresetPrompt = ({String id, String name, bool marker, bool enabled, String? content});

/// [raw]'s prompts in the order they are sent: the 100001 group's order, else
/// the first group with one, as the engine picks it.
List<TavernPresetPrompt> tavernPresetPrompts(Map<String, Object?> raw) {
  final prompts = {
    for (final p in ((raw['prompts'] as List?) ?? const []).whereType<Map<String, Object?>>()) '${p['identifier']}': p,
  };
  final groups = ((raw['prompt_order'] as List?) ?? const []).whereType<Map<String, Object?>>().toList();
  bool hasOrder(Map<String, Object?> g) => ((g['order'] as List?) ?? const []).isNotEmpty;
  final group =
      groups.where((g) => '${g['character_id']}' == '100001' && hasOrder(g)).firstOrNull ??
      groups.where(hasOrder).firstOrNull;
  return [
    for (final entry in ((group?['order'] as List?) ?? const []).whereType<Map<String, Object?>>())
      if (entry['identifier'] case final Object id)
        (
          id: '$id',
          name: '${prompts['$id']?['name'] ?? id}',
          marker: prompts['$id']?['marker'] == true,
          enabled: entry['enabled'] != false,
          content: prompts['$id']?['marker'] == true ? null : _contentOf(raw, prompts['$id'], '$id'),
        ),
  ];
}

/// A prompt's text: its own, else the legacy top-level field ST keeps for the
/// three classic prompts.
String _contentOf(Map<String, Object?> raw, Map<String, Object?>? prompt, String id) => switch (prompt?['content']) {
  final String text => text,
  _ => switch (raw['${id}_prompt']) {
    final String text when const ['main', 'nsfw', 'jailbreak'].contains(id) => text,
    _ => '',
  },
};

class TavernPresetPage extends ConsumerWidget {
  const TavernPresetPage({super.key, required this.presetId});

  final String presetId;

  static Route<void> route(String presetId) =>
      MaterialPageRoute<void>(builder: (_) => TavernPresetPage(presetId: presetId));

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final preset = ref.watch(tavernPresetProvider(presetId)).value;
    final tavern = ref.read(tavernProvider);
    if (preset == null) return AppPage.list(title: l10n.tavernPresets, children: const [QuietSpinner()]);
    final raw = preset.raw;
    final numbers = TavernGeneration.of(raw);
    final prompts = tavernPresetPrompts(raw);
    void set(String key, Object value) => unawaited(tavern.updatePreset(presetId, {key: value}));
    // The prefill (engine T20): extensions.dshgo.prefill's switch and target,
    // and ST's own assistant_prefill text.
    final prefill = switch (raw['extensions']) {
      {'dshgo': {'prefill': final Map<String, Object?> p}} => p,
      _ => const <String, Object?>{},
    };
    final prefillText = switch (raw['assistant_prefill']) {
      final String text => text,
      _ => '',
    };
    void setPrefill(Map<String, Object?> patch) => unawaited(
      tavern.updatePreset(presetId, {
        'extensions': {
          'dshgo': {'prefill': patch},
        },
      }),
    );
    Future<void> editPrompt(TavernPresetPrompt prompt) async {
      final text = await Navigator.of(context)
          .push(TavernMessageEditPage.route(speaker: preset.name, text: prompt.content ?? '', title: prompt.name));
      if (text != null) await tavern.updatePresetPrompt(presetId, prompt.id, {'content': text});
    }

    Future<void> editPrefill() async {
      final text = await Navigator.of(context)
          .push(TavernMessageEditPage.route(speaker: preset.name, text: prefillText, title: l10n.tavernPrefill));
      if (text != null) await tavern.updatePreset(presetId, {'assistant_prefill': text});
    }

    final theme = Theme.of(context);
    final quiet = theme.textTheme.bodySmall?.copyWith(color: DshColors.of(context).textTertiary, height: 1.5);
    return AppPage.list(
      title: preset.name,
      children: [
        SheetGroup(
          key: const ValueKey('tavern-preset-numbers'),
          title: l10n.tavernPresetParams,
          margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          children: [
            SettingsSegmentTile<int>(
              key: const ValueKey('tavern-preset-context'),
              icon: AppIcons.tavernContext,
              title: l10n.tavernMaxContext,
              segments: [for (final t in tavernContextSizes) PillSegment(t, '${(t + 1) ~/ 1024}K')],
              selected: numbers.maxContext,
              onChanged: (t) => set(TavernGenerationController.contextKey, t),
            ),
            SettingsSegmentTile<int>(
              key: const ValueKey('tavern-preset-reply'),
              icon: AppIcons.tavernReplyLength,
              title: l10n.tavernMaxReply,
              segments: [for (final t in tavernReplySizes) PillSegment(t, '$t')],
              selected: numbers.maxReply,
              onChanged: (t) => set(TavernGenerationController.replyKey, t),
            ),
            SettingsSegmentTile<double>(
              key: const ValueKey('tavern-preset-temperature'),
              icon: AppIcons.tavernTemperature,
              title: l10n.tavernTemperature,
              segments: [for (final t in tavernTemperatures) PillSegment(t, t.toStringAsFixed(1))],
              selected: numbers.temperature,
              onChanged: (t) => set(TavernGenerationController.temperatureKey, t),
            ),
          ],
        ),
        SheetGroup(
          key: const ValueKey('tavern-preset-prefill-group'),
          title: l10n.tavernPrefill,
          margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          children: [
            SettingsSwitchTile(
              key: const ValueKey('tavern-preset-prefill'),
              title: l10n.tavernPrefillOn,
              subtitle: l10n.tavernPrefillOnSubtitle,
              value: prefill['enabled'] == true,
              onChanged: (on) => setPrefill({'enabled': on}),
            ),
            SettingsTile(
              key: const ValueKey('tavern-preset-prefill-text'),
              icon: AppIcons.edit,
              tinted: false,
              title: l10n.tavernPrefillText,
              subtitle: prefillText.trim().isEmpty ? l10n.tavernPrefillTextEmpty : _line(prefillText),
              onTap: () => unawaited(editPrefill()),
            ),
            SettingsSegmentTile<bool>(
              key: const ValueKey('tavern-preset-prefill-target'),
              title: l10n.tavernPrefillTarget,
              segments: [PillSegment(false, l10n.tavernPrefillContent), PillSegment(true, l10n.tavernPrefillReasoning)],
              selected: prefill['target'] == 'reasoning',
              onChanged: (reasoning) => setPrefill({'target': reasoning ? 'reasoning' : 'content'}),
            ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(32, 0, 32, 16),
          child: Text(l10n.tavernPrefillNote, style: quiet),
        ),
        SheetGroup(
          key: const ValueKey('tavern-preset-prompts'),
          title: l10n.tavernPresetPrompts,
          margin: const EdgeInsets.fromLTRB(16, 0, 16, 24),
          children: [
            if (prompts.isEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                child: Text(l10n.tavernPresetPromptsEmpty, style: quiet),
              ),
            for (final prompt in prompts)
              if (prompt.content case final content?)
                // A prompt with text: the row opens it, the switch turns it on or off.
                MergeSemantics(
                  key: ValueKey('tavern-preset-prompt-${prompt.id}'),
                  child: SettingsTile(
                    title: prompt.name,
                    subtitle: content.trim().isEmpty ? l10n.tavernPresetPromptEmpty : _line(content),
                    onTap: () => unawaited(editPrompt(prompt)),
                    trailing: Switch(
                      value: prompt.enabled,
                      onChanged: (on) => unawaited(tavern.setPresetPromptEnabled(presetId, prompt.id, on)),
                    ),
                  ),
                )
              else
                SettingsSwitchTile(
                  key: ValueKey('tavern-preset-prompt-${prompt.id}'),
                  title: prompt.name,
                  subtitle: l10n.tavernPresetMarker,
                  value: prompt.enabled,
                  onChanged: (on) => unawaited(tavern.setPresetPromptEnabled(presetId, prompt.id, on)),
                ),
            if (prompts.length > 1)
              SettingsTile(
                key: const ValueKey('tavern-preset-order'),
                icon: AppIcons.dragHandle,
                tinted: false,
                title: l10n.tavernPresetOrder,
                onTap: () => unawaited(showTavernPresetOrder(context, presetId, prompts)),
              ),
          ],
        ),
      ],
    );
  }
}

/// [text] as one short line: its first line, cut at about 40 characters.
String _line(String text) {
  final first = text.trim().split('\n').first.trim();
  return first.length > 40 ? '${first.substring(0, 40)}…' : first;
}

/// [prompts] in order, each with a handle to drag it; every drop is saved
/// as the whole order at once.
Future<void> showTavernPresetOrder(BuildContext context, String presetId, List<TavernPresetPrompt> prompts) =>
    showAppSheet<void>(
      context,
      isScrollControlled: true,
      builder: (_) => _PresetOrderSheet(presetId: presetId, prompts: prompts),
    );

class _PresetOrderSheet extends ConsumerStatefulWidget {
  const _PresetOrderSheet({required this.presetId, required this.prompts});

  final String presetId;
  final List<TavernPresetPrompt> prompts;

  @override
  ConsumerState<_PresetOrderSheet> createState() => _PresetOrderSheetState();
}

class _PresetOrderSheetState extends ConsumerState<_PresetOrderSheet> {
  late final List<TavernPresetPrompt> _rows = [...widget.prompts];

  /// Saves run one after another, each with the whole order as it then was.
  Future<void> _saving = Future.value();

  void _move(int from, int to) {
    setState(() {
      final moved = _rows.removeAt(from);
      _rows.insert(to.clamp(0, _rows.length), moved);
    });
    final ids = [for (final p in _rows) p.id];
    final tavern = ref.read(tavernProvider);
    final messenger = ScaffoldMessenger.maybeOf(context);
    final failed = context.l10n.commonSaveFailed;
    _saving = _saving.then((_) async {
      try {
        await tavern.setPresetOrder(widget.presetId, ids);
      } on Object {
        messenger?.showBriefNotice(failed);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    final colors = DshColors.of(context);
    Widget row(TavernPresetPrompt prompt, int index) => ListPageRow(
      key: ValueKey('tavern-preset-order-${prompt.id}'),
      title: prompt.name,
      subtitle: !prompt.enabled
          ? l10n.tavernPresetPromptOff
          : prompt.marker
          ? l10n.tavernPresetMarker
          : null,
      trailing: ReorderableDragStartListener(
        index: index,
        child: Semantics(
          label: l10n.shellDragToReorder,
          child: SizedBox.square(dimension: 32, child: Icon(AppIcons.dragHandle, size: 20, color: colors.textTertiary)),
        ),
      ),
    );

    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SheetTitleBar(l10n.tavernPresetOrder),
            Padding(
              padding: const EdgeInsets.fromLTRB(SheetTitleBar.inset + 12, 0, SheetTitleBar.inset + 12, 6),
              child: Text(
                l10n.tavernPresetOrderNote,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(color: colors.textTertiary, height: 1.5),
              ),
            ),
            Flexible(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(kSheetGutter, 6, kSheetGutter, 6),
                child: GlassSurface(
                  tier: GlassTier.card,
                  borderRadius: AppShape.radiusLg,
                  child: Material(
                    type: MaterialType.transparency,
                    clipBehavior: Clip.antiAlias,
                    shape: const RoundedSuperellipseBorder(borderRadius: AppShape.radiusLg),
                    child: ReorderableListView.builder(
                      key: const ValueKey('tavern-preset-order-list'),
                      shrinkWrap: true,
                      buildDefaultDragHandles: false,
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      itemCount: _rows.length,
                      // The lifted row keeps its glass look, a touch raised.
                      proxyDecorator: (child, _, animation) => AnimatedBuilder(
                        animation: animation,
                        builder: (context, child) => Material(
                          color: scheme.surface.withValues(alpha: 0.92),
                          elevation: 6 * animation.value,
                          shadowColor: Colors.black26,
                          shape: Squircle.border(AppShape.md),
                          clipBehavior: Clip.antiAlias,
                          child: child,
                        ),
                        child: child,
                      ),
                      onReorderItem: _move,
                      itemBuilder: (context, i) => row(_rows[i], i),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 4),
          ],
        ),
      ),
    );
  }
}
