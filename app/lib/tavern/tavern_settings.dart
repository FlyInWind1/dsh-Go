// 酒馆设置: which DeepSeek model plays the characters and whether it thinks
// first (docs/design/roleplay.md §7). The key is the app's own DeepSeek key
// (settings_state.dart); nothing here stores it.

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The models the tavern offers, cheapest first.
const tavernModels = ['deepseek-flash', 'deepseek-v4-pro'];

/// How a chat is laid out (docs/design/roleplay-ui.md §4): bubbles, full
/// width text under the speaker's name, or a stage with one paragraph at a
/// time (视觉小说).
enum TavernLayout { bubble, novel, visualNovel }

/// The story's text size (px), smallest first: a role-play reads more at a
/// time than a chat, so it starts a step below the app's 16.
const tavernTextSizes = [14.0, 15.0, 16.0, 18.0];

/// Its line spacing: 紧凑, 适中 (the app's), 宽松.
const tavernLineHeights = [1.5, 1.65, 1.8];

class TavernSettings {
  const TavernSettings({
    this.model = 'deepseek-flash',
    this.thinking = false,
    this.layout = TavernLayout.bubble,
    this.textSize = 15,
    this.lineHeight = 1.5,
    this.loaded = false,
  });

  final String model;
  final bool thinking;
  final TavernLayout layout;

  /// One of [tavernTextSizes] and [tavernLineHeights].
  final double textSize;
  final double lineHeight;
  final bool loaded;

  TavernSettings copyWith({
    String? model,
    bool? thinking,
    TavernLayout? layout,
    double? textSize,
    double? lineHeight,
  }) => TavernSettings(
    model: model ?? this.model,
    thinking: thinking ?? this.thinking,
    layout: layout ?? this.layout,
    textSize: textSize ?? this.textSize,
    lineHeight: lineHeight ?? this.lineHeight,
    loaded: true,
  );
}

class TavernSettingsController extends Notifier<TavernSettings> {
  static const modelKey = 'tavern.model';
  static const thinkingKey = 'tavern.thinking';
  static const layoutKey = 'tavern.layout';
  static const textSizeKey = 'tavern.textSize';
  static const lineHeightKey = 'tavern.lineHeight';

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
        textSize: _oneOf(prefs.getDouble(textSizeKey), tavernTextSizes, 15),
        lineHeight: _oneOf(prefs.getDouble(lineHeightKey), tavernLineHeights, 1.5),
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

  Future<void> setTextSize(double size) async {
    state = state.copyWith(textSize: size);
    await _save((prefs) => prefs.setDouble(textSizeKey, size));
  }

  Future<void> setLineHeight(double height) async {
    state = state.copyWith(lineHeight: height);
    await _save((prefs) => prefs.setDouble(lineHeightKey, height));
  }

  /// [stored] when it is one of [choices]; else [fallback].
  static double _oneOf(double? stored, List<double> choices, double fallback) =>
      stored != null && choices.contains(stored) ? stored : fallback;

  Future<void> _save(Future<bool> Function(SharedPreferences prefs) write) async {
    try {
      await write(await SharedPreferences.getInstance());
    } catch (_) {}
  }
}

final tavernSettingsProvider = NotifierProvider<TavernSettingsController, TavernSettings>(TavernSettingsController.new);

/// One chat's own layout, over 酒馆设置's; null follows the setting.
class TavernChatLayoutController extends Notifier<TavernLayout?> {
  TavernChatLayoutController(this.chatId);

  final String chatId;
  var _chosen = false;

  String get _key => 'tavern.layout.$chatId';

  @override
  TavernLayout? build() {
    unawaited(_load());
    return null;
  }

  Future<void> _load() async {
    try {
      final stored = (await SharedPreferences.getInstance()).getString(_key);
      if (!_chosen && ref.mounted) state = TavernLayout.values.asNameMap()[stored];
    } catch (_) {}
  }

  Future<void> set(TavernLayout? layout) async {
    _chosen = true;
    state = layout;
    try {
      final prefs = await SharedPreferences.getInstance();
      layout == null ? await prefs.remove(_key) : await prefs.setString(_key, layout.name);
    } catch (_) {}
  }
}

final tavernChatLayoutProvider = NotifierProvider.autoDispose.family<TavernChatLayoutController, TavernLayout?, String>(
  TavernChatLayoutController.new,
);
