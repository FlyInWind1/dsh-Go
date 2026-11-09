// Port of SillyTavern 1.19.0 public/scripts/world-info.js (AGPL-3.0),
// commit 7e8663cd9c184a550b37238218bdd32c6efc68e9: WorldInfoBuffer,
// getSortedEntries, checkWorldInfo, inclusion groups and convertCharacterBook.
// IO, UI, events, timed effects and V3 decorators are outside this evaluator.

import 'dart:convert';
import 'dart:math' as math;

enum WorldInfoSource { global, character, chat, persona, memory }

enum WorldInfoStrategy { evenly, characterFirst, globalFirst }

/// The indices are ST's persisted position values, including AN before depth.
enum WorldInfoPosition {
  before,
  after,
  authorNoteBefore,
  authorNoteAfter,
  atDepth,
  examplesBefore,
  examplesAfter,
  outlet,
}

enum WorldInfoRole { system, user, assistant }

enum WorldInfoScanPhase { initial, recursion, minActivations }

/// Keeps the complete original book, including fields this wave does not use.
/// A character book is the card's `data.character_book`, not the whole card.
class WorldInfoBook {
  WorldInfoBook._(this.id, this.source, this.raw) {
    final original = raw['entries'];
    final byId = <String, Map<String, Object?>>{};
    final parsed = <WorldInfoEntry>[];
    if (original is Map<String, Object?>) {
      for (final key in _objectKeys(original.keys)) {
        final value = original[key];
        if (value is! Map<String, Object?>) throw FormatException('World info entry $key must be an object.');
        parsed.add(WorldInfoEntry._(this, _id(value['uid'] ?? key), value, value));
      }
    } else if (original is List<Object?>) {
      for (var index = 0; index < original.length; index++) {
        final value = original[index];
        if (value is! Map<String, Object?>) throw FormatException('Character book entry $index must be an object.');
        byId[_id(value['id'] ?? index)] = value;
      }
      for (final uid in _objectKeys(byId.keys)) {
        parsed.add(WorldInfoEntry._(this, uid, byId[uid]!, _convertCharacterEntry(byId[uid]!)));
      }
    } else {
      throw const FormatException('World info must contain an entries object or array.');
    }
    entries = List.unmodifiable(parsed);
  }

  factory WorldInfoBook.fromJson({
    required String id,
    required WorldInfoSource source,
    required Map<String, Object?> json,
  }) => WorldInfoBook._(id, source, jsonDecode(jsonEncode(json)) as Map<String, Object?>);

  final String id;
  final WorldInfoSource source;
  final Map<String, Object?> raw;
  late final List<WorldInfoEntry> entries;
  String get name => raw['name'] is String ? raw['name'] as String : id;
}

class WorldInfoEntry {
  const WorldInfoEntry._(this.book, this.uid, this.raw, this._fields);
  final WorldInfoBook book;
  final String uid;
  final Map<String, Object?> raw;
  final Map<String, Object?> _fields;
  (String, String) get identity => (book.id, uid);
  List<String> get keys => _strings(_fields['key']);
  List<String> get secondaryKeys => _strings(_fields['keysecondary']);
  String get content => _string(_fields['content']);
  String get comment => _string(_fields['comment']);
  bool get constant => _fields['constant'] == true;
  bool get disabled => _fields['disable'] == true;
  bool get selective => _fields['selective'] == true;
  int get selectiveLogic => _integer(_fields['selectiveLogic']) ?? 0;
  num get order => _number(_fields['order']) ?? 100;
  int? get position => _integer(_fields['position']);
  int get depth => _integer(_fields['depth']) ?? 4;
  int get role => _integer(_fields['role']) ?? 0;
  String get outlet => _string(_fields['outletName']);
  bool get ignoreBudget => _fields['ignoreBudget'] == true;
  bool get excludeRecursion => _fields['excludeRecursion'] == true;
  bool get preventRecursion => _fields['preventRecursion'] == true;
  num get delayUntilRecursion =>
      _fields['delayUntilRecursion'] == true ? 1 : _number(_fields['delayUntilRecursion']) ?? 0;
  bool get useProbability => _fields['useProbability'] == true;
  num get probability => _number(_fields['probability']) ?? 100;
  String get group => _string(_fields['group']);
  bool get groupOverride => _fields['groupOverride'] == true;
  num get groupWeight => _number(_fields['groupWeight']) ?? 100;
  int? get scanDepth => _integer(_fields['scanDepth']);
  bool? get caseSensitive => _boolean(_fields['caseSensitive']);
  bool? get matchWholeWords => _boolean(_fields['matchWholeWords']);
  bool? get useGroupScoring => _boolean(_fields['useGroupScoring']);
  List<String> get triggers => _strings(_fields['triggers']);
}

