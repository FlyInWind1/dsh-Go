// 资源库 › 预设 › one preset (docs/design/roleplay-roadmap.md P0, engine T20):
// its numbers (context, reply length, temperature) and its prompts in the
// order they are sent, each switched on or off, as the engine edits them.

import 'dart:async';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../tavern/tavern_generation.dart';
import '../../tavern/tavern_provider.dart';
import '../common/app_sheet.dart';
import '../features/feature_kit.dart';
import '../settings/settings_widgets.dart';
import '../shell/page_frame.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'tavern_presets_page.dart';

/// One preset, as it is now; again when the library changes.
final tavernPresetProvider = FutureProvider.autoDispose.family<TavernPreset?, String>((ref, id) {
  ref.watch(tavernPresetsProvider);
  return ref.watch(tavernProvider).preset(id);
});

/// A prompt as the order sends it.
typedef TavernPresetPrompt = ({String id, String name, bool marker, bool enabled});

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
        ),
  ];
}

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
          key: const ValueKey('tavern-preset-prompts'),
          title: l10n.tavernPresetPrompts,
          margin: const EdgeInsets.fromLTRB(16, 0, 16, 24),
          children: [
            if (prompts.isEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                child: Text(
                  l10n.tavernPresetPromptsEmpty,
                  style: Theme.of(context).textTheme.bodySmall
                      ?.copyWith(color: DshColors.of(context).textTertiary, height: 1.5),
                ),
              ),
            for (final prompt in prompts)
              SettingsSwitchTile(
                key: ValueKey('tavern-preset-prompt-${prompt.id}'),
                title: prompt.name,
                subtitle: prompt.marker ? l10n.tavernPresetMarker : null,
                value: prompt.enabled,
                onChanged: (on) => unawaited(tavern.setPresetPromptEnabled(presetId, prompt.id, on)),
              ),
          ],
        ),
      ],
    );
  }
}
