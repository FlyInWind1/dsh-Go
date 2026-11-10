// Port of SillyTavern 1.19.0 regex/engine.js, regex/index.js migrations,
// and utils.js regexFromString.
// https://github.com/SillyTavern/SillyTavern
// Commit: 7e8663cd9c184a550b37238218bdd32c6efc68e9 (AGPL-3.0).
// Upstream regexFromString also credits https://github.com/IonicaBizau/regex-parser.js.

/// ST's numeric placement values; zero and four are legacy import values.
abstract final class RegexPlacement {
  static const userInput = 1;
  static const aiOutput = 2;
  static const slashCommand = 3;
  static const worldInfo = 5;
  static const reasoning = 6;
}

enum RegexPhase { writeBack, prompt, display }

/// The callback must apply [postProcess] to each resolved macro value, including
/// nested evaluations. Escaping the complete expanded pattern is not equivalent.
/// Only trim-string expansion receives [characterOverride].
typedef RegexMacroExpansion =
    String Function(String text, {String? characterOverride, Object? Function(Object? value)? postProcess});

/// An immutable execution view. The original card/preset/settings JSON remains
/// owned by its persistence layer, including fields this engine does not read.
final class RegexScript {
  factory RegexScript.fromJson(Map<String, Object?> json) {
    final rawPlacement = json['placement'];
    final placement = rawPlacement is List ? List<Object?>.of(rawPlacement) : <Object?>[];
    var markdownOnly = _truthy(json['markdownOnly']);
    var promptOnly = _truthy(json['promptOnly']);
    if (placement.contains(0)) {
      if (placement.length == 1) {
        placement
          ..clear()
          ..addAll(const [1, 2, 3, 5, 6]);
      } else {
        placement.removeWhere((value) => value == 0);
      }
      markdownOnly = true;
      promptOnly = true;
    }
    if (placement.contains(4)) {
      if (placement.length == 1) {
        placement[0] = RegexPlacement.slashCommand;
      } else {
        placement.removeWhere((value) => value == 4);
      }
    }
    final rawTrims = json['trimStrings'];
    final trims = rawTrims is List ? rawTrims.whereType<String>().toList() : <String>[];
    return RegexScript._(
      id: json['id'] is String ? json['id']! as String : '',
      scriptName: json['scriptName'] is String ? json['scriptName']! as String : '',
      findRegex: json['findRegex'] is String ? json['findRegex']! as String : '',
      replaceString: json['replaceString'] is String ? json['replaceString']! as String : '',
      trimStrings: List.unmodifiable(trims),
      placement: List.unmodifiable([
        for (final value in placement)
          if (value is num && value.isFinite && value == value.truncateToDouble()) value.toInt(),
      ]),
      disabled: _truthy(json['disabled']),
      markdownOnly: markdownOnly,
      promptOnly: promptOnly,
      runOnEdit: _truthy(json['runOnEdit']),
      substituteRegex: _number(json['substituteRegex']),
      minDepth: json['minDepth'] == null ? null : _number(json['minDepth']),
      maxDepth: json['maxDepth'] == null ? null : _number(json['maxDepth']),
      valid:
          json['findRegex'] is String &&
          json['replaceString'] is String &&
          (rawTrims == null || (rawTrims is List && trims.length == rawTrims.length)),
    );
  }

  const RegexScript._({
    required this.id,
    required this.scriptName,
    required this.findRegex,
    required this.replaceString,
    required this.trimStrings,
    required this.placement,
    required this.disabled,
    required this.markdownOnly,
    required this.promptOnly,
    required this.runOnEdit,
    required this.substituteRegex,
    required this.minDepth,
    required this.maxDepth,
    required bool valid,
  }) : _valid = valid;

  final String id;
  final String scriptName;
  final String findRegex;
  final String replaceString;
  final List<String> trimStrings;
  final List<int> placement;
  final bool disabled;
  final bool markdownOnly;
  final bool promptOnly;
  final bool runOnEdit;
  final num substituteRegex;
  final num? minDepth;
  final num? maxDepth;
  final bool _valid;
}

/// Pure synchronous execution. This class neither persists text nor counts
/// chat depth. Callers supply a complete message for write-back, and a separate
/// copy for prompt/display. No write-back script is reapplied to prompt copies.
final class RegexEngine {
  RegexEngine({
    Iterable<RegexScript> globalScripts = const [],
    Iterable<RegexScript> presetScripts = const [],
    Iterable<RegexScript> characterScripts = const [],
    this.enabled = true,
  }) : _scripts = List.unmodifiable([...globalScripts, ...presetScripts, ...characterScripts]);

