// The story's colours (docs/design/roleplay-ui.md §10, the colours an ST theme
// sets most): what is said in quotes, and what is done in *italics*, each in a
// colour of its own; the narration stays the page's text. A few sets to pick
// from in 酒馆设置; 素 leaves the text as the app draws it.

import 'package:flutter/material.dart';
import 'package:gpt_markdown/gpt_markdown.dart' show InlinePattern;

import '../../tavern/tavern_settings.dart';

/// The colours for one set and brightness; null leaves that part as it is.
@immutable
class TavernInk {
  const TavernInk({this.dialogue, this.action});

  final Color? dialogue;
  final Color? action;

  bool get plain => dialogue == null && action == null;

  /// [palette]'s colours on a page of [brightness]: each readable on its own
  /// page, the darker for light pages.
  factory TavernInk.of(TavernPalette palette, Brightness brightness) {
    final dark = brightness == Brightness.dark;
    Color pick(int light, int night) => Color(dark ? night : light);
    return switch (palette) {
      TavernPalette.plain => const TavernInk(),
      TavernPalette.ember => TavernInk(dialogue: pick(0xFF9A5508, 0xFFF0B868), action: pick(0xFF5F6577, 0xFFA5ABBD)),
      TavernPalette.ocean => TavernInk(dialogue: pick(0xFF1C5FA8, 0xFF8CC2F5), action: pick(0xFF56676C, 0xFF9FB2B8)),
      TavernPalette.rose => TavernInk(dialogue: pick(0xFFAA2E66, 0xFFF29BC0), action: pick(0xFF6A55A3, 0xFFB9A8EE)),
    };
  }
}

/// The colours the story below is drawn in.
class TavernInkScope extends InheritedWidget {
  const TavernInkScope({super.key, required this.ink, required super.child});

  final TavernInk ink;

  static TavernInk? maybeOf(BuildContext context) => context.dependOnInheritedWidgetOfExactType<TavernInkScope>()?.ink;

  @override
  bool updateShouldNotify(TavernInkScope old) => old.ink.dialogue != ink.dialogue || old.ink.action != ink.action;
}

/// What is said: text in 「」『』“” or "…" (not an HTML attribute's value).
const _said = '「[^」\\n]*」|『[^』\\n]*』|“[^”\\n]*”|(?<![=\\w])"[^"\\n<>]*"';

/// What is done: `*…*` with single asterisks, as Markdown's italics would take
/// it (not `**bold**`, not `a*b*c` inside a word).
const _done = '(?<![*\\w])\\*(?![\\s*])([^*\\n]+?)(?<!\\s)\\*(?![*\\w])';

/// Matched with Markdown's own syntax, ahead of it: only these two, so the
/// rest of the reply is parsed as ever.
final _story = RegExp('$_said|$_done');
final _saidOnly = RegExp(_said);

/// [text] with what is said in it in [ink]'s dialogue colour.
List<InlineSpan> _sayings(String text, TextStyle style, TavernInk? ink) {
  final color = ink?.dialogue;
  if (color == null) return [TextSpan(text: text, style: style)];
  final spans = <InlineSpan>[];
  var at = 0;
  for (final m in _saidOnly.allMatches(text)) {
    if (m.start > at) spans.add(TextSpan(text: text.substring(at, m.start), style: style));
    spans.add(
      TextSpan(
        text: m[0],
        style: style.copyWith(color: color),
      ),
    );
    at = m.end;
  }
  if (at < text.length) spans.add(TextSpan(text: text.substring(at), style: style));
  return spans;
}

/// Colours the story by [TavernInkScope]: what is said as dialogue, what is
/// done (`*…*`, in italics as ever) as action, and quotes inside an action
/// still as dialogue. Without a scope, or with 素, it draws them as the app
/// does: the quote as it is, the action in italics.
final tavernInkPattern = InlinePattern(
  pattern: _story,
  builder: (context, match, style) {
    final ink = TavernInkScope.maybeOf(context);
    if (match[1] case final done?) {
      final italic = style.copyWith(fontStyle: FontStyle.italic, color: ink?.action ?? style.color);
      return TextSpan(children: _sayings(done, italic, ink));
    }
    return TextSpan(
      text: match[0],
      style: ink?.dialogue == null ? style : style.copyWith(color: ink!.dialogue),
    );
  },
);
