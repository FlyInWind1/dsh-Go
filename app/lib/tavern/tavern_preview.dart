// A stand-in [Tavern] for building the screens before the engine
// (packages/dsh_tavern, Pro's T8) lands: two sample characters, an in-memory
// tree, and canned replies that stream like a model. Nothing is stored and no
// model is called; the chat page says so ([TavernPreview] → 预览 banner).

import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:dsh_tavern/dsh_tavern.dart';

/// Marks the stand-in, so the screens can say replies are samples.
abstract interface class TavernPreview {}

class PreviewTavern implements Tavern, TavernPreview {
  PreviewTavern({DateTime Function()? clock, this.tick = const Duration(milliseconds: 28)})
    : _clock = clock ?? DateTime.now {
    final now = _clock();
    for (final c in _samples) {
      _characters[c.id] = _Char(c, now);
    }
  }

  final DateTime Function() _clock;

  /// Time between streamed pieces.
  final Duration tick;

  final _characters = <String, _Char>{};
  final _chats = <String, _Chat>{};
  final _listChanged = StreamController<void>.broadcast();
  final _running = <String, StreamController<TavernEvent>>{};
  var _seq = 0;

  String _id(String prefix) => '$prefix-${++_seq}';

  // Library -------------------------------------------------------------------

  List<TavernCharacter> _characterList() {
    final list = _characters.values.map(_view).toList()
      ..sort((a, b) => (b.lastChatAt ?? b.importedAt!).compareTo(a.lastChatAt ?? a.importedAt!));
    return list;
  }

  TavernCharacter _view(_Char c) {
    final chats = _chats.values.where((chat) => chat.characterId == c.id).toList();
    DateTime? last;
    for (final chat in chats) {
      if (last == null || chat.updatedAt.isAfter(last)) last = chat.updatedAt;
    }
    return TavernCharacter(
      id: c.id,
      name: c.name,
      creator: c.creator,
      tags: c.tags,
      description: c.description,
      creatorNotes: c.creatorNotes,
      greetings: c.greetings,
      chatCount: chats.length,
      lastChatAt: last,
      importedAt: c.importedAt,
    );
  }

  Stream<T> _watch<T>(T Function() read) async* {
    yield read();
    yield* _listChanged.stream.map((_) => read());
  }

  @override
  Stream<List<TavernCharacter>> watchCharacters() => _watch(_characterList);

  @override
  Future<TavernCharacter?> character(String id) async => switch (_characters[id]) {
    final c? => _view(c),
    null => null,
  };

  @override
  Future<TavernCharacter> importCard(Uint8List bytes, {String? fileName}) async =>
      throw const TavernImportError('preview');

  @override
  Future<Uint8List> exportCard(String characterId, {TavernCardFormat format = TavernCardFormat.png}) async =>
      throw UnsupportedError('preview');

  @override
  Future<void> deleteCharacter(String characterId) async {
    _characters.remove(characterId);
    _chats.removeWhere((_, chat) => chat.characterId == characterId);
    _listChanged.add(null);
  }

  static const _editableTexts = {
    'name',
    'nickname',
    'description',
    'personality',
    'scenario',
    'first_mes',
    'mes_example',
    'system_prompt',
    'post_history_instructions',
    'creator_notes',
    'creator',
    'character_version',
  };

  @override
  Future<Map<String, Object?>?> characterFields(String characterId) async => switch (_characters[characterId]) {
    final c? => _copy(c.data),
    null => null,
  };

  @override
  Future<TavernCharacter> updateCharacterFields(String characterId, Map<String, Object?> fields) async {
    final c = _characters[characterId];
    if (c == null) throw const TavernImportError('missing character');
    for (final MapEntry(:key, :value) in fields.entries) {
      final ok = _editableTexts.contains(key)
          ? value is String
          : (key == 'alternate_greetings' || key == 'tags') && value is List && value.every((v) => v is String);
      if (!ok) throw ArgumentError.value(value, key);
    }
    for (final MapEntry(:key, :value) in fields.entries) {
      c.data[key] = value is List ? [...value] : value;
    }
    _listChanged.add(null);
    return _view(c);
  }

