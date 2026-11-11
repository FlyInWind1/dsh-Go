// A card's own look (docs/design/roleplay-ui.md §10, extensions.dshgo.theme):
// its accent, the layout it reads best in, its characters' name colours and
// its background, read leniently from the raw JSON. It reaches only the story
// (transcript, stage, picture); the app's shell keeps its own look. Fonts are
// not drawn yet. 酒馆设置 › 显示 turns all of it off.

import 'dart:io';
import 'dart:ui' as ui;

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../wallpaper/custom_wallpaper.dart';
import 'tavern_provider.dart';
import 'tavern_settings.dart';

class TavernCardTheme {
  const TavernCardTheme({this.accent, this.layout, this.names = const {}, this.background});

  final Color? accent;

  /// The layout a chat with this card starts in, until it picks its own.
  final TavernLayout? layout;

  /// Name colours by speaker, as the card writes the names.
  final Map<String, Color> names;

  /// A file on this phone: the asset the theme names, else the card's first
  /// background asset. Remote pictures are never fetched for it.
  final String? background;

  bool get isEmpty => accent == null && layout == null && names.isEmpty && background == null;

  static TavernCardTheme of(TavernCharacter character) {
    final raw = character.theme;
    final theme = raw is Map ? raw : const {};
    final local = [
      for (final a in character.assets)
        if (a.localPath case final String path when path.isNotEmpty) (asset: a, path: path),
    ];
    String? background;
    if (theme['background'] case final String named when named.trim().isNotEmpty) {
      final want = named.trim();
      background = local.where((a) => a.asset.name == want || a.asset.uri == want).firstOrNull?.path;
    } else {
      background = local.where((a) => a.asset.type == 'background').firstOrNull?.path;
    }
    return TavernCardTheme(
      accent: tavernCssColor(theme['accent']),
      layout: switch (theme['layout']) {
        'bubble' || 'chat' => TavernLayout.bubble,
        'novel' => TavernLayout.novel,
        'vn' || 'visualNovel' || 'visual_novel' || 'visual-novel' || 'galgame' => TavernLayout.visualNovel,
        _ => null,
      },
      names: {
        if (theme['names'] case final Map names)
          for (final MapEntry(:key, :value) in names.entries)
            if (key is String)
              if (tavernCssColor(value) case final Color color) key: color,
      },
      background: background,
    );
  }
}

/// A CSS colour as cards write them: #rgb, #rgba, #rrggbb, #rrggbbaa,
/// rgb(r, g, b) or rgba(r, g, b, a). Anything else (names, var(), hsl) is
/// null.
Color? tavernCssColor(Object? value) {
  if (value is! String) return null;
  final s = value.trim().toLowerCase();
  final hex = RegExp(r'^#([0-9a-f]{3,4}|[0-9a-f]{6}|[0-9a-f]{8})$').firstMatch(s)?.group(1);
  if (hex != null) {
    final full = hex.length <= 4 ? hex.split('').map((c) => '$c$c').join() : hex;
    final rgb = int.parse(full.substring(0, 6), radix: 16);
    final alpha = full.length == 8 ? int.parse(full.substring(6), radix: 16) : 0xff;
    return Color((alpha << 24) | rgb);
  }
  final fn = RegExp(r'^rgba?\(\s*([\d.]+)\s*,\s*([\d.]+)\s*,\s*([\d.]+)\s*(?:,\s*([\d.]+%?)\s*)?\)$').firstMatch(s);
  if (fn == null) return null;
  int channel(String v) => double.parse(v).round().clamp(0, 255);
  var alpha = 1.0;
  if (fn.group(4) case final String a) {
    alpha = a.endsWith('%') ? double.parse(a.substring(0, a.length - 1)) / 100 : double.parse(a);
  }
  return Color.fromARGB(
    (alpha.clamp(0, 1) * 255).round(),
    channel(fn.group(1)!),
    channel(fn.group(2)!),
    channel(fn.group(3)!),
  );
}

/// The card's look for a chat with [characterId]; null when there is none,
/// or 酒馆设置 says not to use it.
final tavernCardThemeProvider = Provider.autoDispose.family<TavernCardTheme?, String?>((ref, characterId) {
  if (characterId == null || !ref.watch(tavernSettingsProvider.select((s) => s.cardTheme))) return null;
  final character = ref.watch(tavernCharacterDetailProvider(characterId)).value;
  if (character == null) return null;
  final theme = TavernCardTheme.of(character);
  return theme.isEmpty ? null : theme;
});

/// The card's background at [path] as a chat picture: read in place (the
/// library keeps the file), only its size decoded. Null when it can't be
/// read or is over a wallpaper's size limit.
final tavernCardBackgroundProvider = FutureProvider.autoDispose.family<CustomWallpaper?, String>((ref, path) async {
  try {
    final file = File(path);
    if (!file.existsSync() || file.lengthSync() > CustomWallpaper.maxBytes) return null;
    final buffer = await ui.ImmutableBuffer.fromFilePath(path);
    final descriptor = await ui.ImageDescriptor.encoded(buffer);
    final (width, height) = (descriptor.width, descriptor.height);
    descriptor.dispose();
    buffer.dispose();
    return CustomWallpaper(path: path, width: width, height: height);
  } catch (_) {
    return null;
  }
});