class WorldInfoSettings {
  const WorldInfoSettings({
    this.scanDepth = 2,
    this.budgetPercent = 25,
    this.budgetCap = 0,
    this.includeNames = true,
    this.recursive = false,
    this.caseSensitive = false,
    this.matchWholeWords = false,
    this.useGroupScoring = false,
    this.strategy = WorldInfoStrategy.characterFirst,
    this.minActivations = 0,
    this.minActivationsDepthMax = 0,
    this.maxRecursionSteps = 0,
  });

  factory WorldInfoSettings.fromJson(Map<String, Object?> json) {
    final strategy = _integer(json['world_info_character_strategy']) ?? 1;
    return WorldInfoSettings(
      scanDepth: _integer(json['world_info_depth']) ?? 2,
      budgetPercent: _number(json['world_info_budget']) ?? 25,
      budgetCap: _integer(json['world_info_budget_cap']) ?? 0,
      includeNames: _boolean(json['world_info_include_names']) ?? true,
      recursive: _boolean(json['world_info_recursive']) ?? false,
      caseSensitive: _boolean(json['world_info_case_sensitive']) ?? false,
      matchWholeWords: _boolean(json['world_info_match_whole_words']) ?? false,
      useGroupScoring: _boolean(json['world_info_use_group_scoring']) ?? false,
      strategy: strategy == 1
          ? WorldInfoStrategy.characterFirst
          : strategy == 2
          ? WorldInfoStrategy.globalFirst
          : WorldInfoStrategy.evenly,
      minActivations: _integer(json['world_info_min_activations']) ?? 0,
      minActivationsDepthMax: _integer(json['world_info_min_activations_depth_max']) ?? 0,
      maxRecursionSteps: _integer(json['world_info_max_recursion_steps']) ?? 0,
    );
  }
  final int scanDepth;
  final num budgetPercent;
  final int budgetCap;
  final bool includeNames;
  final bool recursive;
  final bool caseSensitive;
  final bool matchWholeWords;
  final bool useGroupScoring;
  final WorldInfoStrategy strategy;
  final int minActivations;
  final int minActivationsDepthMax;
  final int maxRecursionSteps;
}

class WorldInfoMessage {
  const WorldInfoMessage(this.text, {this.speaker = ''});
  final String text;
  final String speaker;
}

/// All dependencies are explicit. Callers supply only prompt-eligible messages
/// (for example, remove hidden nodes) in oldest-to-newest order. Random values
/// must be in [0, 1); tokenCount must be a deterministic non-negative counter.
class WorldInfoInput {
  const WorldInfoInput({
    required this.books,
    required this.messages,
    required this.maxContext,
    required this.tokenCount,
    required this.random,
    this.expand = _identity,
    this.settings = const WorldInfoSettings(),
    this.scanInjections = const [],
    this.personaDescription = '',
    this.characterDescription = '',
    this.characterPersonality = '',
    this.characterDepthPrompt = '',
    this.scenario = '',
    this.creatorNotes = '',
    this.trigger = 'normal',
    this.characterName = '',
    this.characterTags,
  });
  final List<WorldInfoBook> books;
  final List<WorldInfoMessage> messages;
  final int maxContext;
  final int Function(String) tokenCount;
  final double Function() random;
  final String Function(String) expand;
  final WorldInfoSettings settings;
  final List<String> scanInjections;
  final String personaDescription;
  final String characterDescription;
  final String characterPersonality;
  final String characterDepthPrompt;
  final String scenario;
  final String creatorNotes;
  final String trigger;

  /// ST's character filename identifier, without its image extension.
  final String characterName;

  /// Null means ST has no tag-map entry; an empty list means a known empty one.
  final List<String>? characterTags;
}