  static Map<String, Object?> _copy(Map<String, Object?> data) => {
    for (final MapEntry(:key, :value) in data.entries)
      key: switch (value) {
        final List l => [...l],
        final Map<String, Object?> m => _copy(m),
        _ => value,
      },
  };

  /// Canned replies assemble no prompt: there is nothing to inspect.
  @override
  Future<TavernTurnInspection?> inspectTurn(String chatId, {String? nodeId}) async => null;

  // Personas ------------------------------------------------------------------

  final _personas = <String, TavernPersona>{};
  final _bindings = <String, String>{};
  String? _defaultPersona;

  List<TavernPersona> _personaList() => _personas.values.toList();

  @override
  Stream<List<TavernPersona>> watchPersonas() => _watch(_personaList);

  @override
  Future<TavernPersona?> persona(String personaId) async => _personas[personaId];

  @override
  Future<TavernPersona> createPersona({
    required String name,
    String description = '',
    String? avatarPath,
    int descriptionPosition = PersonaDescriptionPosition.inPrompt,
  }) async {
    final persona = TavernPersona(
      id: _id('persona'),
      name: name,
      description: description,
      avatarPath: avatarPath,
      descriptionPosition: descriptionPosition,
    );
    _personas[persona.id] = persona;
    _listChanged.add(null);
    return persona;
  }

  @override
  Future<TavernPersona> updatePersona(
    String personaId, {
    String? name,
    String? description,
    String? avatarPath,
    bool clearAvatar = false,
    int? descriptionPosition,
  }) async {
    final persona = _personas[personaId]!.copyWith(
      name: name,
      description: description,
      avatarPath: avatarPath,
      clearAvatar: clearAvatar,
      descriptionPosition: descriptionPosition,
    );
    _personas[personaId] = persona;
    _listChanged.add(null);
    return persona;
  }

  @override
  Future<void> deletePersona(String personaId) async {
    _personas.remove(personaId);
    _bindings.removeWhere((_, id) => id == personaId);
    if (_defaultPersona == personaId) _defaultPersona = null;
    _listChanged.add(null);
  }

  @override
  Future<PersonaSelection> personaSelection({String? chatId}) async {
    final bound = chatId == null ? null : _bindings[chatId];
    final fallback = _defaultPersona;
    final persona = _personas[bound] ?? _personas[fallback];
    return PersonaSelection(
      persona: persona,
      source: _personas[bound] != null
          ? PersonaSelectionSource.chat
          : persona != null
          ? PersonaSelectionSource.globalDefault
          : PersonaSelectionSource.none,
      boundPersonaId: _personas.containsKey(bound) ? bound : null,
      defaultPersonaId: fallback,
    );
  }

  @override
  Future<void> setDefaultPersona(String? personaId) async {
    _defaultPersona = personaId;
    _listChanged.add(null);
  }

  @override
  Future<void> bindPersona(String chatId, String? personaId) async {
    if (personaId == null) {
      _bindings.remove(chatId);
    } else {
      _bindings[chatId] = personaId;
    }
    _listChanged.add(null);
  }

  // Chats ---------------------------------------------------------------------

  @override
  Stream<List<TavernChatSummary>> watchChats({String? characterId}) => _watch(() {
    final list = [
      for (final chat in _chats.values)
        if (characterId == null || chat.characterId == characterId) _summary(chat),
    ]..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return list;
  });

  TavernChatSummary _summary(_Chat chat) {
    final path = chat.path();
    return TavernChatSummary(
      id: chat.id,
      characterId: chat.characterId,
      title: chat.title,
      updatedAt: chat.updatedAt,
      lastText: path.isEmpty ? null : path.last.text,
      messageCount: path.length,
    );
  }

