// 酒馆设置 (docs/design/roleplay-ui.md §1): the model, thinking, and the key
// the calls use.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/app_mode_state.dart';
import '../../state/settings_state.dart';
import '../../tavern/tavern_settings.dart';
import '../common/app_sheet.dart';
import '../modes/mode_switch.dart';
import '../onboarding/api_key_page.dart';
import '../settings/settings_widgets.dart';
import '../shell/page_frame.dart';
import '../theme/app_icons.dart';

class TavernSettingsPage extends ConsumerWidget {
  const TavernSettingsPage({super.key});

  static Route<void> route() => MaterialPageRoute<void>(builder: (_) => const TavernSettingsPage());

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final settings = ref.watch(tavernSettingsProvider);
    final hasKey = ref.watch(settingsProvider.select((s) => s.hasApiKey));
    final startup = ref.watch(appModeProvider.select((s) => s.startup));
    final controller = ref.read(tavernSettingsProvider.notifier);
    return AppPage.list(
      title: l10n.tavernSettings,
      children: [
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
                  Navigator.of(context)
                      .push(MaterialPageRoute<void>(builder: (_) => const ApiKeyPage(onboarding: false))),
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
              ],
              selected: settings.layout,
              onChanged: (layout) => unawaited(controller.setLayout(layout)),
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
      ],
    );
  }
}
