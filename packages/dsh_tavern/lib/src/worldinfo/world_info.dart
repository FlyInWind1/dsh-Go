// Port of SillyTavern 1.19.0 public/scripts/world-info.js (AGPL-3.0),
// commit 7e8663cd9c184a550b37238218bdd32c6efc68e9: WorldInfoBuffer,
// getSortedEntries, checkWorldInfo, inclusion groups and convertCharacterBook.
// IO, UI and events remain outside this deterministic evaluator.

import 'dart:convert';
import 'dart:math' as math;

part 'timed_effects.dart';
part 'decorators.dart';

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
  WorldInfoBook._(this.id, this.source, this.raw, this.stWorldName) {
    final original = raw['entries'];
    final byId = <String, (Map<String, Object?>, int)>{};
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
        byId[_id(value['id'] ?? index)] = (value, index);
      }
      for (final uid in _objectKeys(byId.keys)) {
        final item = byId[uid]!;
        parsed.add(WorldInfoEntry._(this, uid, item.$1, _convertCharacterEntry(item.$1, item.$2)));
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
    String? stWorldName,
  }) => WorldInfoBook._(id, source, jsonDecode(jsonEncode(json)) as Map<String, Object?>, stWorldName ?? id);

  final String id;

  /// ST's world filename/name, not the display title. Local IDs may differ.
  final String stWorldName;
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
  bool? get caseSensitive => _boolean(raw['case_sensitive']) ?? _boolean(_fields['caseSensitive']);
  bool get useRegex => raw['use_regex'] == true;
  bool? get matchWholeWords => _boolean(_fields['matchWholeWords']);
  bool? get useGroupScoring => _boolean(_fields['useGroupScoring']);
  List<String> get triggers => _strings(_fields['triggers']);

  /// Exact ST loader hash, including field order and the original ST decorator parser.
  int get stHash => _entryHash(this);
  String get stKey =>
      '${_fields.containsKey('world') ? _jsString(_fields['world']) : book.stWorldName}.'
      '${_fields.containsKey('uid') ? _jsString(_fields['uid']) : 'undefined'}';
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
    this.timedWorldInfo = const {},
    this.dryRun = false,
    this.decoratorState = const {},
    this.assistantMessageCount,
    this.greetingIndex,
    this.userIconName,
    this.contextAtCapacity,
    this.postProcessContent,
    this.availablePromptSections,
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

  /// The selected branch's chat_metadata.timedWorldInfo, before this evaluation.
  final Map<String, Object?> timedWorldInfo;

  /// ST preview semantics: ignore sticky/cooldown, still check delay, do not add timers.
  final bool dryRun;

  /// Proven prior V3 admissions for this selected branch, keyed by ST entry hash.
  final Map<String, Object?> decoratorState;

  /// Null means unavailable: count-dependent decorators are ignored, including fallbacks.
  final int? assistantMessageCount;
  final int? greetingIndex;

  /// V3 asset name, never inferred from an avatar filesystem path.
  final String? userIconName;

  /// Null means the caller cannot determine full-prompt capacity. False also
  /// allows an assembler to honor ignore_on_max_context by trimming first.
  final bool? contextAtCapacity;

  /// ST applies world-info prompt regex after admission and recursion, in
  /// descending insertion order. Only an at-depth entry receives a depth.
  final String Function(WorldInfoEntry entry, String content, int? depth)? postProcessContent;

  /// Actual enabled card slots in the current preset. Null leaves section
  /// availability to the supplied nonempty character fields for standalone use.
  final Set<String>? availablePromptSections;
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
    this.positionOverride,
    this.depthOverride,
    this.roleOverride,
    this.section,
    this.disabledUiPrompt,
    this.ignoreOnMaxContext = false,
    this.assistantPrefill = false,
  });
  final WorldInfoEntry entry;
  final String content;
  final String reason; // constant, keywords, sticky, decorator-activate or decorator-keep.
  final String? primaryKey;
  final List<String> secondaryMatches;
  final WorldInfoScanPhase phase;
  final int round;
  final double? probabilityRoll;
  final int? positionOverride;
  final int? depthOverride;
  final int? roleOverride;
  final String? section;
  final String? disabledUiPrompt;
  final bool ignoreOnMaxContext;

  /// Explicit V3 assistant role at raw depth zero, before depth clamping.
  final bool assistantPrefill;
  int? get position => positionOverride ?? entry.position;
  int get depth => depthOverride ?? entry.depth;
  int get role => roleOverride ?? entry.role;
  String get bookId => entry.book.id;
  String get uid => entry.uid;
  WorldInfoSource get source => entry.book.source;
  String get originalContent => entry.content;
  num get order => entry.order;
  WorldInfoHit withContent(String value) => WorldInfoHit(
    entry: entry,
    content: value,
    reason: reason,
    phase: phase,
    round: round,
    primaryKey: primaryKey,
    secondaryMatches: secondaryMatches,
    probabilityRoll: probabilityRoll,
    positionOverride: positionOverride,
    depthOverride: depthOverride,
    roleOverride: roleOverride,
    section: section,
    disabledUiPrompt: disabledUiPrompt,
    ignoreOnMaxContext: ignoreOnMaxContext,
    assistantPrefill: assistantPrefill,
  );
}