  @override
  Future<String> createChat(String characterId, {int greeting = 0}) async {
    final c = _characters[characterId]!;
    final now = _clock();
    final chat = _Chat(_id('chat'), characterId, c.name, now);
    final greetings = c.greetings;
    for (var i = 0; i < greetings.length; i++) {
      chat.add(_Node(_id('n'), null, TavernRole.character, c.name, greetings[i], now));
    }
    chat.chosen[null] = chat.children(null)[greeting.clamp(0, greetings.length - 1)].id;
    _chats[chat.id] = chat;
    _listChanged.add(null);
    return chat.id;
  }

  /// The samples have no ST chat files to read or write.
  @override
  Future<TavernChatImportResult> importChats(
    String characterId,
    List<TavernChatFile> files, {
    Map<String, String> lorebookIds = const {},
  }) async => throw UnsupportedError('preview');

  @override
  Future<List<TavernChatFile>> exportChat(String chatId, {String? fileName}) async => throw UnsupportedError('preview');

  @override
  Future<void> deleteChat(String chatId) async {
    _chats.remove(chatId);
    _listChanged.add(null);
  }

  @override
  Future<List<TavernMessage>> path(String chatId, {int limit = 60, String? beforeNodeId}) async {
    final all = _chats[chatId]!.path();
    var end = all.length;
    if (beforeNodeId != null) end = all.indexWhere((m) => m.nodeId == beforeNodeId).clamp(0, all.length);
    return all.sublist(math.max(0, end - limit), end);
  }

  @override
  Stream<void> pathChanges(String chatId) => _chats[chatId]!.changes.stream;

  // Turns ---------------------------------------------------------------------

  @override
  Stream<TavernEvent> send(String chatId, String text) {
    final chat = _chats[chatId]!;
    final tail = chat.tail();
    var parent = tail?.id;
    if (text.trim().isNotEmpty) {
      final user = _Node(_id('n'), parent, TavernRole.user, 'You', text, _clock());
      chat.add(user);
      chat.chosen[parent] = user.id;
      parent = user.id;
    }
    return _reply(chat, parent, _cannedFor(text));
  }

  @override
  Stream<TavernEvent> regenerate(String chatId, String nodeId) {
    final chat = _chats[chatId]!;
    final node = chat.nodes[nodeId]!;
    return _reply(chat, node.parent, _canned[_seq % _canned.length]);
  }

  @override
  Stream<TavernEvent> continueReply(String chatId, String nodeId) {
    final chat = _chats[chatId]!;
    final node = chat.nodes[nodeId]!;
    return _stream(chat, node, '\n\n她停顿了一下，又接着说：「还有一件事……我晚点再告诉你。」', started: false);
  }

  @override
  Stream<TavernEvent> impersonate(String chatId) async* {
    yield const TavernTextDelta('', '我推开门，四下看了看。');
    yield TavernTurnDone(
      TavernMessage(nodeId: '', role: TavernRole.user, speaker: 'You', text: '我推开门，四下看了看。', at: _clock()),
    );
  }

  @override
  void stop(String chatId) => _running[chatId]?.close();

  Stream<TavernEvent> _reply(_Chat chat, String? parent, String text) {
    final c = _characters[chat.characterId]!;
    final node = _Node(_id('n'), parent, TavernRole.character, c.name, '', _clock());
    chat.add(node);
    chat.chosen[parent] = node.id;
    return _stream(chat, node, text, started: true);
  }