  final bool enabled;
  final List<RegexScript> _scripts;
  final Map<String, _CompiledRegex> _cache = {};

  /// Parse the execution view without mutating its source. Malformed array
  /// members are ignored; malformed known string fields disable that script.
  static List<RegexScript> readScripts(Object? value) {
    if (value is! List) return const [];
    return List.unmodifiable([
      for (final item in value)
        if (item is Map && item.keys.every((key) => key is String)) RegexScript.fromJson(item.cast<String, Object?>()),
    ]);
  }

  String apply(
    String input, {
    required int placement,
    RegexPhase phase = RegexPhase.writeBack,
    bool isEdit = false,
    num? depth,
    String? characterOverride,
    RegexMacroExpansion? expand,
  }) {
    if (!enabled || input.isEmpty) return input;
    var result = input;
    for (final script in _scripts) {
      final eligible = switch (phase) {
        RegexPhase.writeBack => !script.markdownOnly && !script.promptOnly,
        RegexPhase.prompt => script.promptOnly,
        RegexPhase.display => script.markdownOnly,
      };
      if (!eligible || (isEdit && !script.runOnEdit) || !script.placement.contains(placement)) continue;
      // ST's write-back call sites omit depth. Even if a caller supplies one,
      // this explicit API keeps the storage path independent of depth filters.
      if (phase != RegexPhase.writeBack && depth != null) {
        final minimum = script.minDepth;
        final maximum = script.maxDepth;
        if (minimum != null && minimum >= -1 && depth < minimum) continue;
        if (maximum != null && maximum >= 0 && depth > maximum) continue;
      }
      result = runScript(script, result, characterOverride: characterOverride, expand: expand);
    }
    return result;
  }

  /// Direct execution, like ST's /regex command: placement/phase/edit/depth
  /// selection is bypassed, while disabled and invalid-pattern guards remain.
  String runScript(RegexScript script, String input, {String? characterOverride, RegexMacroExpansion? expand}) {
    if (!script._valid || script.disabled || script.findRegex.isEmpty || input.isEmpty) return input;
    final substitute = expand ?? _identityExpansion;
    final pattern = switch (script.substituteRegex) {
      1 => substitute(script.findRegex),
      2 => substitute(script.findRegex, postProcess: sanitizeRegexMacro),
      _ => script.findRegex,
    };
    final compiled = _compile(pattern);
    if (compiled == null) return input;
    final matches = compiled.global ? compiled.regex.allMatches(input) : compiled.regex.allMatches(input).take(1);
    final output = StringBuffer();
    var previousEnd = 0;
    for (final match in matches) {
      output.write(input.substring(previousEnd, match.start));
      final template = script.replaceString.replaceAll(_matchMacro, r'$0');
      final replacement = template.replaceAllMapped(_captureReference, (reference) {
        final capture = _capture(match, input, reference);
        if (!_truthy(capture)) return '';
        var filtered = capture;
        for (final trim in script.trimStrings) {
          final text = substitute(trim, characterOverride: characterOverride);
          if (filtered is! String) {
            throw StateError(
              'ST regex ${script.scriptName}: ${reference[0]} is not a string capture and cannot be trimmed',
            );
          }
          filtered = filtered.replaceAll(text, '');
        }
        if (filtered is String) return filtered;
        if (filtered is num) return filtered.toString();
        // The JS callback's final named-groups argument has a null prototype:
        // it cannot be converted to a replacement string, even without trims.
        throw StateError('ST regex ${script.scriptName}: ${reference[0]} resolves to the named-groups object');
      });
      output.write(substitute(replacement));
      previousEnd = match.end;
    }
    output.write(input.substring(previousEnd));
    return output.toString();
  }

