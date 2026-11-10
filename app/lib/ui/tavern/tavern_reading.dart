// How the story reads (酒馆设置 › 阅读): its text size and line spacing, laid
// over the app's theme for the transcript only; the composer, menus and sheets
// keep the app's sizes.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../tavern/tavern_settings.dart';

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

/// [child] (the transcript) under the reading settings.
class TavernReading extends ConsumerWidget {
  const TavernReading({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final (size, height) = ref.watch(tavernSettingsProvider.select((s) => (s.textSize, s.lineHeight)));
    return Theme(
      data: tavernReadingTheme(Theme.of(context), size: size, height: height),
      child: child,
    );
  }
}