  Stream<TavernEvent> _stream(_Chat chat, _Node node, String text, {required bool started}) {
    final out = StreamController<TavernEvent>();
    _running[chat.id] = out;
    var stopped = false;
    out.onCancel = () => stopped = true;
    unawaited(() async {
      if (started) out.add(TavernTurnStarted(chat.message(node)));
      chat.touch(_clock());
      if (_thinking && started) {
        for (final piece in _pieces(_sampleReasoning)) {
          await Future<void>.delayed(tick);
          if (stopped || out.isClosed) break;
          node.reasoning = (node.reasoning ?? '') + piece;
          out.add(TavernReasoningDelta(node.id, piece));
        }
      }
      final pieces = _pieces(text);
      for (final piece in pieces) {
        await Future<void>.delayed(tick);
        if (stopped || out.isClosed) break;
        node.text += piece;
        out.add(TavernTextDelta(node.id, piece));
      }
      _running.remove(chat.id);
      chat.changes.add(null);
      _listChanged.add(null);
      if (out.isClosed) return;
      out.add(
        stopped
            ? TavernTurnFailed(TavernFailure.cancelled, partial: chat.message(node))
            : TavernTurnDone(chat.message(node)),
      );
      await out.close();
    }());
    return out.stream;
  }

  // Editing the tree ----------------------------------------------------------

  @override
  Future<void> selectSibling(String chatId, String nodeId, int index) async {
    final chat = _chats[chatId]!;
    final node = chat.nodes[nodeId]!;
    final siblings = chat.children(node.parent);
    chat.chosen[node.parent] = siblings[index.clamp(0, siblings.length - 1)].id;
    chat.changes.add(null);
  }

  @override
  Future<void> edit(String chatId, String nodeId, String text) async {
    final chat = _chats[chatId]!;
    chat.nodes[nodeId]!.text = text;
    chat.changes.add(null);
  }

  @override
  Future<void> deleteFrom(String chatId, String nodeId) async {
    final chat = _chats[chatId]!;
    chat.remove(nodeId);
    chat.changes.add(null);
    _listChanged.add(null);
  }

  @override
  Future<void> setHidden(String chatId, String nodeId, bool hidden) async {
    final chat = _chats[chatId]!;
    chat.nodes[nodeId]!.hidden = hidden;
    chat.changes.add(null);
  }

  @override
  void configure(TavernModelConfig config) => _thinking = config.thinking;

  /// 思考 is on: replies think a little first.
  var _thinking = false;

  @override
  Future<void> close() async => _listChanged.close();
}

class _Card {
  const _Card({
    required this.id,
    required this.name,
    required this.description,
    required this.greetings,
    this.creator,
    this.tags = const [],
    this.creatorNotes = '',
  });

  final String id;
  final String name;
  final String? creator;
  final List<String> tags;
  final String description;
  final String creatorNotes;
  final List<String> greetings;
}

class _Char {
  _Char(_Card card, this.importedAt)
    : id = card.id,
      data = {
        'name': card.name,
        'nickname': '',
        'description': card.description,
        'personality': '',
        'scenario': '',
        'first_mes': card.greetings.first,
        'alternate_greetings': card.greetings.skip(1).toList(),
        'mes_example': '',
        'system_prompt': '',
        'post_history_instructions': '',
        'creator_notes': card.creatorNotes,
        'creator': card.creator ?? '',
        'character_version': '',
        'tags': [...card.tags],
        'extensions': <String, Object?>{
          'depth_prompt': {'prompt': '', 'depth': 4},
        },
      };

  final String id;

  /// The card's V3 `data`, as [Tavern.characterFields] gives it.
  final Map<String, Object?> data;
  final DateTime importedAt;

  String get name => data['name']! as String;
  String? get creator => switch (data['creator']) {
    final String c when c.isNotEmpty => c,
    _ => null,
  };
  List<String> get tags => (data['tags']! as List).cast<String>();
  String get description => data['description']! as String;
  String get creatorNotes => data['creator_notes']! as String;
  List<String> get greetings => [
    data['first_mes']! as String,
    ...(data['alternate_greetings']! as List).cast<String>(),
  ];
}

class _Node {
  _Node(this.id, this.parent, this.role, this.speaker, this.text, this.at);
  final String id;
  final String? parent;
  final TavernRole role;
  final String speaker;
  String text;
  String? reasoning;
  final DateTime at;
  bool hidden = false;
}