/// One admitted entry, including both original and macro-expanded content.
class WorldInfoHit {
  const WorldInfoHit({
    required this.entry,
    required this.content,
    required this.reason,
    required this.phase,
    required this.round,
    this.primaryKey,
    this.secondaryMatches = const [],
    this.probabilityRoll,
  });
  final WorldInfoEntry entry;
  final String content;
  final String reason; // 'constant' or 'keywords'; secondary logic is on entry.
  final String? primaryKey;
  final List<String> secondaryMatches;
  final WorldInfoScanPhase phase;
  final int round;
  final double? probabilityRoll;
  String get bookId => entry.book.id;
  String get uid => entry.uid;
  WorldInfoSource get source => entry.book.source;
  String get originalContent => entry.content;
  num get order => entry.order;
}

class WorldInfoDepth {
  const WorldInfoDepth({required this.depth, required this.role, required this.entries});
  final int depth;
  final int role;
  final List<WorldInfoHit> entries;
  String get content => entries.map((entry) => entry.content).join('\n');
}

class WorldInfoResult {
  WorldInfoResult._(List<WorldInfoHit> hits, {required this.budget, required this.overflowed, required this.scanRounds})
    : activated = List.unmodifiable(hits) {
    final groups = <(int, int), List<WorldInfoHit>>{};
    for (final hit in _stableSort(hits, (a, b) => b.order.compareTo(a.order))) {
      if (hit.content.isEmpty) continue;
      switch (hit.entry.position) {
        case 0:
          before.insert(0, hit);
        case 1:
          after.insert(0, hit);
        case 2:
          authorNoteBefore.insert(0, hit);
        case 3:
          authorNoteAfter.insert(0, hit);
        case 4:
          (groups[(hit.entry.depth, hit.entry.role)] ??= []).insert(0, hit);
        case 5:
          examplesBefore.insert(0, hit);
        case 6:
          examplesAfter.insert(0, hit);
        case 7:
          if (hit.entry.outlet.isNotEmpty) (outlets[hit.entry.outlet] ??= []).add(hit);
      }
    }
    depths = [
      for (final item in groups.entries)
        WorldInfoDepth(depth: item.key.$1, role: item.key.$2, entries: List.unmodifiable(item.value)),
    ];
  }
  final List<WorldInfoHit> activated;
  final before = <WorldInfoHit>[];
  final after = <WorldInfoHit>[];
  final examplesBefore = <WorldInfoHit>[];
  final examplesAfter = <WorldInfoHit>[];
  final authorNoteBefore = <WorldInfoHit>[];
  final authorNoteAfter = <WorldInfoHit>[];
  late final List<WorldInfoDepth> depths;
  final outlets = <String, List<WorldInfoHit>>{};
  final int budget;
  final bool overflowed;
  final int scanRounds;
  String get beforeText => before.map((hit) => hit.content).join('\n');
  String get afterText => after.map((hit) => hit.content).join('\n');
}

class WorldInfoEngine {
  const WorldInfoEngine();

