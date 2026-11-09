// Adapted from SillyTavern public/scripts/openai.js, PromptManager.js and
// public/script.js (AGPL-3.0).
// Source commit: 7e8663cd9c184a550b37238218bdd32c6efc68e9 (1.19.0).
import 'dart:convert';

import 'character_fields.dart';
import 'deepseek_processing.dart';
import 'preset.dart';
import 'prompt_types.dart';

final class PromptInput {
  const PromptInput({
    required this.preset,
    required this.card,
    required this.history,
    required this.model,
    this.userName = 'User',
    this.characterId = '',
    this.generationType = 'normal',
    this.deepseek = true,
    this.persona = '',
    this.personaInPrompt = true,
    this.groupNames = const [],
    this.worldBefore = const [],
    this.worldAfter = const [],
    this.injections = const [],
    this.examplesBefore = '',
    this.examplesAfter = '',
    this.worldExamples = const [],
    this.pinExamples = false,
    this.stripExamples = false,
    this.quietPrompt = '',
    this.bias = '',
    this.stops = const [],
    this.tools = const [],
    this.toolChoice,
    this.expansion,
    this.cardExpansion,
    this.preparedFields,
  });
  final ChatPreset preset;

  /// V3 `data`, with any per-chat field overrides already applied.
  final Map<String, Object?> card;

  /// Chronological order. Hidden and ST is_system messages are excluded here.
  final List<PromptHistoryMessage> history;
  final String model;
  final String userName;
  final String characterId;
  final String generationType;
  final bool deepseek;
  final String persona;
  final bool personaInPrompt;
  final List<String> groupNames;
  final List<PromptFragment> worldBefore;
  final List<PromptFragment> worldAfter;
  final List<PromptInjection> injections;
  final String examplesBefore;
  final String examplesAfter;
  final List<PromptExample> worldExamples;
  final bool pinExamples;
  final bool stripExamples;
  final String quietPrompt;
  final String bias;
  final List<String> stops;
  final List<Map<String, Object?>> tools;
  final Object? toolChoice;

  /// Normal substitution with fresh lazy raw-card fields on every invocation.
  /// Overrides contain only temporary values such as original/lastChatMessage.
  final PromptExpansion? expansion;

  /// ST baseChatReplace: names/variables enabled, character-field lookup off.
  /// Full macro integrations should supply both callbacks. Without either,
  /// assembly uses a limited names/fields fallback and retains unknown macros.
  final PromptExpansion? cardExpansion;
  final PreparedCharacterFields? preparedFields;
}

final class PromptAssembler {
  const PromptAssembler({this.counter = const EstimatedTokenCounter()});
  final PromptTokenCounter counter;
  PromptAssembly assemble(PromptInput input) => _AssemblyRun(input, counter).run();
}

final class _Prompt {
  _Prompt(
    this.id,
    this.content,
    this.sources, {
    this.role = 'system',
    this.data = const {},
    this.injected = false,
    this.placement,
    this.extension = false,
  });
  final String id;
  String content;
  List<PromptSource> sources;
  String role;
  Map<String, Object?> data;
  final bool injected;
  PromptPlacement? placement;
  bool extension;
  bool get absolute => data['injection_position'] == 1;
  int? get depth {
    final value = data['injection_depth'];
    if (value is! num || value < 0 || value > 10000 || value != value.truncateToDouble()) return null;
    return value.toInt();
  }

  num get order => data['injection_order'] is num
      ? data['injection_order'] as num
      : num.tryParse('${data['injection_order']}') ?? 100;
  _Prompt copy() => _Prompt(
    id,
    content,
    [...sources],
    role: role,
    data: {...data},
    injected: injected,
    placement: placement,
    extension: extension,
  );
}

