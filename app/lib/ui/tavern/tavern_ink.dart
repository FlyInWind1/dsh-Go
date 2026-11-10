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
/// A 「, 『 or “ still open at the very end (a reply being written, a page
/// being typed out; the cursor, U+E000, may follow) is said too, so the words
/// don't change colour as the quote closes.
const _said =
    '「[^」\\n\\uE000]*(?:」|(?=\\uE000?\$))|'
    '『[^』\\n\\uE000]*(?:』|(?=\\uE000?\$))|'
    '“[^”\\n\\uE000]*(?:”|(?=\\uE000?\$))|'
    '(?<![=\\w])"[^"\\n<>]*"';

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

/// Colours for names other than the chat's own character's, light and dark.
const _nameColorsLight = [0xFF0F7A6B, 0xFF7A4BB8, 0xFFB03A6E, 0xFF9A5508, 0xFF3D7A1E, 0xFF2B63B0];
const _nameColorsDark = [0xFF6FD3C2, 0xFFC0A3F2, 0xFFF29BC0, 0xFFF0B868, 0xFFA6D98A, 0xFF8CC2F5];

/// The colour [speaker]'s name is drawn in (docs/design/roleplay-ui.md §10):
/// the chat's own character ([lead]) in the accent; anyone else (a guest, a
/// narrator by name, the others of a group) in a colour of their own, the same
/// every time.
Color tavernNameColor(BuildContext context, String speaker, {required String lead}) {
  final theme = Theme.of(context);
  if (speaker.isEmpty || speaker == lead) return theme.colorScheme.primary;
  // FNV-1a, then a last stir: names a few CJK characters long still spread
  // over all the colours.
  var hash = 0x811c9dc5;
  for (final rune in speaker.runes) {
    hash = ((hash ^ rune) * 0x01000193) & 0xffffffff;
  }
  hash ^= hash >> 15;
  hash = (hash * 0x2c1b3c6d) & 0xffffffff;
  hash ^= hash >> 12;
  final colors = theme.brightness == Brightness.dark ? _nameColorsDark : _nameColorsLight;
  // The high half: the low bits of an FNV hash spread poorly.
  return Color(colors[(hash >> 16) % colors.length]);
}
