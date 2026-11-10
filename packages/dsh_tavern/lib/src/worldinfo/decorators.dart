// Character Card V3 SPEC_V3.md, blob cb9749821955047890ac88aa84ec0b235ae0fb5d,
// plus the two native ST decorators at commit 7e8663cd9c184a550b37238218bdd32c6efc68e9.
part of 'world_info.dart';

/// Full V3 semantics. ST's limited parser is kept separately for timer hashes.
class _Decorators {
  _Decorators(this.entry, this.input) {
    final text = entry.content;
    var offset = 0;
    var fallback = false;
    while (offset < text.length) {
      final line = RegExp(r'[^\r\n]*(?:\r\n|\r|\n|$)').matchAsPrefix(text, offset);
      if (line == null || line.end == offset) break;
      final raw = line[0]!.replaceFirst(RegExp(r'[\r\n]+$'), '');
      if (!raw.startsWith('@@')) break;
      offset = line.end;
      final isFallback = raw.startsWith('@@@');
      if (isFallback && !fallback) continue;
      final body = raw.substring(isFallback ? 3 : 2);
      final parsed = RegExp(r'^([a-z_]+)(?:[ \t]+(.*))?$').firstMatch(body);
      if (parsed == null) {
        fallback = true;
        continue;
      }
      final name = parsed[1]!;
      final value = (parsed[2] ?? '').trim();
      final accepted = _parse(name, value);
      fallback = accepted == null || (name != 'additional_keys' && values.containsKey(name));
      if (!fallback) {
        if (name == 'additional_keys') {
          additionalKeys.add(accepted as List<String>);
        } else {
          values[name] = accepted;
        }
      }
    }
    // V3 requires trimming newlines adjacent to decorator lines, but not the
    // ordinary content's spaces or trailing newlines.
    content = offset == 0 ? text : text.substring(offset).replaceFirst(RegExp(r'^[\r\n]+'), '');
  }

  final WorldInfoEntry entry;
  final WorldInfoInput input;
  final values = <String, Object?>{};
  final additionalKeys = <List<String>>[];
  late final String content;

  Object? _parse(String name, String text) {
    if (const {
      'activate',
      'dont_activate',
      'keep_activate_after_match',
      'dont_activate_after_match',
      'ignore_on_max_context',
    }.contains(name)) {
      if (text.isNotEmpty) return null;
      if (name == 'ignore_on_max_context' && input.contextAtCapacity == null) return null;
      return true;
    }
    if (const {
      'activate_only_after',
      'activate_only_every',
      'depth',
      'reverse_depth',
      'scan_depth',
      'is_greeting',
    }.contains(name)) {
      final number = num.tryParse(text);
      if (number == null || !number.isFinite) return null;
      if (name == 'activate_only_every' && number <= 0) return null;
      if ((name == 'activate_only_after' || name == 'activate_only_every') && input.assistantMessageCount == null) {
        return null;
      }
      if (name == 'is_greeting' && (input.greetingIndex == null || number < 0 || number != number.toInt())) return null;
      return number;
    }
    if (name == 'role') return const {'system': 0, 'user': 1, 'assistant': 2}[text];
    if (name == 'position') {
      if (text == 'before_desc' || text == 'after_desc') return text;
      if (text == 'personality' &&
          input.characterPersonality.isNotEmpty &&
          (input.availablePromptSections?.contains(text) ?? true)) {
        return text;
      }
      if (text == 'scenario' && input.scenario.isNotEmpty && (input.availablePromptSections?.contains(text) ?? true)) {
        return text;
      }
      return null;
    }
    if (name == 'additional_keys' || name == 'exclude_keys') {
      if (name == 'exclude_keys' && entry.useRegex) return null;
      final keys = text.split(',').map((value) => value.trim()).toList();
      return keys.any((value) => value.isEmpty) ? null : keys;
    }
    if (name == 'is_user_icon') return input.userIconName == null || text.isEmpty || text.contains(',') ? null : text;
    if (name == 'disable_ui_prompt') {
      return const {'system_prompt', 'post_history_instructions'}.contains(text) ? text : null;
    }
    return null;
  }