final class _AssemblyRun {
  _AssemblyRun(this.input, this.counter) : settings = input.preset.settings {
    type = input.generationType.trim().toLowerCase();
    if (type.isEmpty) type = 'normal';
    final nickname = input.card['nickname'];
    characterName = nickname is String && nickname.isNotEmpty ? nickname : field('name');
    budget = number('openai_max_context', 4095) - number('openai_max_tokens', 300);
    remaining = budget - 3;
  }
  final PromptInput input;
  final PromptTokenCounter counter;
  final Map<String, Object?> settings;
  late final String characterName;
  late String type;
  late final int budget;
  late int remaining;
  final prompts = <_Prompt>[];
  final collections = <String, List<PromptSegment>>{};
  final tail = <PromptSegment>[];
  final excluded = <PromptExclusion>[];
  final disabled = <String>{};
  final cardFields = <String, String>{};
  final exampleBlocks = <(List<Map<String, Object?>>, PromptSource)>[];
  String persona = '';

  int number(String key, int fallback) => (settings[key] as num?)?.toInt() ?? fallback;
  String setting(String key) => settings[key] as String? ?? '';
  String field(String key) => cardFields[key] ?? (input.card[key] as String? ?? '');
  _Prompt? get(String id) => prompts.where((prompt) => prompt.id == id).firstOrNull;

  String expand(String text, [Map<String, String> overrides = const {}]) {
    // A full macro engine creates fresh lazy card getters for every call. Only
    // temporary values (e.g. original) may override that environment.
    if (input.expansion != null) return input.expansion!(text, overrides);
    return fallbackExpand(text, overrides);
  }

  String baseExpand(String text) =>
      (input.cardExpansion ?? input.expansion)?.call(text, const {}) ??
      fallbackExpand(text, const {}, replaceCharacterCard: false);

  String fallbackExpand(String text, Map<String, String> overrides, {bool replaceCharacterCard = true}) {
    final group = input.groupNames.isEmpty ? characterName : input.groupNames.join(', ');
    String cardValue(String key) => replaceCharacterCard ? field(key) : '';
    final values = <String, String>{
      'user': input.userName,
      'char': characterName,
      'charIfNotGroup': group,
      'group': group,
      'description': cardValue('description'),
      'personality': cardValue('personality'),
      'scenario': cardValue('scenario'),
      'charDescription': cardValue('description'),
      'charPersonality': cardValue('personality'),
      'charScenario': cardValue('scenario'),
      'persona': replaceCharacterCard ? persona : '',
      'model': input.model,
      ...overrides,
    };
    final normalized = {for (final entry in values.entries) entry.key.toLowerCase(): entry.value};
    var originalUsed = false;
    return text.replaceAllMapped(RegExp(r'\{\{([^{}]+)\}\}'), (match) {
      final name = match[1]!.trim().toLowerCase();
      if (name == 'original' && normalized.containsKey(name)) {
        if (originalUsed) return '';
        originalUsed = true;
      }
      return normalized[name] ?? match[0]!;
    });
  }

  PromptSegment message(_Prompt prompt, {bool expandText = false, bool includeName = false}) {
    final content = expandText ? expand(prompt.content) : prompt.content;
    final data = <String, Object?>{'role': prompt.role, 'content': content};
    final name = prompt.data['name'];
    if (includeName && name is String && name.isNotEmpty) data['name'] = sanitizeName(name);
    if (prompt.data['tool_calls'] != null) data['tool_calls'] = prompt.data['tool_calls'];
    if (prompt.data['tool_call_id'] != null) data['tool_call_id'] = prompt.data['tool_call_id'];
    return PromptSegment(id: prompt.id, message: data, sources: prompt.sources, tokens: counter.countMessage(data));
  }

  void reserve(PromptSegment segment) => remaining -= segment.tokens;
  void spend(PromptSegment segment) {
    if (segment.tokens > remaining) throw PromptBudgetExceeded(segment.id, segment.tokens, remaining);
    remaining -= segment.tokens;
  }