class WorldInfoDepth {
  const WorldInfoDepth({required this.depth, required this.role, required this.entries});
  final int depth;
  final int role;
  final List<WorldInfoHit> entries;
  String get content => entries.map((entry) => entry.content).join('\n');
}

class WorldInfoResult {
  WorldInfoResult._(
    List<WorldInfoHit> hits, {
    required this.budget,
    required this.overflowed,
    required this.scanRounds,
    required this.timedWorldInfo,
    required this.decoratorState,
    required WorldInfoResult Function(List<WorldInfoHit>) finalize,
  }) : _finalize = finalize,
       activated = List.unmodifiable(hits) {
    final groups = <(int, int), List<WorldInfoHit>>{};
    for (final hit in _stableSort(hits, (a, b) => b.order.compareTo(a.order))) {
      if (hit.disabledUiPrompt case final prompt?) disabledUiPrompts.add(prompt);
      if (hit.content.isEmpty) continue;
      if (hit.section case final section?) {
        (sections[section] ??= []).insert(0, hit);
        continue;
      }
      switch (hit.position) {
        case 0:
          before.insert(0, hit);
        case 1:
          after.insert(0, hit);
        case 2:
          authorNoteBefore.insert(0, hit);
        case 3:
          authorNoteAfter.insert(0, hit);
        case 4:
          (groups[(hit.depth, hit.role)] ??= []).insert(0, hit);
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
  final Map<String, Object?> timedWorldInfo;
  final Map<String, Object?> decoratorState;
  final WorldInfoResult Function(List<WorldInfoHit>) _finalize;

  /// Finalize state after the prompt assembler drops optional V3 entries.
  /// This never rescans, expands a macro, consumes entropy, or admits a new hit.
  WorldInfoResult withoutEntries(Set<(String, String)> identities) => identities.isEmpty
      ? this
      : _finalize(activated.where((hit) => !identities.contains(hit.entry.identity)).toList());
  final sections = <String, List<WorldInfoHit>>{};
  final disabledUiPrompts = <String>{};
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
    final sorted = _sortedEntries(input.books, settings.strategy).map((entry) => _RuntimeEntry(entry, input)).toList();
    final timed = _TimedEffects(input, sorted);
    final decoratorHistory = _DecoratorHistory(input);
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
        final sticky = timed.isActive('sticky', item);
        if (timed.isActive('delay', item) || (timed.isActive('cooldown', item) && !sticky)) continue;
        if (!sticky && phase != WorldInfoScanPhase.recursion && entry.delayUntilRecursion != 0) continue;
        if (phase == WorldInfoScanPhase.recursion &&
            entry.delayUntilRecursion != 0 &&
            entry.delayUntilRecursion > currentLevel &&
            !sticky) {
          continue;
        }
        if (phase == WorldInfoScanPhase.recursion && settings.recursive && entry.excludeRecursion && !sticky) continue;
        final decorators = item.decorators;
        _MatchReason? reason;
        if (decorators.activate) {
          reason = const _MatchReason('decorator-activate');
        } else {
          final matchedBefore = decoratorHistory.previous(item) > 1;
          if (decorators.dontActivate || (decorators.dontAfterMatch && matchedBefore)) continue;
          if (decorators.keepAfterMatch && matchedBefore) {
            reason = const _MatchReason('decorator-keep');
          } else {
            if (!decorators.allows(buffer, phase)) continue;
            reason = entry.constant && !entry.useRegex
                ? const _MatchReason('constant')
                : sticky
                ? const _MatchReason('sticky')
                : _keywords(entry, buffer, phase, input.expand, scanDepth: decorators.scanDepth);
          }
        }
        if (reason?.kind == 'sticky' && entry.useRegex) {
          // Sticky is an ST extension, not a V3 IN ANY CASE decorator. It may
          // bypass a missing match, but not the validity of primary regexes.
          final keys = entry.keys.map(input.expand).toList();
          if (keys.any((key) => _v3Regex(key, entry) == null)) continue;
        }
        if (reason != null) {
          candidates.add(item);
          reasons[item] = reason;
        }
      }

      var newContent = '';
      final previousTokens = _tokens(input, activatedText);
      final prioritized = _stableSort(
        candidates,
        (a, b) => (timed.isActive('sticky', b) ? 1 : 0) - (timed.isActive('sticky', a) ? 1 : 0),
      );
      candidates
        ..clear()
        ..addAll(prioritized);
      _filterGroups(candidates, activated.values, buffer, phase, input, timed);
      var ignoresBudget = candidates.where((item) => item.entry.ignoreBudget).length;
      for (final item in candidates) {
        final entry = item.entry;
        if (entry.ignoreBudget) ignoresBudget--;
        if (overflowed && !entry.ignoreBudget) {
          if (ignoresBudget > 0) continue;
          break;
        }
        double? roll;
        if (entry.useProbability && entry.probability != 100 && !timed.isActive('sticky', item)) {
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
          positionOverride: item.decorators.depth == null ? null : 4,
          depthOverride: item.decorators.depth,
          roleOverride: item.decorators.role,
          section: item.decorators.section,
          disabledUiPrompt: item.decorators.disabledUiPrompt,
          ignoreOnMaxContext: item.decorators.ignoreOnMaxContext,
          assistantPrefill: item.decorators.assistantPrefill,
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
    final transform = input.postProcessContent;
    if (transform != null) {
      for (final hit in _stableSort(activated.values.toList(), (a, b) => b.order.compareTo(a.order))) {
        activated[hit.entry.identity] = hit.withContent(
          transform(hit.entry, hit.content, hit.section == null && hit.position == 4 ? hit.depth : null),
        );
      }
    }
    // Keep the post-expiry, pre-admission state. Optional V3 entries can later
    // be removed by the full-prompt budget without repeating this scan or any
    // macro/regex/random side effect, or accidentally retaining their timers.
    WorldInfoResult finalize(List<WorldInfoHit> hits) {
      final effects = timed.fork()..finish(hits);
      final history = decoratorHistory.fork();
      final retained = hits.map((hit) => hit.entry.identity).toSet();
      history.finish(sorted.where((item) => retained.contains(item.entry.identity)));
      return WorldInfoResult._(
        hits,
        budget: budget,
        overflowed: overflowed,
        scanRounds: rounds,
        timedWorldInfo: effects.state,
        decoratorState: history.state,
        finalize: finalize,
      );
    }

    return finalize(activated.values.toList());
  }
}

class _RuntimeEntry {
  _RuntimeEntry(this.entry, WorldInfoInput input) : decorators = _Decorators(entry, input), hash = _entryHash(entry) {
    content = decorators.content;
  }
  final WorldInfoEntry entry;
  final int hash;
  final _Decorators decorators;
  late String content;
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

  String get(WorldInfoEntry entry, WorldInfoScanPhase phase, {int? scanDepth}) {
    final effectiveDepth = scanDepth ?? entry.scanDepth ?? depth;
    if (effectiveDepth <= 0) return '';
    const joiner = '\n\x01';
    var result = '\x01${messages.take(math.min(effectiveDepth, 1000)).join(joiner)}';
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
    if (entry.useRegex) {
      final parsed = _v3Regex(needle, entry, caseSensitive: input.settings.caseSensitive);
      return parsed != null && (parsed.$2 ? parsed.$1.matchAsPrefix(haystack) != null : parsed.$1.hasMatch(haystack));
    }
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

  int score(WorldInfoEntry entry, WorldInfoScanPhase phase, {int? scanDepth}) {
    final text = get(entry, phase, scanDepth: scanDepth);
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
  String Function(String) expand, {
  int? scanDepth,
}) {
  final text = buffer.get(entry, phase, scanDepth: scanDepth);
  if (entry.useRegex) {
    final expanded = [for (final key in entry.keys) (key, expand(key))];
    if (expanded.any((key) => _v3Regex(key.$2, entry) == null)) return null;
    for (final key in expanded) {
      if (buffer.matches(text, key.$2, entry)) return _MatchReason('keywords', primary: key.$1);
    }
    return null;
  }
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
  _TimedEffects timed,
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

  final stickyGroups = <String>{};
  for (final key in _objectKeys(groups.keys)) {
    final group = groups[key]!;
    final sticky = group.where((item) => timed.isActive('sticky', item)).toSet();
    if (sticky.isNotEmpty) {
      for (final item in group) {
        if (!sticky.contains(item)) remove(item);
      }
      stickyGroups.add(key);
    }
    // ST also removes sticky entries if they are simultaneously on cooldown.
    // This group-specific behavior intentionally differs from candidate filtering.
    for (final item in group) {
      if (timed.isActive('cooldown', item)) remove(item);
    }
    for (final item in group) {
      if (timed.isActive('delay', item)) remove(item);
    }
  }
  for (final key in _objectKeys(groups.keys)) {
    final group = groups[key]!;
    if (stickyGroups.contains(key)) continue;
    if (!input.settings.useGroupScoring && !group.any((item) => item.entry.useGroupScoring == true)) continue;
    final scores = group.map((item) => buffer.score(item.entry, phase, scanDepth: item.decorators.scanDepth)).toList();
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
    if (stickyGroups.contains(key)) continue;
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

Map<String, Object?> _convertCharacterEntry(Map<String, Object?> raw, int index) {
  final extensions = _object(raw['extensions']);
  // Property insertion order is ST's template order. It participates in timer hashes.
  final result = <String, Object?>{
    'key': <Object?>[],
    'keysecondary': <Object?>[],
    'comment': '',
    'content': '',
    'constant': false,
    'vectorized': false,
    'selective': true,
    'selectiveLogic': 0,
    'addMemo': false,
    'order': 100,
    'position': 0,
    'disable': false,
    'ignoreBudget': false,
    'excludeRecursion': false,
    'preventRecursion': false,
    'matchPersonaDescription': false,
    'matchCharacterDescription': false,
    'matchCharacterPersonality': false,
    'matchCharacterDepthPrompt': false,
    'matchScenario': false,
    'matchCreatorNotes': false,
    'delayUntilRecursion': 0,
    'probability': 100,
    'useProbability': true,
    'depth': 4,
    'outletName': '',
    'group': '',
    'groupOverride': false,
    'groupWeight': 100,
    'scanDepth': null,
    'caseSensitive': null,
    'matchWholeWords': null,
    'useGroupScoring': null,
    'automationId': '',
    'role': 0,
    'sticky': null,
    'cooldown': null,
    'delay': null,
    'triggers': <Object?>[],
  };
  result.addAll({
    'uid': raw.containsKey('id') ? raw['id'] : index,
    'key': raw['keys'],
    'keysecondary': raw['secondary_keys'] ?? <Object?>[],
    'comment': raw['comment'] ?? '',
    'content': raw['content'],
    'constant': raw['constant'] ?? false,
    'selective': raw['selective'] ?? false,
    'order': raw['insertion_order'],
    'position': extensions['position'] ?? (raw['position'] == 'before_char' ? 0 : 1),
    'excludeRecursion': extensions['exclude_recursion'] ?? false,
    'preventRecursion': extensions['prevent_recursion'] ?? false,
    'delayUntilRecursion': extensions['delay_until_recursion'] ?? false,
    'disable': raw['enabled'] != true,
    'addMemo': _truthy(raw['comment']),
    'displayIndex': extensions['display_index'] ?? index,
    'probability': extensions['probability'] ?? 100,
    'useProbability': extensions['useProbability'] ?? true,
    'depth': extensions['depth'] ?? 4,
    'selectiveLogic': extensions['selectiveLogic'] ?? 0,
    'outletName': extensions['outlet_name'] ?? '',
    'group': extensions['group'] ?? '',
    'groupOverride': extensions['group_override'] ?? false,
    'groupWeight': extensions['group_weight'] ?? 100,
    'scanDepth': extensions['scan_depth'],
    'caseSensitive': extensions['case_sensitive'],
    'matchWholeWords': extensions['match_whole_words'],
    'useGroupScoring': extensions['use_group_scoring'],
    'automationId': extensions['automation_id'] ?? '',
    'role': extensions['role'] ?? 0,
    'vectorized': extensions['vectorized'] ?? false,
    'sticky': extensions['sticky'],
    'cooldown': extensions['cooldown'],
    'delay': extensions['delay'],
    'matchPersonaDescription': extensions['match_persona_description'] ?? false,
    'matchCharacterDescription': extensions['match_character_description'] ?? false,
    'matchCharacterPersonality': extensions['match_character_personality'] ?? false,
    'matchCharacterDepthPrompt': extensions['match_character_depth_prompt'] ?? false,
    'matchScenario': extensions['match_scenario'] ?? false,
    'matchCreatorNotes': extensions['match_creator_notes'] ?? false,
    'extensions': extensions,
    'triggers': extensions['triggers'] ?? <Object?>[],
    'ignoreBudget': extensions['ignore_budget'] ?? false,
  });
  // JSON.stringify omits undefined assignments in converted incomplete cards.
  for (final pair in [('keys', 'key'), ('insertion_order', 'order')]) {
    if (!raw.containsKey(pair.$1)) result.remove(pair.$2);
  }
  return result;
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
String _id(Object value) => _jsString(value);
