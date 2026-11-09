// 酒馆设置: which DeepSeek model plays the characters and whether it thinks
// first (docs/design/roleplay.md §7). The key is the app's own DeepSeek key
// (settings_state.dart); nothing here stores it.

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The models the tavern offers, cheapest first.
const tavernModels = ['deepseek-flash', 'deepseek-v4-pro'];

class TavernSettings {
  const TavernSettings({this.model = 'deepseek-flash', this.thinking = false, this.loaded = false});

  final String model;
  final bool thinking;
  final bool loaded;

  TavernSettings copyWith({String? model, bool? thinking}) =>
      TavernSettings(model: model ?? this.model, thinking: thinking ?? this.thinking, loaded: true);
}

class TavernSettingsController extends Notifier<TavernSettings> {
  static const modelKey = 'tavern.model';
  static const thinkingKey = 'tavern.thinking';

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

  Future<void> _save(Future<bool> Function(SharedPreferences prefs) write) async {
    try {
      await write(await SharedPreferences.getInstance());
    } catch (_) {}
  }
}

final tavernSettingsProvider = NotifierProvider<TavernSettingsController, TavernSettings>(TavernSettingsController.new);
