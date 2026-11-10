// 酒馆设置 (docs/design/roleplay-ui.md §1): the model, thinking, and the key
// the calls use.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/app_mode_state.dart';
import '../../state/settings_state.dart';
import '../../tavern/tavern_generation.dart';
import '../../tavern/tavern_provider.dart';
import '../../tavern/tavern_quick_replies.dart';
import '../../tavern/tavern_settings.dart';
import '../chat/render/markdown_body.dart';
import '../common/app_sheet.dart';
import '../modes/mode_switch.dart';
import '../onboarding/api_key_page.dart';
import '../settings/settings_widgets.dart';
import '../shell/page_frame.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'tavern_personas.dart';
import 'tavern_quick_replies_page.dart';
import 'tavern_reading.dart';

class TavernSettingsPage extends ConsumerWidget {
  const TavernSettingsPage({super.key});

  static Route<void> route() => MaterialPageRoute<void>(builder: (_) => const TavernSettingsPage());

  @override
  Widget build(BuildContext context, WidgetRef ref) =>
      AppPage.list(title: context.l10n.tavernSettings, children: tavernSettingsGroups(context, ref));
}

/// 酒馆设置's groups: on a page of their own, and as 我的 on the tavern's home.
List<Widget> tavernSettingsGroups(BuildContext context, WidgetRef ref) {
  final l10n = context.l10n;
  final settings = ref.watch(tavernSettingsProvider);
  final hasKey = ref.watch(settingsProvider.select((s) => s.hasApiKey));
  final startup = ref.watch(appModeProvider.select((s) => s.startup));
  final controller = ref.read(tavernSettingsProvider.notifier);
  final defaultPersona = ref.watch(tavernPersonaSelectionProvider(null)).value?.persona;
  final generation = ref.watch(tavernGenerationProvider).value ?? TavernGeneration.standard;
  final generate = ref.read(tavernGenerationProvider.notifier);
  return [
    SheetGroup(
      title: l10n.tavernSettingsYou,
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      children: [
        SettingsTile(
          key: const ValueKey('tavern-personas'),
          icon: AppIcons.profile,
          title: l10n.tavernDefaultPersona,
          value: Text(defaultPersona?.name ?? l10n.tavernPersonaNotSet),
          onTap: () => unawaited(Navigator.of(context).push(TavernPersonasPage.route())),
        ),
        SettingsTile(
          key: const ValueKey('tavern-quick-replies'),
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
    SheetGroup(
      title: l10n.tavernSettingsModel,
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      children: [
        SettingsSegmentTile<String>(
          key: const ValueKey('tavern-model'),
          icon: AppIcons.model,
          title: l10n.tavernSettingsModel,
          segments: [
            PillSegment(tavernModels[0], l10n.tavernModelFlash),
            PillSegment(tavernModels[1], l10n.tavernModelPro),
          ],
          selected: settings.model,
          onChanged: (model) => unawaited(controller.setModel(model)),
        ),
        SettingsSwitchTile(
          key: const ValueKey('tavern-thinking'),
          icon: AppIcons.generating,
          title: l10n.tavernThinking,
          subtitle: l10n.tavernThinkingSubtitle,
          value: settings.thinking,
          onChanged: (on) => unawaited(controller.setThinking(on)),
        ),
        SettingsTile(
          key: const ValueKey('tavern-key'),
          icon: hasKey ? AppIcons.apiKey : AppIcons.noApiKey,
          title: l10n.tavernApiKey,
          value: Text(hasKey ? l10n.tavernApiKeySet : l10n.tavernApiKeyMissing),
          onTap: () =>
              Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const ApiKeyPage(onboarding: false))),
        ),
      ],
    ),
    SheetGroup(
      key: const ValueKey('tavern-generation'),
      title: l10n.tavernSettingsGeneration,
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      children: [
        SettingsSegmentTile<int>(
          key: const ValueKey('tavern-max-context'),
          icon: AppIcons.tavernContext,
          title: l10n.tavernMaxContext,
          segments: [for (final tokens in tavernContextSizes) PillSegment(tokens, '${(tokens + 1) ~/ 1024}K')],
          selected: generation.maxContext,
          onChanged: (tokens) => unawaited(generate.setMaxContext(tokens)),
        ),
        SettingsSegmentTile<int>(
          key: const ValueKey('tavern-max-reply'),
          icon: AppIcons.tavernReplyLength,
          title: l10n.tavernMaxReply,
          segments: [for (final tokens in tavernReplySizes) PillSegment(tokens, '$tokens')],
          selected: generation.maxReply,
          onChanged: (tokens) => unawaited(generate.setMaxReply(tokens)),
        ),
        SettingsSegmentTile<double>(
          key: const ValueKey('tavern-temperature'),
          icon: AppIcons.tavernTemperature,
          title: l10n.tavernTemperature,
          segments: [for (final t in tavernTemperatures) PillSegment(t, t.toStringAsFixed(1))],
          selected: generation.temperature,
          onChanged: (t) => unawaited(generate.setTemperature(t)),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 2, 16, 12),
          child: Text(
            l10n.tavernGenerationNote,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(color: DshColors.of(context).textTertiary),
          ),
        ),
      ],
    ),
    SheetGroup(
      title: l10n.tavernSettingsDisplay,
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      children: [
        SettingsSegmentTile<TavernLayout>(
          key: const ValueKey('tavern-layout'),
          icon: AppIcons.article,
          title: l10n.tavernLayout,
          segments: [
            PillSegment(TavernLayout.bubble, l10n.tavernLayoutBubble),
            PillSegment(TavernLayout.novel, l10n.tavernLayoutNovel),
            PillSegment(TavernLayout.visualNovel, l10n.tavernLayoutVisualNovel),
          ],
          selected: settings.layout,
          onChanged: (layout) => unawaited(controller.setLayout(layout)),
        ),
        // How 视觉小说 types out each page.
        SettingsSegmentTile<TavernTextSpeed>(
          key: const ValueKey('tavern-text-speed'),
          icon: AppIcons.textSpeed,
          title: l10n.tavernTextSpeed,
          segments: [
            PillSegment(TavernTextSpeed.slow, l10n.tavernTextSlow),
            PillSegment(TavernTextSpeed.normal, l10n.tavernTextNormal),
            PillSegment(TavernTextSpeed.fast, l10n.tavernTextFast),
            PillSegment(TavernTextSpeed.instant, l10n.tavernTextInstant),
          ],
          selected: settings.textSpeed,
          onChanged: (speed) => unawaited(controller.setTextSpeed(speed)),
        ),
        SettingsSegmentTile<double>(
          key: const ValueKey('tavern-text-size'),
          icon: AppIcons.selectText,
          title: l10n.tavernTextSize,
          segments: [
            for (final (i, size) in tavernTextSizes.indexed)
              PillSegment(
                size,
                [l10n.tavernTextSmall, l10n.tavernTextMedium, l10n.tavernTextLarge, l10n.tavernTextHuge][i],
              ),
          ],
          selected: settings.textSize,
          onChanged: (size) => unawaited(controller.setTextSize(size)),
        ),
        SettingsSegmentTile<double>(
          key: const ValueKey('tavern-line-height'),
          icon: AppIcons.compact,
          title: l10n.tavernLineHeight,
          segments: [
            for (final (i, height) in tavernLineHeights.indexed)
              PillSegment(height, [l10n.tavernLineTight, l10n.tavernLineNormal, l10n.tavernLineLoose][i]),
          ],
          selected: settings.lineHeight,
          onChanged: (height) => unawaited(controller.setLineHeight(height)),
        ),
        SettingsSegmentTile<TavernPalette>(
          key: const ValueKey('tavern-palette'),
          icon: AppIcons.theme,
          title: l10n.tavernPalette,
          segments: [
            PillSegment(TavernPalette.plain, l10n.tavernPalettePlain),
            PillSegment(TavernPalette.ember, l10n.tavernPaletteEmber),
            PillSegment(TavernPalette.ocean, l10n.tavernPaletteOcean),
            PillSegment(TavernPalette.rose, l10n.tavernPaletteRose),
          ],
          selected: settings.palette,
          onChanged: (palette) => unawaited(controller.setPalette(palette)),
        ),
        // What a reply will look like.
        Padding(
          key: const ValueKey('tavern-reading-preview'),
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 14),
          child: TavernReading(child: MarkdownBody(text: l10n.tavernReadingSample, selectable: false)),
        ),
      ],
    ),
    SheetGroup(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      children: [
        SettingsTile(
          key: const ValueKey('tavern-startup'),
          icon: AppIcons.modes,
          title: l10n.modeStartup,
          value: Text(appModeShortLabel(l10n, startup)),
          onTap: () => unawaited(showModeSheet(context, current: AppMode.tavern)),
        ),
      ],
    ),
  ];
}