  bool meaningful(PromptSegment segment) =>
      segment.message['content'] != '' || segment.message.containsKey('tool_calls');
  void addFixed(String id) {
    final prompt = get(id);
    if (prompt == null || prompt.absolute || (disabled.contains(id) && id != 'main')) return;
    final segment = message(prompt);
    spend(segment);
    collections[id] = [segment];
  }

  void prepare() {
    final prepared =
        input.preparedFields ??
        prepareCharacterFields(input.card, persona: input.persona, expand: (text, _) => baseExpand(text));
    cardFields.addAll(prepared.values);
    persona = prepared.persona;
    prepareExamples();
    final scenario = field('scenario').isNotEmpty && setting('scenario_format').isNotEmpty
        ? expand(setting('scenario_format'))
        : field('scenario');
    final personality = field('personality').isNotEmpty && setting('personality_format').isNotEmpty
        ? expand(setting('personality_format'))
        : field('personality');
    final groupNudge = expand(setting('group_nudge_prompt'));
    final impersonate = expand(setting('impersonation_prompt'));
    final definitions = (settings['prompts'] as List<Object?>).whereType<Map<String, Object?>>().toList();
    final group = (settings['prompt_order'] as List<Object?>).whereType<Map<String, Object?>>().firstWhere(
      (group) => '${group['character_id']}' == '100001',
    );
    final order = (group['order'] as List<Object?>).whereType<Map<String, Object?>>();
    final seenOrder = <String>{};
    for (final entry in order) {
      final id = entry['identifier'] as String? ?? '';
      final definition = definitions.where((prompt) => prompt['identifier'] == id).firstOrNull;
      if (seenOrder.add(id) && entry['enabled'] != true) disabled.add(id);
      if (definition == null) continue;
      final triggers = definition['injection_trigger'];
      final allowed =
          entry['enabled'] == true && (triggers is! List<Object?> || triggers.isEmpty || triggers.contains(type));
      final source = PromptSource('preset', id, label: definition['name'] as String? ?? id);
      if (!allowed && id != 'main') {
        excluded.add(PromptExclusion(id, disabled.contains(id) ? 'disabled' : 'generation-trigger', [source]));
        continue;
      }
      prompts.add(
        _Prompt(
          id,
          expand(allowed ? definition['content'] as String? ?? '' : ''),
          [source],
          role: definition['role'] as String? ?? 'system',
          data: {...definition},
        ),
      );
    }

    _Prompt marker(String id, String content, List<PromptSource> sources, {String role = 'system'}) {
      final existing = get(id);
      final metadata = <String, Object?>{};
      for (final key in ['injection_position', 'injection_depth', 'injection_order']) {
        if (existing?.data[key] != null) metadata[key] = existing!.data[key];
      }
      final replacement = _Prompt(id, expand(content), sources, role: existing?.role ?? role, data: metadata);
      if (existing == null) {
        prompts.add(replacement);
      } else {
        prompts[prompts.indexOf(existing)] = replacement;
      }
      return replacement;
    }

    String world(List<PromptFragment> fragments) {
      final text = fragments.map((fragment) => fragment.content).join('\n');
      if (text.isEmpty || setting('wi_format').trim().isEmpty) return text;
      return setting('wi_format').replaceAll('{0}', text);
    }

    PromptSource cardSource(String key) => PromptSource('card', '${input.characterId}:$key', label: key);
    marker('worldInfoBefore', world(input.worldBefore), input.worldBefore.map((fragment) => fragment.source).toList());
    marker('worldInfoAfter', world(input.worldAfter), input.worldAfter.map((fragment) => fragment.source).toList());
    marker('charDescription', field('description'), [cardSource('description')]);
    marker('charPersonality', personality, [cardSource('personality')]);
    marker('scenario', scenario, [cardSource('scenario')]);
    marker('impersonate', impersonate, const [PromptSource('control', 'impersonation_prompt')]);
    marker('quietPrompt', input.quietPrompt, const [PromptSource('control', 'quietPrompt')]);
    marker('groupNudge', groupNudge, const [PromptSource('control', 'group_nudge_prompt')]);
    marker('bias', input.bias, const [PromptSource('control', 'bias')], role: 'assistant');
    const knownExtensions = {
      '1_memory': 'summary',
      '2_floating_prompt': 'authorsNote',
      '3_vectors': 'vectorsMemory',
      '4_vectors_data_bank': 'vectorsDataBank',
      'chromadb': 'smartContext',
    };
    void extension(PromptInjection injection, String id, {bool forceSystem = false, bool unknown = false}) {
      final prompt = marker(id, injection.fragment.content, [
        injection.fragment.source,
      ], role: forceSystem ? 'system' : injection.role);
      prompt.placement = injection.placement == PromptPlacement.inChat ? null : injection.placement;
      prompt.extension = unknown;
    }

    // ST prepares known extensions even when their relative position is false
    // (e.g. an in-chat author's note). That early macro pass is observable.
    for (final entry in knownExtensions.entries) {
      final injection = input.injections.where((item) => item.fragment.source.id == entry.key).firstOrNull;
      if (injection != null && injection.fragment.content.isNotEmpty) {
        extension(injection, entry.value, forceSystem: entry.key == '3_vectors' || entry.key == 'chromadb');
      }
    }
    if (input.persona.isNotEmpty && input.personaInPrompt) {
      marker('personaDescription', input.persona, const [PromptSource('persona', 'description')]);
    }
    for (final injection in input.injections) {
      final key = injection.fragment.source.id;
      if (injection.placement == PromptPlacement.inChat ||
          injection.fragment.content.isEmpty ||
          knownExtensions.containsKey(key) ||
          const {'PERSONA_DESCRIPTION', 'QUIET_PROMPT', 'DEPTH_PROMPT'}.contains(key)) {
        continue;
      }
      extension(injection, key.replaceAll(RegExp(r'\W'), '_'), unknown: true);
    }
    for (final pair in [('main', 'system_prompt'), ('jailbreak', 'post_history_instructions')]) {
      final prompt = get(pair.$1);
      if (prompt != null &&
          !disabled.contains(pair.$1) &&
          prompt.data['forbid_overrides'] != true &&
          field(pair.$2).isNotEmpty) {
        prompt.content = expand(field(pair.$2), {'original': prompt.content});
        prompt.sources = [cardSource(pair.$2), ...prompt.sources];
      }
    }
  }