  WorldInfoResult evaluate(WorldInfoInput input) {
    final settings = input.settings;
    // JS Math.round rounds ties toward +infinity, unlike Dart for negatives.
    var budget = (settings.budgetPercent * input.maxContext / 100 + 0.5).floor();
    if (budget == 0) budget = 1;
    if (settings.budgetCap > 0 && budget > settings.budgetCap) budget = settings.budgetCap;
    final sorted = _sortedEntries(input.books, settings.strategy).map(_RuntimeEntry.new).toList();
    final buffer = _ScanBuffer(input);
    final activated = <(String, String), WorldInfoHit>{};
    final failedProbability = <_RuntimeEntry>{};
    final levels = sorted.map((item) => item.entry.delayUntilRecursion).where((level) => level != 0).toSet().toList()
      ..sort();
    var currentLevel = levels.isEmpty ? 0 : levels.removeAt(0);
    var overflowed = false;
    var rounds = 0;
    var activatedText = '';
    WorldInfoScanPhase? phase = sorted.isEmpty ? null : WorldInfoScanPhase.initial;
    while (phase != null) {
      if (settings.maxRecursionSteps != 0 && settings.maxRecursionSteps <= rounds) break;
      rounds++;
      WorldInfoScanPhase? next;
      final candidates = <_RuntimeEntry>[];
      final reasons = <_RuntimeEntry, _MatchReason>{};
      for (final item in sorted) {
        final entry = item.entry;
        if (failedProbability.contains(item) || activated.containsKey(entry.identity) || entry.disabled) continue;
        if (entry.triggers.isNotEmpty && !entry.triggers.contains(input.trigger)) continue;
        if (!_characterAllowed(entry, input)) continue;
        if (phase != WorldInfoScanPhase.recursion && entry.delayUntilRecursion != 0) continue;
        if (phase == WorldInfoScanPhase.recursion &&
            entry.delayUntilRecursion != 0 &&
            entry.delayUntilRecursion > currentLevel) {
          continue;
        }
        if (phase == WorldInfoScanPhase.recursion && settings.recursive && entry.excludeRecursion) continue;
        final reason = entry.constant ? const _MatchReason('constant') : _keywords(entry, buffer, phase, input.expand);
        if (reason != null) {
          candidates.add(item);
          reasons[item] = reason;
        }
      }

      var newContent = '';
      final previousTokens = _tokens(input, activatedText);
      _filterGroups(candidates, activated.values, buffer, phase, input);
      var ignoresBudget = candidates.where((item) => item.entry.ignoreBudget).length;
      for (final item in candidates) {
        final entry = item.entry;
        if (entry.ignoreBudget) ignoresBudget--;
        if (overflowed && !entry.ignoreBudget) {
          if (ignoresBudget > 0) continue;
          break;
        }
        double? roll;
        if (entry.useProbability && entry.probability != 100) {
          roll = _random(input) * 100;
          if (roll > entry.probability) {
            failedProbability.add(item);
            continue;
          }
        }
        item.content = input.expand(item.content);
        newContent += '${item.content}\n';
        if (!entry.ignoreBudget && previousTokens + _tokens(input, newContent) >= budget) {
          overflowed = true;
          continue;
        }
        final reason = reasons[item]!;
        activated[entry.identity] = WorldInfoHit(
          entry: entry,
          content: item.content,
          reason: reason.kind,
          phase: phase,
          round: rounds,
          primaryKey: reason.primary,
          secondaryMatches: reason.secondary,
          probabilityRoll: roll,
        );
      }

      // ST removes only probability failures from this "successful" list.
      // Budget-skipped candidates can enter the buffer when delayed recursion
      // forces another pass; the original book remains untouched.
      final recursiveEntries = candidates
          .where((item) => !failedProbability.contains(item) && !item.entry.preventRecursion)
          .toList();
      if (settings.recursive && !overflowed && recursiveEntries.isNotEmpty) next = WorldInfoScanPhase.recursion;
      if (settings.recursive &&
          !overflowed &&
          phase == WorldInfoScanPhase.minActivations &&
          buffer.recursive.isNotEmpty) {
        next = WorldInfoScanPhase.recursion;
      }
      if (next == null && !overflowed && settings.minActivations > activated.length) {
        final overMax =
            (settings.minActivationsDepthMax > 0 && buffer.depth > settings.minActivationsDepthMax) ||
            buffer.depth > input.messages.length;
        if (!overMax) {
          next = WorldInfoScanPhase.minActivations;
          buffer.skew++;
        }
      }
      if (next == null && levels.isNotEmpty) {
        next = WorldInfoScanPhase.recursion;
        currentLevel = levels.removeAt(0);
      }
      if (next != null) {
        final text = recursiveEntries.map((item) => item.content).join('\n');
        if (text.isNotEmpty) {
          buffer.recursive.add(text);
          activatedText = '$text\n$activatedText';
        }
      }
      phase = next;
    }
    return WorldInfoResult._(activated.values.toList(), budget: budget, overflowed: overflowed, scanRounds: rounds);
  }
}

class _RuntimeEntry {
  _RuntimeEntry(this.entry) : content = entry.content;
  final WorldInfoEntry entry;
  String content;
}

class _MatchReason {
  const _MatchReason(this.kind, {this.primary, this.secondary = const []});
  final String kind;
  final String? primary;
  final List<String> secondary;
}

class _ScanBuffer {
  _ScanBuffer(this.input) {
    var index = 0;
    for (final message in input.messages.reversed.take(1000)) {
      final text = input.settings.includeNames ? '${message.speaker}: ${message.text}' : message.text;
      if (text.isNotEmpty) {
        while (messages.length <= index) {
          messages.add('');
        }
        messages[index] = text.trim();
      }
      index++;
    }
  }
  final WorldInfoInput input;
  final messages = <String>[];
  final recursive = <String>[];
  var skew = 0;
  int get depth => input.settings.scanDepth + skew;