  bool get activate => values['activate'] == true;
  bool get dontActivate => values['dont_activate'] == true;
  bool get keepAfterMatch => values['keep_activate_after_match'] == true;
  bool get dontAfterMatch => values['dont_activate_after_match'] == true;
  bool get ignoreOnMaxContext => values['ignore_on_max_context'] == true;
  String? get section => values['position'] as String?;
  String? get disabledUiPrompt => values['disable_ui_prompt'] as String?;
  int? get scanDepth => (values['scan_depth'] as num?)?.toInt();
  int? get role => values['role'] as int?;
  bool get assistantPrefill {
    if (section != null || role != 2) {
      return false;
    }
    final explicitDepth = values['depth'] as num?;
    final reverse = values['reverse_depth'] as num?;
    final rawDepth = explicitDepth ?? (reverse == null ? null : input.messages.length - reverse);
    // A clamped or truncated depth of zero does not declare V3 prefill.
    return rawDepth == 0;
  }

  int? get depth {
    if (section != null) return null;
    final value = values['depth'] as num?;
    if (value != null) return math.min(input.messages.length, math.max(0, value.toInt()));
    final reverse = values['reverse_depth'] as num?;
    return reverse == null
        ? null
        : math.min(input.messages.length, math.max(0, (input.messages.length - reverse).toInt()));
  }

  bool allows(_ScanBuffer buffer, WorldInfoScanPhase phase) {
    final after = values['activate_only_after'] as num?;
    if (after != null && input.assistantMessageCount! < after) return false;
    final every = values['activate_only_every'] as num?;
    if (every != null && input.assistantMessageCount! % every != 0) return false;
    final greeting = values['is_greeting'] as num?;
    if (greeting != null && input.greetingIndex != greeting) return false;
    final icon = values['is_user_icon'];
    if (icon != null && input.userIconName != icon) return false;
    if (ignoreOnMaxContext && input.contextAtCapacity == true) return false;
    final text = buffer.get(entry, phase, scanDepth: scanDepth);
    for (final group in additionalKeys) {
      final expanded = group.map(input.expand).toList();
      if (entry.useRegex && expanded.any((key) => _v3Regex(key, entry) == null)) return false;
      if (!expanded.any((key) => key.isNotEmpty && buffer.matches(text, key.trim(), entry))) return false;
    }
    final excluded = values['exclude_keys'] as List<String>?;
    if (excluded != null) {
      for (final key in excluded) {
        final expanded = input.expand(key);
        if (expanded.isNotEmpty && buffer.matches(text, expanded.trim(), entry)) return false;
      }
    }
    return true;
  }
}

(RegExp, bool)? _v3Regex(String text, WorldInfoEntry entry, {bool caseSensitive = false}) {
  // V3 explicitly uses /pattern/flags examples. A malformed literal is invalid,
  // never a plain substring fallback. Bare patterns remain supported as well.
  if (text.startsWith('/')) return _keywordRegex(text);
  try {
    return (RegExp(text, caseSensitive: entry.caseSensitive ?? caseSensitive), false);
  } on FormatException {
    return null;
  }
}

/// Observed admissions on the selected branch; prior imported history is never
/// guessed. A content hash change starts a fresh record. Same-count previews or
/// retries cannot increment a record twice.
class _DecoratorHistory {
  _DecoratorHistory(this.input) : state = jsonDecode(jsonEncode(input.decoratorState)) as Map<String, Object?>;
  final WorldInfoInput input;
  final Map<String, Object?> state;
  _DecoratorHistory._fork(this.input, this.state);
  _DecoratorHistory fork() => _DecoratorHistory._fork(input, jsonDecode(jsonEncode(state)) as Map<String, Object?>);
  int previous(_RuntimeEntry entry) => math.max(0, _integer(_object(state['${entry.hash}'])['matches']) ?? 0);
  void finish(Iterable<_RuntimeEntry> activated) {
    if (input.dryRun) return;
    for (final entry in activated) {
      final old = _object(state['${entry.hash}']);
      if (_integer(old['lastMessageCount']) == input.messages.length) continue;
      state['${entry.hash}'] = {...old, 'matches': previous(entry) + 1, 'lastMessageCount': input.messages.length};
    }
  }
}