  PromptAssembly run() {
    prepare();
    for (final id in [
      'worldInfoBefore',
      'main',
      'worldInfoAfter',
      'charDescription',
      'charPersonality',
      'scenario',
      'personaDescription',
    ]) {
      addFixed(id);
    }
    final controls = <PromptSegment>[];
    if (type == 'impersonate') controls.add(message(get('impersonate')!));
    if (get('quietPrompt')!.content.isNotEmpty) controls.add(message(get('quietPrompt')!));
    for (final control in controls) {
      reserve(control);
    }
    final relativeIds = prompts.where((p) => p.data['system_prompt'] == false && !p.absolute).map((p) => p.id);
    for (final id in ['nsfw', 'jailbreak', ...relativeIds, 'enhanceDefinitions']) {
      addFixed(id);
    }
    if (input.bias.trim().isNotEmpty) addFixed('bias');
    final absolute = prompts.where((prompt) => prompt.absolute).map((prompt) => prompt.copy()).toList();
    final depthExtensions = input.injections
        .where((injection) => injection.placement == PromptPlacement.inChat && injection.fragment.content.isNotEmpty)
        .toList();
    // Resolve the final collection after identifier normalization/replacement.
    // ST intentionally has separate known and extension loops: an unknown key
    // which replaces a known id can therefore be injected by both loops.
    final relativeInjections = <_Prompt>[
      for (final id in ['summary', 'authorsNote', 'vectorsMemory', 'vectorsDataBank', 'smartContext'])
        if (get(id)?.placement != null) get(id)!,
      ...prompts.where((prompt) => prompt.extension && prompt.placement != null),
    ];
    for (final prepared in relativeInjections) {
      final placement = prepared.placement!;
      final prompt = prepared.copy();
      final mainCollection = collections['main'];
      if (mainCollection != null) {
        final segment = message(prompt);
        spend(segment);
        if (placement == PromptPlacement.beforeMain) {
          mainCollection.insert(0, segment);
        } else {
          mainCollection.add(segment);
        }
      } else {
        final mainIndex = absolute.indexWhere((prompt) => prompt.id == 'main');
        if (mainIndex >= 0) {
          final main = absolute[mainIndex];
          prompt.role = main.role;
          prompt.data = {...main.data};
          absolute.insert(mainIndex + (placement == PromptPlacement.afterMain ? 1 : 0), prompt);
        }
      }
    }
    if (input.tools.isNotEmpty) {
      final toolData = {'tools': input.tools, if (input.toolChoice != null) 'tool_choice': input.toolChoice};
      remaining -= counter.countMessage({'role': 'user', 'content': jsonEncode(toolData)});
    }
    var history = historyPrompts();
    var cyclePrompt = input.history.where((item) => !item.hidden && !item.isSystem).lastOrNull?.content ?? '';
    if (type == 'continue' && !cyclePrompt.endsWith(' ')) cyclePrompt += setting('continue_postfix');
    if (type == 'continue' && settings['continue_prefill'] == true && history.isNotEmpty) {
      final last = history.removeLast();
      final prefill = message(
        _Prompt('continuePrefill', last.content, last.sources, role: last.role, data: last.data),
        includeName: number('names_behavior', 0) == 1,
      );
      controls.add(prefill);
      reserve(prefill);
    }
    history = injectDepth(absolute, depthExtensions, history);
    if (input.pinExamples) {
      addExamples();
      addHistory(history, cyclePrompt);
    } else {
      addHistory(history, cyclePrompt);
      addExamples();
    }
    for (final control in controls) {
      remaining += control.tokens;
      spend(control);
    }
    tail.addAll(controls);
    var flattened = <PromptSegment>[
      for (final id in prompts.map((prompt) => prompt.id).toSet()) ...?collections[id],
      ...tail,
    ];
    if (settings['squash_system_messages'] == true) flattened = squash(flattened);
    final before = flattened.where(meaningful).toList();
    final after = input.deepseek
        ? postProcessDeepSeek(
            before,
            userName: input.userName,
            characterName: characterName,
            groupNames: input.groupNames,
            tools: input.tools,
            counter: counter,
          )
        : before;
    final stops = input.stops.where((stop) => stop.isNotEmpty).map((stop) => expand(stop)).toList();
    final body = input.deepseek
        ? deepSeekRequestBody(
            messages: after,
            settings: settings,
            model: input.model,
            generationType: type,
            stops: stops,
            tools: input.tools,
            toolChoice: input.toolChoice,
          )
        : genericBody(after, stops);
    return PromptAssembly(
      body: body,
      beforePostProcessing: before,
      afterPostProcessing: after,
      excluded: excluded,
      budget: budget,
      remainingBudget: remaining,
      counterName: counter.name,
      exactTokenCounts: counter.exact,
    );
  }