  String get(WorldInfoEntry entry, WorldInfoScanPhase phase) {
    final scanDepth = entry.scanDepth ?? depth;
    if (scanDepth <= 0) return '';
    const joiner = '\n\x01';
    var result = '\x01${messages.take(math.min(scanDepth, 1000)).join(joiner)}';
    final global = {
      'matchPersonaDescription': input.personaDescription,
      'matchCharacterDescription': input.characterDescription,
      'matchCharacterPersonality': input.characterPersonality,
      'matchCharacterDepthPrompt': input.characterDepthPrompt,
      'matchScenario': input.scenario,
      'matchCreatorNotes': input.creatorNotes,
    };
    for (final item in global.entries) {
      if (entry._fields[item.key] == true && item.value.isNotEmpty) result += '$joiner${item.value}';
    }
    final injections = input.scanInjections.where((text) => text.isNotEmpty).toList();
    if (injections.isNotEmpty) result += '$joiner${injections.join(joiner)}';
    if (recursive.isNotEmpty && phase != WorldInfoScanPhase.minActivations) {
      result += '$joiner${recursive.join(joiner)}';
    }
    return result;
  }

  bool matches(String haystack, String needle, WorldInfoEntry entry) {
    final parsed = _keywordRegex(needle);
    if (parsed != null) {
      return parsed.$2 ? parsed.$1.matchAsPrefix(haystack) != null : parsed.$1.hasMatch(haystack);
    }
    if (!(entry.caseSensitive ?? input.settings.caseSensitive)) {
      haystack = haystack.toLowerCase();
      needle = needle.toLowerCase();
    }
    if (!(entry.matchWholeWords ?? input.settings.matchWholeWords) || needle.split(RegExp(r'\s+')).length > 1) {
      return haystack.contains(needle);
    }
    return RegExp('(?:^|\\W)(${RegExp.escape(needle)})(?:\$|\\W)').hasMatch(haystack);
  }

  int score(WorldInfoEntry entry, WorldInfoScanPhase phase) {
    final text = get(entry, phase);
    // ST scoring does not substitute or trim keys, unlike activation matching.
    final primary = entry.keys.where((key) => matches(text, key, entry)).length;
    final secondary = entry.secondaryKeys.where((key) => matches(text, key, entry)).length;
    if (entry.keys.isEmpty) return 0;
    if (entry.secondaryKeys.isNotEmpty &&
        (entry.selectiveLogic == 0 || (entry.selectiveLogic == 3 && secondary == entry.secondaryKeys.length))) {
      return primary + secondary;
    }
    return primary;
  }
}

_MatchReason? _keywords(
  WorldInfoEntry entry,
  _ScanBuffer buffer,
  WorldInfoScanPhase phase,
  String Function(String) expand,
) {
  final text = buffer.get(entry, phase);
  String? primary;
  for (final key in entry.keys) {
    final substituted = expand(key);
    if (substituted.isNotEmpty && buffer.matches(text, substituted.trim(), entry)) {
      primary = key;
      break;
    }
  }
  if (primary == null || primary.isEmpty) return null;
  if (!entry.selective || entry.secondaryKeys.isEmpty) return _MatchReason('keywords', primary: primary);
  var any = false;
  var all = true;
  final matched = <String>[];
  for (final key in entry.secondaryKeys) {
    final substituted = expand(key);
    final found = substituted.isNotEmpty && buffer.matches(text, substituted.trim(), entry);
    if (found) {
      any = true;
      matched.add(key);
    } else {
      all = false;
    }
    if ((entry.selectiveLogic == 0 && found) || (entry.selectiveLogic == 1 && !found)) {
      return _MatchReason('keywords', primary: primary, secondary: matched);
    }
  }
  return (entry.selectiveLogic == 2 && !any) || (entry.selectiveLogic == 3 && all)
      ? _MatchReason('keywords', primary: primary, secondary: matched)
      : null;
}

