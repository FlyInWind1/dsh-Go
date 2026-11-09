// 酒馆设置: which DeepSeek model plays the characters and whether it thinks
// first (docs/design/roleplay.md §7). The key is the app's own DeepSeek key
// (settings_state.dart); nothing here stores it.

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The models the tavern offers, cheapest first.
const tavernModels = ['deepseek-flash', 'deepseek-v4-pro'];

/// How a chat is laid out (docs/design/roleplay-ui.md §4): bubbles, or full
/// width text under the speaker's name. 视觉小说 comes with the canvas.
enum TavernLayout { bubble, novel }

class TavernSettings {
  const TavernSettings({
    this.model = 'deepseek-flash',
    this.thinking = false,
    this.layout = TavernLayout.bubble,
    this.loaded = false,
  });

  final String model;
  final bool thinking;
  final TavernLayout layout;
  final bool loaded;

  TavernSettings copyWith({String? model, bool? thinking, TavernLayout? layout}) => TavernSettings(
    model: model ?? this.model,
    thinking: thinking ?? this.thinking,
    layout: layout ?? this.layout,
    loaded: true,
  );
}

class TavernSettingsController extends Notifier<TavernSettings> {
  static const modelKey = 'tavern.model';
  static const thinkingKey = 'tavern.thinking';
  static const layoutKey = 'tavern.layout';

  @override
  TavernSettings build() {
    unawaited(_load());
    return const TavernSettings();
  }

  Future<void> _load() async {
    var loaded = const TavernSettings(loaded: true);
    try {
      final prefs = await SharedPreferences.getInstance();
      final model = prefs.getString(modelKey);
      loaded = TavernSettings(
        model: tavernModels.contains(model) ? model! : tavernModels.first,
        thinking: prefs.getBool(thinkingKey) ?? false,
        layout: TavernLayout.values.asNameMap()[prefs.getString(layoutKey)] ?? TavernLayout.bubble,
        loaded: true,
      );
    } catch (_) {
      // No preferences backend (tests): the defaults.
    }
    if (!state.loaded) state = loaded;
  }

  Future<void> setModel(String model) async {
    state = state.copyWith(model: model);
    await _save((prefs) => prefs.setString(modelKey, model));
  }

  Future<void> setThinking(bool thinking) async {
    state = state.copyWith(thinking: thinking);
    await _save((prefs) => prefs.setBool(thinkingKey, thinking));
  }

  Future<void> setLayout(TavernLayout layout) async {
    state = state.copyWith(layout: layout);
    await _save((prefs) => prefs.setString(layoutKey, layout.name));
  }

  Future<void> _save(Future<bool> Function(SharedPreferences prefs) write) async {
    try {
      await write(await SharedPreferences.getInstance());
    } catch (_) {}
  }
}

final tavernSettingsProvider = NotifierProvider<TavernSettingsController, TavernSettings>(TavernSettingsController.new);