  List<_Prompt> historyPrompts() {
    final result = <_Prompt>[];
    final names = number('names_behavior', 0);
    for (final item in input.history) {
      final sources = [PromptSource('history', item.id, label: item.name)];
      if (item.hidden || item.isSystem) {
        excluded.add(PromptExclusion(item.id, item.hidden ? 'hidden' : 'is_system', sources));
        continue;
      }
      final role = item.role == 'narrator' ? 'system' : item.role;
      var content = item.content;
      if ((names == 2 && role != 'system') ||
          (names == 0 &&
              item.name != input.userName &&
              (input.groupNames.isNotEmpty || (item.forceAvatar && role != 'system')))) {
        content = '${item.name}: $content';
      }
      result.add(
        _Prompt(
          item.id,
          content.replaceAll('\r', ''),
          sources,
          role: role,
          data: {
            'name': item.name,
            if (item.toolCalls != null) 'tool_calls': item.toolCalls,
            if (item.toolCallId != null) 'tool_call_id': item.toolCallId,
          },
        ),
      );
    }
    return result;
  }

  List<_Prompt> injectDepth(List<_Prompt> absolute, List<PromptInjection> extensions, List<_Prompt> history) {
    final reversed = history.reversed.toList();
    final depths = <int>{
      for (final p in absolute)
        if (p.depth != null && p.depth! >= 0 && p.content.isNotEmpty) p.depth!,
      for (final p in extensions)
        if (p.depth >= 0 && p.depth <= 10000) p.depth,
    }.toList()..sort();
    var inserted = 0;
    for (final depth in depths) {
      final atDepth = absolute.where((prompt) => prompt.depth == depth && prompt.content.isNotEmpty).toList();
      final orders = <num>{100, ...atDepth.map((prompt) => prompt.order)}.toList()..sort((a, b) => b.compareTo(a));
      final messages = <_Prompt>[];
      for (final order in orders) {
        for (final role in ['system', 'user', 'assistant']) {
          final own = atDepth.where((prompt) => prompt.order == order && prompt.role == role).toList();
          final ext = order == 100
              ? extensions.where((prompt) => prompt.depth == depth && prompt.role == role).toList()
              : <PromptInjection>[];
          final ownText = own.map((prompt) => prompt.content).join('\n');
          ext.sort((a, b) => a.fragment.source.id.compareTo(b.fragment.source.id));
          final extensionRaw = ext.map((prompt) => prompt.fragment.content.trim()).join('\n');
          final extensionText = extensionRaw.isEmpty ? '' : expand(extensionRaw);
          final text = [ownText, extensionText].where((text) => text.isNotEmpty).map((text) => text.trim()).join('\n');
          if (text.isEmpty) continue;
          messages.add(
            _Prompt(
              'depth-$depth-$order-$role',
              text,
              [for (final prompt in own) ...prompt.sources, for (final prompt in ext) prompt.fragment.source],
              role: role,
              injected: true,
            ),
          );
        }
      }
      final desired = depth + inserted;
      reversed.insertAll(desired < reversed.length ? desired : reversed.length, messages);
      inserted += messages.length;
    }
    return reversed.reversed.toList();
  }