class _Chat {
  _Chat(this.id, this.characterId, this.title, this.updatedAt);
  final String id;
  final String characterId;
  final String title;
  DateTime updatedAt;
  final nodes = <String, _Node>{};
  final _order = <String>[];

  /// The child each node continues with (null key: the root).
  final chosen = <String?, String>{};
  final changes = StreamController<void>.broadcast();

  void add(_Node node) {
    nodes[node.id] = node;
    _order.add(node.id);
  }

  void touch(DateTime at) => updatedAt = at;

  List<_Node> children(String? parent) => [
    for (final id in _order)
      if (nodes[id]!.parent == parent) nodes[id]!,
  ];

  /// The nodes from the root down the chosen children.
  List<_Node> _walk() {
    final out = <_Node>[];
    var next = chosen[null];
    while (next != null && nodes.containsKey(next)) {
      out.add(nodes[next]!);
      next = chosen[next];
    }
    return out;
  }

  _Node? tail() => _walk().lastOrNull;

  List<TavernMessage> path() => [for (final node in _walk()) message(node)];

  TavernMessage message(_Node node) {
    final siblings = children(node.parent);
    return TavernMessage(
      nodeId: node.id,
      parentId: node.parent,
      role: node.role,
      speaker: node.speaker,
      text: node.text,
      reasoning: node.reasoning,
      at: node.at,
      siblingIndex: siblings.indexOf(node),
      siblingCount: siblings.length,
      hidden: node.hidden,
    );
  }

  void remove(String id) {
    final node = nodes[id];
    if (node == null) return;
    for (final child in children(id)) {
      remove(child.id);
    }
    nodes.remove(id);
    _order.remove(id);
    chosen.remove(id);
    if (chosen[node.parent] == id) {
      final rest = children(node.parent);
      if (rest.isEmpty) {
        chosen.remove(node.parent);
      } else {
        chosen[node.parent] = rest.last.id;
      }
    }
  }
}

Iterable<String> _pieces(String text) => RegExp(r'.{1,3}', dotAll: true).allMatches(text).map((m) => m[0]!);

const _sampleReasoning = '她在等一个答案，但不想说得太多。先回应眼前的问题，再留一点悬念。';

String _cannedFor(String text) => text.contains('?') || text.contains('？') ? _canned[1] : _canned[0];

const _canned = [
  '*她把手里的杯子放下，抬眼看你。*\n\n「你来得正好。外面的雨一直没停，镇上的人都躲在屋里。」\n\n她往壁炉那边挪了挪，给你让出一个位置。「坐吧，我去给你倒点热的。」',
  '「这个问题啊……」她想了想，手指在桌面上轻轻敲着。\n\n「我只能告诉你我知道的那部分。剩下的，你得自己去地下室看看。」',
  '*门外传来一阵脚步声，又很快远去。*\n\n她没有回头，只是低声说：「别出声，等他们走远。」',
];

const _samples = [
  _Card(
    id: 'sample-innkeeper',
    name: '林晚',
    creator: 'DSH Go',
    tags: ['示例', '悬疑'],
    description: '雨夜小镇上一家旅店的老板娘，知道很多事，但只说一半。',
    creatorNotes: '这是一张示例卡，用来预览酒馆的界面。',
    greetings: [
      '*旅店的门被风推开，带进一阵冷雨。柜台后面的女人抬起头。*\n\n「这么晚了还在赶路？进来吧，炉子还热着。」',
      '*你醒来时，发现自己躺在旅店二楼的床上。窗外还在下雨。*\n\n「你可算醒了。」门口的女人端着一碗汤，「昨晚你倒在门口，吓我一跳。」',
    ],
  ),
  _Card(
    id: 'sample-navigator',
    name: '星图',
    creator: 'DSH Go',
    tags: ['示例', '科幻'],
    description: '远航飞船上的导航 AI，说话简短，偶尔会讲冷笑话。',
    greetings: ['「舰桥欢迎你，舰长。航线已经算好，还有三十七个小时抵达。要听个笑话打发时间吗？」'],
  ),
];