void _filterGroups(
  List<_RuntimeEntry> candidates,
  Iterable<WorldInfoHit> activated,
  _ScanBuffer buffer,
  WorldInfoScanPhase phase,
  WorldInfoInput input,
) {
  final groups = <String, List<_RuntimeEntry>>{};
  for (final item in candidates) {
    for (final group in item.entry.group.split(RegExp(r',\s*')).where((name) => name.isNotEmpty)) {
      (groups[group] ??= []).add(item);
    }
  }
  // JS uses splice(indexOf(entry), 1), including -1 for entries already removed
  // by another group. Preserve its candidate-only effect for ST parity; see the
  // independent overlapping-group fixture. No original book data is removed.
  void remove(_RuntimeEntry item) {
    if (candidates.isEmpty) return;
    final index = candidates.indexOf(item);
    candidates.removeAt(index < 0 ? candidates.length - 1 : index);
  }

  for (final key in _objectKeys(groups.keys)) {
    final group = groups[key]!;
    if (!input.settings.useGroupScoring && !group.any((item) => item.entry.useGroupScoring == true)) continue;
    final scores = group.map((item) => buffer.score(item.entry, phase)).toList();
    final maximum = scores.reduce(math.max);
    for (var index = 0; index < group.length; index++) {
      if ((group[index].entry.useGroupScoring ?? input.settings.useGroupScoring) && scores[index] < maximum) {
        remove(group[index]);
        group.removeAt(index);
        scores.removeAt(index);
        index--;
      }
    }
  }
  for (final key in _objectKeys(groups.keys)) {
    final group = groups[key]!;
    if (activated.any((hit) => hit.entry.group == key)) {
      for (final item in group) {
        remove(item);
      }
      continue;
    }
    if (group.length <= 1) continue;
    final priority = _stableSort(
      group.where((item) => item.entry.groupOverride).toList(),
      (a, b) => b.entry.order.compareTo(a.entry.order),
    );
    _RuntimeEntry? winner;
    if (priority.isNotEmpty) {
      winner = priority.first;
    } else {
      final weight = group.fold<num>(0, (sum, item) => sum + item.entry.groupWeight);
      final roll = _random(input) * weight;
      num current = 0;
      for (final item in group) {
        current += item.entry.groupWeight;
        if (roll <= current) {
          winner = item;
          break;
        }
      }
    }
    if (winner != null) {
      for (final item in group) {
        if (!identical(item, winner)) remove(item);
      }
    }
  }
}

List<WorldInfoEntry> _sortedEntries(List<WorldInfoBook> books, WorldInfoStrategy strategy) {
  // Loading deduplicates by book identity before applying insertion priorities.
  final bySource = {for (final source in WorldInfoSource.values) source: <WorldInfoEntry>[]};
  final seen = <String>{};
  for (final source in [
    WorldInfoSource.global,
    WorldInfoSource.chat,
    WorldInfoSource.persona,
    WorldInfoSource.character,
    WorldInfoSource.memory,
  ]) {
    for (final book in books.where((book) => book.source == source)) {
      if (seen.add(book.id)) bySource[source]!.addAll(book.entries);
    }
  }
  List<WorldInfoEntry> sort(List<WorldInfoEntry> values) => _stableSort(values, (a, b) => b.order.compareTo(a.order));
  final global = bySource[WorldInfoSource.global]!;
  final character = [...bySource[WorldInfoSource.character]!, ...bySource[WorldInfoSource.memory]!];
  final rest = switch (strategy) {
    WorldInfoStrategy.evenly => sort([...global, ...character]),
    WorldInfoStrategy.characterFirst => [...sort(character), ...sort(global)],
    WorldInfoStrategy.globalFirst => [...sort(global), ...sort(character)],
  };
  return [...sort(bySource[WorldInfoSource.chat]!), ...sort(bySource[WorldInfoSource.persona]!), ...rest];
}

bool _characterAllowed(WorldInfoEntry entry, WorldInfoInput input) {
  final filter = entry._fields['characterFilter'];
  if (filter is! Map<String, Object?>) return true;
  final exclude = filter['isExclude'] == true;
  final names = _strings(filter['names']);
  if (names.isNotEmpty && names.contains(input.characterName) == exclude) return false;
  final tags = _strings(filter['tags']);
  return tags.isEmpty || input.characterTags == null || input.characterTags!.any(tags.contains) != exclude;
}