  void addHistory(List<_Prompt> history, String cyclePrompt) {
    if (get('chatHistory') == null) return;
    final output = <PromptSegment>[];
    collections['chatHistory'] = output;
    final newChatKey = input.groupNames.isEmpty ? 'new_chat_prompt' : 'new_group_chat_prompt';
    final newChat = message(_Prompt('newMainChat', expand(setting(newChatKey)), [PromptSource('control', newChatKey)]));
    reserve(newChat);
    final groupNudge = input.groupNames.isNotEmpty && type != 'impersonate' ? message(get('groupNudge')!) : null;
    if (groupNudge != null) reserve(groupNudge);
    final continuation = <PromptSegment>[];
    if (type == 'continue' && cyclePrompt.isNotEmpty && settings['continue_prefill'] != true) {
      final nudge = expand(setting('continue_nudge_prompt'), {'lastChatMessage': cyclePrompt.trim()});
      final index = history.lastIndexWhere((prompt) => !prompt.injected);
      if (index >= 0) continuation.add(message(history.removeAt(index), expandText: true));
      continuation.add(
        message(_Prompt('continueNudge', expand(nudge), const [PromptSource('control', 'continue_nudge_prompt')])),
      );
      for (final segment in continuation) {
        reserve(segment);
      }
    }
    final emptyUser = message(
      _Prompt('emptyUserMessageReplacement', setting('send_if_empty'), const [
        PromptSource('control', 'send_if_empty'),
      ], role: 'user'),
    );
    if (history.isNotEmpty &&
        history.last.role == 'assistant' &&
        emptyUser.message['content'] != '' &&
        emptyUser.tokens <= remaining) {
      spend(emptyUser);
      output.add(emptyUser);
    }
    final pool = history.reversed.toList();
    for (var i = 0; i < pool.length; i++) {
      final segment = message(pool[i], expandText: true, includeName: number('names_behavior', 0) == 1);
      if (segment.tokens > remaining) {
        for (final dropped in pool.skip(i)) {
          excluded.add(PromptExclusion(dropped.id, 'history-budget', dropped.sources));
        }
        break;
      }
      if (meaningful(segment)) {
        spend(segment);
        output.insert(0, segment);
      }
    }
    remaining += newChat.tokens;
    spend(newChat);
    output.insert(0, newChat);
    if (groupNudge != null) {
      remaining += groupNudge.tokens;
      spend(groupNudge);
      output.add(groupNudge);
    }
    for (final segment in continuation) {
      remaining += segment.tokens;
      spend(segment);
    }
    tail.addAll(continuation);
  }

