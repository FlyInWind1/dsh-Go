// How the story reads (酒馆设置 › 阅读): its text size, line spacing and
// colours, laid over the app's theme for the transcript only; the composer,
// menus and sheets keep the app's look.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../tavern/tavern_settings.dart';
import '../chat/render/markdown_body.dart';
import 'tavern_ink.dart';

/// [theme] with the story's body text at [size] and [height]. The same
/// object for the same inputs: text caches keyed on the theme keep hitting.
ThemeData tavernReadingTheme(ThemeData theme, {required double size, required double height}) {
  final byTheme = _readingThemes[theme] ??= {};
  return byTheme[(size, height)] ??= theme.copyWith(
    textTheme: theme.textTheme.copyWith(
      bodyLarge: theme.textTheme.bodyLarge?.copyWith(fontSize: size, height: height),
    ),
  );
}

final _readingThemes = Expando<Map<(double, double), ThemeData>>('tavernReading');

/// The patterns a coloured story is drawn with: one list, so the text's parse
/// cache keeps hitting.
final _inkPatterns = [tavernInkPattern];

/// [child] (the transcript) under the reading settings.
class TavernReading extends ConsumerWidget {
  const TavernReading({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final (size, height, palette) = ref.watch(
      tavernSettingsProvider.select((s) => (s.textSize, s.lineHeight, s.palette)),
    );
    final theme = Theme.of(context);
    final ink = TavernInk.of(palette, theme.brightness);
    final read = Theme(
      data: tavernReadingTheme(theme, size: size, height: height),
      child: child,
    );
    return TavernInkScope(
      ink: ink,
      child: MarkdownPatterns(
        patterns: _inkPatterns,
        // Drawn afresh in other colours: the text keeps the spans it made.
        child: KeyedSubtree(key: ValueKey((palette, theme.brightness)), child: read),
      ),
    );
  }
}