  /// ST's sanitizeRegexMacro, deliberately different from RegExp.escape:
  /// escapes line controls, slash and regex syntax, but leaves hyphen alone.
  static Object? sanitizeRegexMacro(Object? value) {
    // Legacy ST passes raw number/object macro values here; unlike the new
    // engine, it does not stringify them before this callback.
    if (value is! String) return value;
    const controls = {10: r'\n', 13: r'\r', 9: r'\t', 11: r'\v', 12: r'\f', 0: r'\0'};
    const syntax = r'.^$*+?{}[]\/|()';
    final output = StringBuffer();
    for (final unit in value.codeUnits) {
      final control = controls[unit];
      if (control != null) {
        output.write(control);
      } else {
        final character = String.fromCharCode(unit);
        if (syntax.contains(character)) output.write(r'\');
        output.writeCharCode(unit);
      }
    }
    return output.toString();
  }

  void clearCache() => _cache.clear();

  _CompiledRegex? _compile(String input) {
    final cached = _cache.remove(input);
    if (cached != null) {
      _cache[input] = cached;
      return cached;
    }
    final parsed = _regexFromString(input);
    if (parsed == null) return null;
    if (_cache.length >= 1000) _cache.remove(_cache.keys.first);
    _cache[input] = parsed;
    return parsed;
  }
}

final _matchMacro = RegExp(r'\{\{match\}\}', caseSensitive: false);
final _captureReference = RegExp(r'\$(\d+)|\$<([^>]+)>');
final _regexLiteral = RegExp(r'(/?)(.+)\1([a-z]*)', caseSensitive: false);
final _validFlags = RegExp(r'^(?!.*?(.).*?\1)[gmixXsuUAJ]+$');

final class _CompiledRegex {
  const _CompiledRegex(this.regex, this.global);
  final RegExp regex;
  final bool global;
}

_CompiledRegex? _regexFromString(String input) {
  final parsed = _regexLiteral.firstMatch(input);
  if (parsed == null) return null;
  var pattern = parsed[2]!;
  var flags = parsed[3]!;
  if (flags.isNotEmpty && !_validFlags.hasMatch(flags)) {
    // ST falls back to RegExp(input), including delimiters and invalid flags.
    pattern = input;
    flags = '';
  }
  // These pass ST's historical parser whitelist but fail JavaScript RegExp.
  if (flags.contains(RegExp('[xXUAJ]'))) return null;
  try {
    return _CompiledRegex(
      RegExp(
        pattern,
        caseSensitive: !flags.contains('i'),
        multiLine: flags.contains('m'),
        unicode: flags.contains('u'),
        dotAll: flags.contains('s'),
      ),
      flags.contains('g'),
    );
  } on FormatException {
    return null;
  } on ArgumentError {
    return null;
  }
}

Object? _capture(RegExpMatch match, String input, Match reference) {
  final number = reference[1];
  if (number != null) {
    final index = int.tryParse(number);
    if (index == null) return null;
    if (index <= match.groupCount) return match[index];
    // Preserve ST 1.19's actual callback-argument indexing, not JavaScript's
    // built-in replacement-string syntax: the next two slots are offset/input.
    if (index == match.groupCount + 1) return match.start;
    if (index == match.groupCount + 2) return input;
    if (index == match.groupCount + 3 && match.groupNames.isNotEmpty) return const _NamedGroups();
    return null;
  }
  final name = reference[2]!;
  return match.groupNames.contains(name) ? match.namedGroup(name) : null;
}

final class _NamedGroups {
  const _NamedGroups();
}

String _identityExpansion(String text, {String? characterOverride, Object? Function(Object?)? postProcess}) => text;

bool _truthy(Object? value) {
  if (value == null || value == false || value == '') return false;
  if (value is num) return value != 0 && !value.isNaN;
  return true;
}

num _number(Object? value) {
  if (value == null || value == false) return 0;
  if (value == true) return 1;
  if (value is num) return value;
  if (value is List) value = _arrayString(value);
  if (value is! String) return double.nan;
  final text = value.replaceAll(_numberWhitespace, '');
  if (text.isEmpty) return 0;
  if (text == 'Infinity' || text == '+Infinity') return double.infinity;
  if (text == '-Infinity') return double.negativeInfinity;
  if (RegExp(r'^0[xX][0-9a-fA-F]+$').hasMatch(text)) return int.tryParse(text.substring(2), radix: 16) ?? double.nan;
  if (RegExp(r'^0[bB][01]+$').hasMatch(text)) return int.tryParse(text.substring(2), radix: 2) ?? double.nan;
  if (RegExp(r'^0[oO][0-7]+$').hasMatch(text)) return int.tryParse(text.substring(2), radix: 8) ?? double.nan;
  if (!RegExp(r'^[+-]?(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?$').hasMatch(text)) return double.nan;
  return num.tryParse(text) ?? double.nan;
}

final _numberWhitespace = RegExp(
  r'^[\u0009-\u000d\u0020\u00a0\u1680\u2000-\u200a\u2028\u2029\u202f\u205f\u3000\ufeff]+|'
  r'[\u0009-\u000d\u0020\u00a0\u1680\u2000-\u200a\u2028\u2029\u202f\u205f\u3000\ufeff]+$',
);

String _arrayString(List<Object?> values) => values
    .map((value) {
      if (value == null) return '';
      if (value is List) return _arrayString(value);
      if (value is Map) return '[object Object]';
      return value.toString();
    })
    .join(',');