  void prepareExamples() {
    List<(List<Map<String, Object?>>, PromptSource)> parse(String text, PromptSource source) => [
      for (final block in parseDialogueExamples(
        text,
        userName: input.userName,
        characterName: characterName,
        groupNames: input.groupNames,
      ))
        (block, source),
    ];
    exampleBlocks.addAll(
      parse(field('mes_example'), PromptSource('card', '${input.characterId}:mes_example', label: 'mes_example')),
    );
    final examples = [
      if (input.examplesBefore.isNotEmpty)
        PromptExample(
          before: true,
          fragment: PromptFragment(input.examplesBefore, const PromptSource('world', 'examplesBefore')),
        ),
      ...input.worldExamples,
      if (input.examplesAfter.isNotEmpty)
        PromptExample(
          before: false,
          fragment: PromptFragment(input.examplesAfter, const PromptSource('world', 'examplesAfter')),
        ),
    ];
    for (final example in examples) {
      if (example.fragment.content.isEmpty) continue;
      // S4646 applies baseChatReplace again, after the WI activation expansion.
      // Keep mixed order for side effects; each before item unshifts its blocks.
      final blocks = parse(baseExpand(example.fragment.content), example.fragment.source);
      if (example.before) {
        exampleBlocks.insertAll(0, blocks);
      } else {
        exampleBlocks.addAll(blocks);
      }
    }
  }

  void addExamples() {
    if (get('dialogueExamples') == null || input.stripExamples) return;
    final output = <PromptSegment>[];
    collections['dialogueExamples'] = output;
    if (exampleBlocks.isEmpty) return;
    final prefix = message(
      _Prompt('newChat', expand(setting('new_example_chat_prompt')), const [
        PromptSource('control', 'new_example_chat_prompt'),
      ]),
    );
    for (var i = 0; i < exampleBlocks.length; i++) {
      final (block, source) = exampleBlocks[i];
      final candidates = <PromptSegment>[prefix];
      for (var j = 0; j < block.length; j++) {
        final data = block[j];
        candidates.add(
          PromptSegment(
            id: 'dialogueExamples-$i-$j',
            message: data,
            sources: [source],
            tokens: counter.countMessage(data),
          ),
        );
      }
      final cost = candidates.fold<int>(0, (sum, segment) => sum + segment.tokens);
      if (cost > remaining) {
        excluded.add(PromptExclusion('dialogueExamples-$i', 'whole-example-budget', [source]));
        break;
      }
      for (final segment in candidates) {
        // ST canAffordAll counts empty named examples; insert then skips them.
        if (!meaningful(segment)) continue;
        spend(segment);
        output.add(segment);
      }
    }
  }