(RegExp, bool)? _keywordRegex(String key) {
  final match = RegExp(r'^/([\w\W]+?)/([gimsuy]*)$').firstMatch(key);
  if (match == null) return null;
  var pattern = match.group(1)!;
  final flags = match.group(2)!;
  if (flags.split('').toSet().length != flags.length || RegExp(r'(^|[^\\])/').hasMatch(pattern)) return null;
  pattern = pattern.replaceFirst(r'\/', '/');
  try {
    return (
      RegExp(
        pattern,
        caseSensitive: !flags.contains('i'),
        multiLine: flags.contains('m'),
        dotAll: flags.contains('s'),
        unicode: flags.contains('u'),
      ),
      flags.contains('y'),
    );
  } on FormatException {
    return null;
  }
}

Map<String, Object?> _convertCharacterEntry(Map<String, Object?> raw) {
  final extensions = raw['extensions'] is Map<String, Object?>
      ? raw['extensions'] as Map<String, Object?>
      : <String, Object?>{};
  return {
    'key': raw['keys'],
    'keysecondary': raw['secondary_keys'] ?? <Object?>[],
    'content': raw['content'],
    'comment': raw['comment'],
    'constant': raw['constant'] ?? false,
    'selective': raw['selective'] ?? false,
    'order': raw['insertion_order'],
    'position': extensions['position'] ?? (raw['position'] == 'before_char' ? 0 : 1),
    'disable': raw['enabled'] != true,
    for (final item in const {
      'excludeRecursion': 'exclude_recursion',
      'preventRecursion': 'prevent_recursion',
      'delayUntilRecursion': 'delay_until_recursion',
      'probability': 'probability',
      'depth': 'depth',
      'selectiveLogic': 'selectiveLogic',
      'outletName': 'outlet_name',
      'group': 'group',
      'groupOverride': 'group_override',
      'groupWeight': 'group_weight',
      'scanDepth': 'scan_depth',
      'caseSensitive': 'case_sensitive',
      'matchWholeWords': 'match_whole_words',
      'useGroupScoring': 'use_group_scoring',
      'role': 'role',
      'triggers': 'triggers',
      'matchPersonaDescription': 'match_persona_description',
      'matchCharacterDescription': 'match_character_description',
      'matchCharacterPersonality': 'match_character_personality',
      'matchCharacterDepthPrompt': 'match_character_depth_prompt',
      'matchScenario': 'match_scenario',
      'matchCreatorNotes': 'match_creator_notes',
      'ignoreBudget': 'ignore_budget',
    }.entries)
      item.key: extensions[item.value],
    'useProbability': extensions['useProbability'] ?? true,
  };
}

List<T> _stableSort<T>(List<T> items, int Function(T, T) compare) {
  final indexed = [for (var index = 0; index < items.length; index++) (index, items[index])];
  indexed.sort((a, b) {
    final result = compare(a.$2, b.$2);
    return result == 0 ? a.$1.compareTo(b.$1) : result;
  });
  return [for (final item in indexed) item.$2];
}

/// JavaScript Object.keys enumerates array-index keys before other keys.
List<String> _objectKeys(Iterable<String> keys) {
  final indexes = <int>[];
  final others = <String>[];
  for (final key in keys) {
    final value = int.tryParse(key);
    if (value != null && value >= 0 && value < 4294967295 && value.toString() == key) {
      indexes.add(value);
    } else {
      others.add(key);
    }
  }
  indexes.sort();
  return [...indexes.map((value) => '$value'), ...others];
}

int _tokens(WorldInfoInput input, String text) {
  final count = input.tokenCount(text);
  if (count < 0) throw ArgumentError.value(count, 'tokenCount', 'Must return a non-negative count.');
  return count;
}

double _random(WorldInfoInput input) {
  final value = input.random();
  if (!value.isFinite || value < 0 || value >= 1) {
    throw ArgumentError.value(value, 'random', 'Must return 0 <= value < 1.');
  }
  return value;
}

String _identity(String value) => value;
String _string(Object? value) => value is String ? value : '';
num? _number(Object? value) => value is num && value.isFinite ? value : null;
int? _integer(Object? value) => _number(value)?.toInt();
bool? _boolean(Object? value) => value is bool ? value : null;
List<String> _strings(Object? value) => value is List<Object?> ? value.whereType<String>().toList() : [];
String _id(Object value) =>
    value is num && value.isFinite && value == value.truncateToDouble() ? '${value.toInt()}' : '$value';