  List<PromptSegment> squash(List<PromptSegment> input) {
    const protected = {'newMainChat', 'newChat', 'groupNudge'};
    bool eligible(PromptSegment message) =>
        message.message['role'] == 'system' && !message.message.containsKey('name') && !protected.contains(message.id);
    final result = <PromptSegment>[];
    for (final segment in input) {
      if (segment.message['role'] == 'system' && segment.message['content'] == '') continue;
      if (result.isNotEmpty && eligible(result.last) && eligible(segment)) {
        final previous = result.removeLast();
        final data = {...previous.message, 'content': '${previous.message['content']}\n${segment.message['content']}'};
        result.add(
          PromptSegment(
            id: previous.id,
            message: data,
            sources: [...previous.sources, ...segment.sources],
            tokens: counter.countMessage(data),
          ),
        );
      } else {
        result.add(segment);
      }
    }
    return result;
  }

  Map<String, Object?> genericBody(List<PromptSegment> messages, List<String> stops) => {
    'messages': messages.map((segment) => segment.message).toList(),
    'model': input.model,
    'temperature': settings['temperature'],
    'max_tokens': settings['openai_max_tokens'],
    'stream': settings['stream_openai'] == true && type != 'quiet',
    'presence_penalty': settings['presence_penalty'],
    'frequency_penalty': settings['frequency_penalty'],
    'top_p': settings['top_p'],
    if (stops.isNotEmpty) 'stop': stops.take(4).toList(),
    if ((settings['seed'] as num? ?? -1) >= 0) 'seed': settings['seed'],
    if (input.tools.isNotEmpty) 'tools': input.tools,
    if (input.tools.isNotEmpty && input.toolChoice != null) 'tool_choice': input.toolChoice,
  };
}

String sanitizeName(String name) {
  final normalized = name.replaceAll(RegExp(r'[^a-zA-Z0-9_]'), '_');
  return normalized.length > 64 ? normalized.substring(0, 64) : normalized;
}

/// ST parseMesExamples + parseExampleIntoIndividual, including same-speaker
/// continuation lines and the example_user/example_assistant system names.
List<List<Map<String, Object?>>> parseDialogueExamples(
  String text, {
  required String userName,
  required String characterName,
  List<String> groupNames = const [],
}) {
  if (text.isEmpty || text == '<START>') return [];
  if (!text.startsWith('<START>')) text = '<START>\n${text.trim()}';
  final blocks = text.split(RegExp('<START>', caseSensitive: false)).skip(1);
  final result = <List<Map<String, Object?>>>[];
  for (final block in blocks) {
    final lines = '${block.trim()}\n'.replaceAll('\r', '').split('\n');
    final messages = <Map<String, Object?>>[];
    var buffer = <String>[];
    String? mode;
    var botName = characterName;
    void flush(String name, String marker) {
      var content = buffer.join('\n').replaceFirst('$name:', '').trim();
      if (groupNames.isNotEmpty) content = '$name: $content';
      messages.add({'role': 'system', 'content': content, 'name': marker});
      buffer = [];
    }

    for (final line in lines) {
      if (line.startsWith('$userName:')) {
        if (mode == 'bot') flush(botName, 'example_assistant');
        mode = 'user';
      } else if (line.startsWith('$characterName:') || groupNames.any((name) => line.startsWith('$name:'))) {
        if (!line.startsWith('$characterName:') && groupNames.isNotEmpty) botName = line.split(':').first;
        if (mode == 'user') flush(userName, 'example_user');
        mode = 'bot';
      }
      buffer.add(line);
    }
    if (mode == 'user') flush(userName, 'example_user');
    if (mode == 'bot') flush(botName, 'example_assistant');
    result.add(messages);
  }
  return result;
}
