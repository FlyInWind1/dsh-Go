// ST continuation, injection ordering and world-info integration follow
// SillyTavern public/script.js, scripts/constants.js and scripts/world-info.js
// at 7e8663cd9c184a550b37238218bdd32c6efc68e9 (1.19.0, AGPL-3.0).
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'api.dart';
import 'inspection.dart';
import 'llm/model_client.dart';
import 'macros/macro_engine.dart';
import 'persona.dart';
import 'prompt/character_fields.dart';
import 'prompt/preset.dart';
import 'prompt/prompt_assembler.dart';
import 'prompt/prompt_types.dart';
import 'store/character_library.dart';
import 'store/chat_store.dart';
import 'store/persona_store.dart';
import 'worldinfo/world_info.dart';

/// App convenience factory. [directory] is the actual tavern data directory,
/// normally `<app support>/tavern`. No extra path component is appended.
Future<Tavern> openTavern(String directory) => TavernEngine.openDirectory(Directory(directory));

/// A recording of the actual assembly, never a second macro evaluation.
class TavernInspection {
  const TavernInspection({
    required this.prompt,
    required this.worldInfo,
    required this.generationType,
    required this.at,
  });
  final PromptAssembly prompt;
  final WorldInfoResult worldInfo;
  final String generationType;
  final DateTime at;

  Map<String, Object?> toJson() => _copy({
    'prompt': prompt.toJson(),
    'generationType': generationType,
    'at': at.toIso8601String(),
    'worldInfo': {
      'budget': worldInfo.budget,
      'overflowed': worldInfo.overflowed,
      'scanRounds': worldInfo.scanRounds,
      'activated': [
        for (final hit in worldInfo.activated)
          {
            'bookId': hit.bookId,
            'uid': hit.uid,
            'source': hit.source.name,
            'reason': hit.reason,
            'content': hit.content,
            'originalContent': hit.originalContent,
            'order': hit.order,
            'phase': hit.phase.name,
            'round': hit.round,
            'primaryKey': hit.primaryKey,
            'secondaryMatches': hit.secondaryMatches,
            'probabilityRoll': hit.probabilityRoll,
          },
      ],
    },
  });
}

/// Owns the character files, chat database, settings, and active generations.
/// Only one engine should open a given app-support directory at a time.
class TavernEngine implements Tavern {
  TavernEngine._(
    this.directory,
    this._store,
    this._library,
    this._personas,
    this._document,
    this._config,
    this._modelClient,
    this._counter,
    this._clock,
    this._random,
  ) {
    _globalVariables = _map(_document['globalVariables']);
    _storeSubscription = _store.changes.listen((chatId) {
      if (_closed) return;
      _paths.add(chatId);
      if (!_turns.containsKey(chatId)) _notifyLists();
    });
  }

  static Future<TavernEngine> open(
    Directory appSupport, {
    TavernModelConfig? config,
    TavernModelClient? modelClient,
    PromptTokenCounter counter = const EstimatedTokenCounter(),
    DateTime Function()? clock,
    double Function()? random,
  }) => openDirectory(
    Directory('${appSupport.path}/tavern'),
    config: config,
    modelClient: modelClient,
    counter: counter,
    clock: clock,
    random: random,
  );

  /// Opens an explicit tavern root. Unlike [open], this does not append
  /// `tavern`; the caller chooses the complete data-directory path.
  static Future<TavernEngine> openDirectory(
    Directory directory, {
    TavernModelConfig? config,
    TavernModelClient? modelClient,
    PromptTokenCounter counter = const EstimatedTokenCounter(),
    DateTime Function()? clock,
    double Function()? random,
  }) async {
    await directory.create(recursive: true);
    final settingsFile = File('${directory.path}/settings.json');
    final document = await settingsFile.exists()
        ? _decodeObject(await settingsFile.readAsString(), 'Tavern settings')
        : <String, Object?>{'version': 1, 'settings': <String, Object?>{}, 'globalVariables': <String, Object?>{}};
    if (document['version'] != 1) throw const FormatException('Unsupported Tavern settings version.');
    final now = clock ?? DateTime.now;
    final personas = await PersonaStore.open(directory);
    ChatStore? store;
    try {
      store = ChatStore.open('${directory.path}/tavern.sqlite3', clock: now);
      return TavernEngine._(
        directory,
        store,
        CharacterLibrary(directory, now: now),
        personas,
        document,
        config ?? TavernModelConfig(apiKey: () async => null),
        modelClient ?? TavernModelClient(),
        counter,
        now,
        random ?? Random.secure().nextDouble,
      );
    } catch (_) {
      await store?.close();
      await personas.close();
      rethrow;
    }
  }

  final Directory directory;
  final ChatStore _store;
  final CharacterLibrary _library;
  final PersonaStore _personas;
  final Map<String, Object?> _document;
  TavernModelConfig _config;
  final TavernModelClient _modelClient;
  final PromptTokenCounter _counter;
  final DateTime Function() _clock;
  final double Function() _random;
  late final Map<String, Object?> _globalVariables;
  late final StreamSubscription<String> _storeSubscription;
  final _charactersChanged = StreamController<void>.broadcast();
  final _chatsChanged = StreamController<void>.broadcast();
  final _paths = StreamController<String>.broadcast();
  final _turns = <String, _Turn>{};
  final _mutations = <String, Future<void>>{};
  final _deletingCharacters = <String>{};
  final _deletingPersonas = <String>{};
  final _operations = <Future<void>>{};
  final _inspections = <String, TavernInspection>{};
  // A null entry is a tombstone: never fall back to an older disk snapshot
  // after deleting the context of a more recent in-memory attempt.
  final _latestInspections = <String, TavernTurnInspection?>{};
  final _liveVariables = <String, ({String? leaf, Map<String, Object?> values})>{};
  final _books = <String, Map<String, Object?>>{};
  final _bookRevisions = <String, int>{};
  Future<List<StoredCharacter>>? _characterCache;
  Future<void> _libraryQueue = Future.value();
  Future<void> _personaQueue = Future.value();
  Future<void> _fileQueue = Future.value();
  Future<void>? _closeFuture;
  var _closing = false;
  var _closed = false;
  var _temporaryId = 0;

  void _ensureOpen() {
    if (_closing || _closed) throw StateError('The tavern is closed.');
  }

  Future<T> _operation<T>(FutureOr<T> Function() action) {
    _ensureOpen();
    final result = Future<T>.sync(action);
    final completed = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    _operations.add(completed);
    unawaited(
      completed.then<void>((_) {
        _operations.remove(completed);
      }),
    );
    return result;
  }

  Future<T> _libraryOperation<T>(Future<T> Function() action) {
    final result = _libraryQueue.then((_) => action());
    _libraryQueue = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  // Acquire this queue before chat barriers for bind/delete. Taking them in
  // the reverse order could leave a binder waiting behind a deletion that is
  // itself waiting for the binder's chat barrier.
  Future<T> _personaOperation<T>(Future<T> Function() action) {
    final result = _personaQueue.then((_) => action());
    _personaQueue = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Future<List<StoredCharacter>> _characters() => _characterCache ??= _library.list();

  Future<StoredCharacter?> _record(String id) async {
    for (final item in await _characters()) {
      if (item.id == id) return item;
    }
    return null;
  }

  List<TavernChatSummary> _chatSummaries({String? characterId}) => [
    for (final chat in _store.listChats(characterId: characterId))
      TavernChatSummary(
        id: chat.id,
        characterId: chat.characterId,
        title: chat.title,
        updatedAt: chat.updatedAt,
        lastText: chat.lastText == null ? null : _plainText(chat.lastText!),
        messageCount: chat.messageCount,
      ),
  ];

  Future<List<TavernCharacter>> _characterSummaries() async {
    final records = await _characters();
    if (_closed) return const [];
    final chats = _store.listChats();
    final count = <String, int>{};
    final last = <String, DateTime>{};
    for (final chat in chats) {
      count.update(chat.characterId, (value) => value + 1, ifAbsent: () => 1);
      final previous = last[chat.characterId];
      if (previous == null || chat.updatedAt.isAfter(previous)) last[chat.characterId] = chat.updatedAt;
    }
    final result = [
      for (final record in records) record.toCharacter(chatCount: count[record.id] ?? 0, lastChatAt: last[record.id]),
    ];
    result.sort((a, b) {
      final chatOrder = (b.lastChatAt?.millisecondsSinceEpoch ?? -1).compareTo(
        a.lastChatAt?.millisecondsSinceEpoch ?? -1,
      );
      if (chatOrder != 0) return chatOrder;
      final importOrder = b.importedAt!.compareTo(a.importedAt!);
      return importOrder != 0 ? importOrder : a.id.compareTo(b.id);
    });
    return result;
  }

  void _notifyLists() {
    if (_closed || _closing) return;
    _charactersChanged.add(null);
    _chatsChanged.add(null);
  }

  @override
  Stream<List<TavernCharacter>> watchCharacters() {
    _ensureOpen();
    return _watch(_charactersChanged.stream, _characterSummaries);
  }

  @override
  Stream<List<TavernChatSummary>> watchChats({String? characterId}) {
    _ensureOpen();
    return _watch(_chatsChanged.stream, () => _chatSummaries(characterId: characterId));
  }

  @override
  Future<TavernCharacter?> character(String id) => _operation(() async {
    for (final item in await _characterSummaries()) {
      if (item.id == id) return item;
    }
    return null;
  });

  @override
  Future<Map<String, Object?>?> characterFields(String characterId) =>
      _operation(() => _libraryOperation(() => _library.readFields(characterId)));

  @override
  Future<TavernCharacter> updateCharacterFields(String characterId, Map<String, Object?> fields) => _operation(() {
    if (_deletingCharacters.contains(characterId)) throw StateError('Character deletion is running.');
    // Only strings and string lists are accepted by the library. Snapshot the
    // lists now, before this edit waits behind another library operation.
    final patch = <String, Object?>{
      for (final entry in fields.entries)
        entry.key: entry.value is List<Object?> ? List<Object?>.of(entry.value! as List<Object?>) : entry.value,
    };
    return _libraryOperation(() async {
      final stored = await _library.updateFields(characterId, patch);
      _characterCache = null;
      _notifyLists();
      final chats = _store.listChats(characterId: characterId);
      return stored.toCharacter(chatCount: chats.length, lastChatAt: chats.isEmpty ? null : chats.first.updatedAt);
    });
  });

  @override
  Future<TavernCharacter> importCard(Uint8List bytes, {String? fileName}) => _operation(
    () => _libraryOperation(() async {
      final stored = await _library.importCard(bytes, fileName: fileName);
      _characterCache = null;
      _notifyLists();
      return stored.toCharacter();
    }),
  );

  @override
  Future<Uint8List> exportCard(String characterId, {TavernCardFormat format = TavernCardFormat.png}) =>
      _operation(() => _library.exportCard(characterId, format: format));

  @override
  Future<void> deleteCharacter(String characterId) {
    _ensureOpen();
    if (!_deletingCharacters.add(characterId)) {
      return Future.error(StateError('Character deletion is already running.'));
    }
    return _operation(
      () => _libraryOperation(() async {
        try {
          final ids = _store.listChats(characterId: characterId).map((chat) => chat.id).toList();
          await Future.wait([for (final id in ids) _withMutation<void>(id, () {})]);
          await _library.delete(characterId);
          _characterCache = null;
          _store.deleteCharacterChats(characterId);
          for (final id in ids) {
            _inspections.remove(id);
            _latestInspections.remove(id);
            _liveVariables.remove(id);
          }
          _characterCache = null;
          _notifyLists();
        } finally {
          _deletingCharacters.remove(characterId);
          _notifyLists();
        }
      }),
    );
  }

  @override
  Stream<List<TavernPersona>> watchPersonas() {
    _ensureOpen();
    return _watch(_personas.changes, _personas.list);
  }

  @override
  Future<TavernPersona?> persona(String personaId) =>
      _operation(() => _personaOperation(() async => _personas.get(personaId)));

  @override
  Future<TavernPersona> createPersona({
    required String name,
    String description = '',
    String? avatarPath,
    int descriptionPosition = PersonaDescriptionPosition.inPrompt,
  }) => _operation(
    () => _personaOperation(
      () => _personas.create(
        name: name,
        description: description,
        avatarPath: avatarPath,
        descriptionPosition: descriptionPosition,
      ),
    ),
  );

  @override
  Future<TavernPersona> updatePersona(
    String personaId, {
    String? name,
    String? description,
    String? avatarPath,
    bool clearAvatar = false,
    int? descriptionPosition,
  }) => _operation(
    () => _personaOperation(
      () => _personas.update(
        personaId,
        name: name,
        description: description,
        avatarPath: avatarPath,
        clearAvatar: clearAvatar,
        descriptionPosition: descriptionPosition,
      ),
    ),
  );

  @override
  Future<PersonaSelection> personaSelection({String? chatId}) => _operation(
    () => _personaOperation(() async => chatId == null ? _personas.resolve() : _personas.forChat(_store, chatId)),
  );

  @override
  Future<void> setDefaultPersona(String? personaId) =>
      _operation(() => _personaOperation(() => _personas.setDefault(personaId)));

  @override
  Future<void> bindPersona(String chatId, String? personaId) => _operation(
    () => _personaOperation(() async {
      // Reject a missing profile before disturbing an otherwise valid turn.
      if (personaId != null && _personas.get(personaId) == null) throw StateError('Unknown persona: $personaId');
      if (_store.chat(chatId).personaId == personaId) return;
      await _withMutation(chatId, () => _personas.bindChat(_store, chatId, personaId));
    }),
  );

  @override
  Future<void> deletePersona(String personaId) => _operation(
    () => _personaOperation(() async {
      _deletingPersonas.add(personaId);
      try {
        final affected = <String>{};
        for (final summary in _store.listChats()) {
          final chat = _store.chat(summary.id);
          if (chat.personaId == personaId ||
              _personas.resolve(personaId: chat.personaId).persona?.id == personaId ||
              _turns[chat.id]?.personaSelection.persona?.id == personaId) {
            affected.add(chat.id);
          }
        }
        // Hold every affected chat gate until both profile and bindings have
        // been updated. The active turn may still use this profile even when
        // its chat has inherited a different default since that turn began.
        await _withMutations(affected, () async {
          await _personas.delete(personaId, chats: _store);
        });
      } finally {
        _deletingPersonas.remove(personaId);
      }
    }),
  );

  @override
  Future<String> createChat(String characterId, {int greeting = 0}) => _operation(
    () => _libraryOperation(() async {
      if (_deletingCharacters.contains(characterId)) throw StateError('Character deletion is running.');
      final record = await _record(characterId);
      if (record == null) throw const TavernImportError('角色不存在。');
      if (_deletingCharacters.contains(characterId)) throw StateError('Character deletion is running.');
      final data = record.card.data;
      final greetings = <String>[_string(data['first_mes']), ..._strings(data['alternate_greetings'])];
      RangeError.checkValidIndex(greeting, greetings, 'greeting');
      final selection = _personas.resolve();
      if (_deletingPersonas.contains(selection.persona?.id)) throw StateError('Persona deletion is running.');
      final settings = _personaSettings(_effectiveSettings(), selection);
      final variables = <String, Object?>{};
      final beforeGlobals = _jsonString(_globalVariables);
      final id = _store.transaction(() {
        final id = _store.createChat(characterId: characterId, title: record.card.name);
        final context = _MacroEnvironment(
          data,
          settings,
          variables,
          _globalVariables,
          const [],
          _config,
          _clock(),
          _random,
          id,
          '',
          'normal',
        );
        final text = context.expand(greetings[greeting].trim(), const {}).replaceAll('\r', '');
        _store.append(
          id,
          parentId: null,
          role: TavernRole.character,
          speaker: record.card.promptName,
          text: text,
          state: {'variables': _copy(variables)},
        );
        _store.updateChat(id, variables: _copy(variables));
        return id;
      });
      _liveVariables[id] = (leaf: _store.chat(id).currentLeafId, values: _runtimeCopy(variables));
      if (beforeGlobals != _jsonString(_globalVariables)) await _saveDocument();
      _notifyLists();
      return id;
    }),
  );

  @override
  Future<void> deleteChat(String chatId) => _operation(
    () => _withMutation(chatId, () {
      _store.deleteChat(chatId);
      _inspections.remove(chatId);
      _latestInspections.remove(chatId);
      _liveVariables.remove(chatId);
    }),
  );

  @override
  Future<List<TavernMessage>> path(String chatId, {int limit = 60, String? beforeNodeId}) =>
      _operation(() => _store.path(chatId, limit: limit, beforeNodeId: beforeNodeId));

  @override
  Stream<void> pathChanges(String chatId) {
    _ensureOpen();
    return _paths.stream.where((id) => id == chatId).map<void>((_) {});
  }

  @override
  void configure(TavernModelConfig config) {
    _ensureOpen();
    _config = config;
  }

  /// Settings are JSON data. Per-chat documents overlay global settings.
  /// Unknown fields survive updates and reopening. Model credentials are never
  /// read from this document; use [configure] and its key callback.
  Map<String, Object?> settings({String? chatId}) {
    _ensureOpen();
    return _effectiveSettings(chatId == null ? null : _store.chat(chatId));
  }

  Map<String, Object?> variables(String chatId) {
    _ensureOpen();
    return _runtimeCopy(_liveVariables[chatId]?.values ?? _store.chat(chatId).variables);
  }

  Map<String, Object?> get globalVariables {
    _ensureOpen();
    return _runtimeCopy(_globalVariables);
  }

  Future<void> setSettings(Map<String, Object?> patch, {String? chatId}) => _operation(() async {
    if (chatId == null) {
      _document['settings'] = _merge(_map(_document['settings']), patch);
      await _saveDocument();
    } else {
      await _withMutation(chatId, () {
        _store.updateChat(chatId, settings: _merge(_store.chat(chatId).settings, patch));
      });
    }
  });

  Future<void> setPreset(ChatPreset preset, {String? chatId}) => _operation(() async {
    if (chatId == null) {
      _document['settings'] = {..._map(_document['settings']), 'preset': preset.raw};
      await _saveDocument();
    } else {
      await _withMutation(chatId, () {
        _store.updateChat(chatId, settings: {..._store.chat(chatId).settings, 'preset': preset.raw});
      });
    }
  });

  Future<void> setGlobalVariables(Map<String, Object?> variables) => _operation(() async {
    final copy = _copy(variables);
    _globalVariables
      ..clear()
      ..addAll(copy);
    await _saveDocument();
  });

  /// Reads the most recent real request. This has no variable/random effects.
  TavernInspection? inspect(String chatId) {
    _ensureOpen();
    return _inspections[chatId];
  }

  @override
  Future<TavernTurnInspection?> inspectTurn(String chatId, {String? nodeId}) => _operation(() {
    StoredChat chat;
    try {
      chat = _store.chat(chatId);
    } on StateError {
      return null;
    }
    if (nodeId != null) return _nodeInspection(chatId, nodeId);
    if (_latestInspections.containsKey(chatId)) {
      final value = _latestInspections[chatId];
      if (value != null && !_inspectionAnchorExists(value)) _latestInspections[chatId] = null;
      return _latestInspections[chatId];
    }
    final value = _storedLatestInspection(chat);
    return value != null && _inspectionAnchorExists(value) ? value : null;
  });

  StoredNode? _inspectionNode(String chatId, String nodeId) {
    try {
      return _store.node(chatId, nodeId);
    } on StateError {
      return null;
    }
  }

  TavernTurnInspection? _nodeInspection(String chatId, String nodeId) {
    final node = _inspectionNode(chatId, nodeId);
    final json = node == null ? null : _map(node.extra['dshgo'])['inspection'];
    if (json is! Map<String, Object?>) return null;
    final value = TavernTurnInspection.fromJson(json);
    return value.chatId == chatId && value.nodeId == nodeId ? value : null;
  }

  TavernTurnInspection? _storedLatestInspection(StoredChat chat) {
    final latest = _map(_map(chat.metadata['dshgo'])['latestInspection']);
    final nodeId = latest['nodeId'];
    if (nodeId is String) return _nodeInspection(chat.id, nodeId);
    final json = latest['snapshot'];
    if (json is! Map<String, Object?>) return null;
    final value = TavernTurnInspection.fromJson(json);
    return value.chatId == chat.id && value.nodeId == null ? value : null;
  }

  bool _inspectionAnchorExists(TavernTurnInspection value) {
    final anchor = value.nodeId ?? value.contextNodeId;
    return anchor == null || _inspectionNode(value.chatId, anchor) != null;
  }

  void _setInspection(_Turn turn, TavernTurnInspection value) {
    turn.inspection = value;
    _latestInspections[turn.chat.id] = value;
  }

  Map<String, Object?> _inspectionExtra(Map<String, Object?> extra, TavernTurnInspection value) => {
    ...extra,
    'dshgo': {..._map(extra['dshgo']), 'inspection': value.toJson()},
  };

  void _writeLatestInspection(String chatId, TavernTurnInspection? value) {
    final metadata = _store.chat(chatId).metadata;
    final own = _map(metadata['dshgo']);
    if (value == null) {
      own.remove('latestInspection');
    } else {
      own['latestInspection'] = value.nodeId == null ? {'snapshot': value.toJson()} : {'nodeId': value.nodeId};
    }
    _store.updateChat(chatId, metadata: {...metadata, 'dshgo': own});
  }

  // The caller owns the transaction, so node evidence and the latest pointer
  // become visible together. Always merge with the current stored JSON.
  void _writeInspection(TavernTurnInspection value) {
    final nodeId = value.nodeId;
    if (nodeId != null) {
      final node = _store.node(value.chatId, nodeId);
      _store.updateMessage(value.chatId, nodeId, extra: _inspectionExtra(node.extra, value));
    }
    _writeLatestInspection(value.chatId, value);
  }

  void _persistInspection(_Turn turn, TavernTurnInspection value) {
    _store.transaction(() => _writeInspection(value));
    _setInspection(turn, value);
  }

  void _captureAssembly(_Turn turn, PromptAssembly assembly) {
    try {
      _setInspection(turn, turn.inspection.copyWith(prompt: assembly, status: TavernInspectionStatus.ready));
    } on FormatException {
      // An internal recording error is not a malformed character card.
      throw StateError('Invalid assembled inspection data.');
    }
  }

  Future<void> putLorebook(String id, Map<String, Object?> json) => _operation(() async {
    _requireBookId(id);
    final book = WorldInfoBook.fromJson(id: id, source: WorldInfoSource.global, json: json);
    await _writeJson(File('${directory.path}/lorebooks/$id.json'), book.raw);
    _bookRevisions.update(id, (revision) => revision + 1, ifAbsent: () => 1);
    _books[id] = _copy(book.raw);
  });

  Future<Map<String, Object?>?> lorebook(String id) => _operation(() async {
    _requireBookId(id);
    final value = await _readBook(id);
    return value == null ? null : _copy(value);
  });

  /// A global binding applies to all chats; a chat binding overrides that
  /// source's global list. Character-specific bindings may be set globally via
  /// settings.characterLorebooks[characterId]. Card-embedded books always join.
  Future<void> bindLorebooks(List<String> ids, {WorldInfoSource source = WorldInfoSource.global, String? chatId}) {
    for (final id in ids) {
      _requireBookId(id);
    }
    return setSettings({
      'lorebooks': {source.name: List<String>.of(ids)},
    }, chatId: chatId);
  }

  /// ST character filters use the avatar filename and independent tag-map ids,
  /// not a card's display name, library id, or descriptive tags. Importers/UI
  /// can supply that identity explicitly; absent tag-map data remains null.
  Future<void> setCharacterIdentity(String characterId, {required String avatarFilename, List<String>? tagIds}) =>
      setSettings({
        'characterIdentities': {
          characterId: {'avatarFilename': avatarFilename, 'tagIds': tagIds == null ? null : List<String>.of(tagIds)},
        },
      });

  Map<String, Object?> _effectiveSettings([StoredChat? chat]) {
    final result = _merge(_map(_document['settings']), chat?.settings ?? const <String, Object?>{});
    // A selected preset is one complete preset, not a field-by-field mixture
    // with whichever global preset happened to be selected previously.
    if (chat != null && chat.settings.containsKey('preset')) result['preset'] = _map(chat.settings['preset']);
    return result;
  }

  Future<Map<String, Object?>?> _readBook(String id) async {
    _requireBookId(id);
    final cached = _books[id];
    if (cached != null) return cached;
    final revision = _bookRevisions[id] ?? 0;
    final file = File('${directory.path}/lorebooks/$id.json');
    if (!await file.exists()) return null;
    final value = _decodeObject(await file.readAsString(), 'Lorebook');
    if ((_bookRevisions[id] ?? 0) == revision) _books[id] = value;
    return value;
  }

  Future<void> _saveDocument() {
    _document['globalVariables'] = _copy(_globalVariables);
    return _writeJson(File('${directory.path}/settings.json'), _document);
  }

  Future<void> _writeJson(File file, Map<String, Object?> json) {
    final text = jsonEncode(json);
    final result = _fileQueue.then((_) async {
      await file.parent.create(recursive: true);
      final temporary = File('${file.path}.writing');
      await temporary.writeAsString(text, flush: true);
      await temporary.rename(file.path);
    });
    _fileQueue = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Future<T> _withMutation<T>(String chatId, FutureOr<T> Function() action) => _withMutations([chatId], action);

  Future<T> _withMutations<T>(Iterable<String> chatIds, FutureOr<T> Function() action) {
    final ids = chatIds.toSet();
    final previous = [for (final id in ids) _mutations[id] ?? Future<void>.value()];
    final released = Completer<void>();
    // Register every gate before awaiting any turn, including when one persona
    // deletion affects several chats. Later overlapping mutations wait behind
    // this same gate; none can enter while another affected chat is draining.
    for (final id in ids) {
      _mutations[id] = released.future;
      _turns[id]?.cancellation.cancel();
    }
    return () async {
      try {
        await Future.wait(previous);
        final running = ids.map((id) => _turns[id]).whereType<_Turn>().toList();
        for (final turn in running) {
          turn.cancellation.cancel();
        }
        await Future.wait([for (final turn in running) turn.done.future]);
        return await action();
      } finally {
        for (final id in ids) {
          if (identical(_mutations[id], released.future)) {
            // remove returns this same gate Future; complete it below. Waiting
            // for it here would deadlock the mutation's own finally block.
            unawaited(_mutations.remove(id));
          }
        }
        released.complete();
        _notifyLists();
      }
    }();
  }

  @override
  Future<void> selectSibling(String chatId, String nodeId, int index) => _operation(
    () => _withMutation(chatId, () {
      _store.transaction(() {
        _store.selectSibling(chatId, nodeId, index);
        _restoreVariables(chatId);
      });
      _liveVariables.remove(chatId);
    }),
  );

  @override
  Future<void> edit(String chatId, String nodeId, String text) => _operation(
    () => _withMutation(chatId, () {
      _store.edit(chatId, nodeId, text);
    }),
  );

  @override
  Future<void> deleteFrom(String chatId, String nodeId) => _operation(
    () => _withMutation(chatId, () {
      final stored = _storedLatestInspection(_store.chat(chatId));
      final latest = _latestInspections.containsKey(chatId) ? _latestInspections[chatId] : stored;
      var clearLatest = false;
      _store.transaction(() {
        _store.deleteFrom(chatId, nodeId);
        _restoreVariables(chatId);
        clearLatest = latest != null && !_inspectionAnchorExists(latest);
        if (clearLatest || (stored != null && !_inspectionAnchorExists(stored))) {
          _writeLatestInspection(chatId, null);
        }
      });
      if (clearLatest) _latestInspections[chatId] = null;
      _liveVariables.remove(chatId);
    }),
  );

  @override
  Future<void> setHidden(String chatId, String nodeId, bool hidden) => _operation(
    () => _withMutation(chatId, () {
      _store.setHidden(chatId, nodeId, hidden);
    }),
  );

  void _restoreVariables(String chatId) {
    final leaf = _store.chat(chatId).currentLeafId;
    final variables = leaf == null ? <String, Object?>{} : _map(_stateAt(chatId, leaf)['variables']);
    _store.updateChat(chatId, variables: variables);
  }

  Map<String, Object?> _stateAt(String chatId, String? nodeId) {
    if (nodeId == null) return <String, Object?>{};
    final node = _store.node(chatId, nodeId);
    final override = _map(node.extra['dshgo'])['tavernState'];
    return override is Map<String, Object?> ? _copy(override) : _store.nodeState(chatId, nodeId);
  }

  List<StoredNode> _historyTo(String chatId, String? leaf) {
    final reversed = <StoredNode>[];
    while (leaf != null) {
      final node = _store.node(chatId, leaf);
      reversed.add(node);
      leaf = node.message.parentId;
    }
    return reversed.reversed.toList();
  }

  @override
  Stream<TavernEvent> send(String chatId, String text) => _streamTurn(chatId, _TurnKind.send, input: text);
  @override
  Stream<TavernEvent> regenerate(String chatId, String nodeId) =>
      _streamTurn(chatId, _TurnKind.regenerate, nodeId: nodeId);
  @override
  Stream<TavernEvent> continueReply(String chatId, String nodeId) =>
      _streamTurn(chatId, _TurnKind.continueReply, nodeId: nodeId);
  @override
  Stream<TavernEvent> impersonate(String chatId) => _streamTurn(chatId, _TurnKind.impersonate);
  @override
  void stop(String chatId) {
    _turns[chatId]?.cancellation.cancel();
  }

  Stream<TavernEvent> _streamTurn(String chatId, _TurnKind kind, {String input = '', String? nodeId}) {
    late StreamController<TavernEvent> controller;
    _Turn? turn;
    controller = StreamController<TavernEvent>(
      onListen: () {
        try {
          _ensureOpen();
          final chat = _store.chat(chatId);
          final selection = _personas.resolve(personaId: chat.personaId);
          if (_turns.containsKey(chatId) ||
              _mutations.containsKey(chatId) ||
              _deletingCharacters.contains(chat.characterId) ||
              _deletingPersonas.contains(selection.persona?.id)) {
            controller.add(const TavernTurnFailed(TavernFailure.busy, detail: 'chat_busy'));
            unawaited(controller.close());
            return;
          }
          final running = _Turn(
            chat,
            kind,
            input,
            nodeId,
            controller,
            _config,
            _personaSettings(_effectiveSettings(chat), selection),
            _clock(),
            selection,
          );
          turn = running;
          _turns[chatId] = running;
          _setInspection(running, running.inspection);
          unawaited(_run(running));
        } catch (error) {
          controller.add(TavernTurnFailed(TavernFailure.server, detail: _safeDetail(error)));
          unawaited(controller.close());
        }
      },
      onCancel: () {
        final running = turn;
        if (running != null && !running.finished) {
          running.abandoned = true;
          running.cancellation.cancel();
        }
        // Never return running.done or controller.close: either may be waiting
        // for this subscription's cancellation to finish.
      },
    );
    return controller.stream;
  }

  Future<void> _run(_Turn turn) async {
    final chatId = turn.chat.id;
    var beforeGlobals = '';
    try {
      beforeGlobals = _jsonString(_globalVariables);
      turn.originalVariables = _runtimeCopy(_liveVariables[chatId]?.values ?? turn.chat.variables);
      final record = await turn.cancellation.wait(_record(turn.chat.characterId));
      if (record == null) throw const TavernImportError('角色不存在。');
      turn.cancellation.check();
      final data = _effectiveCard(record.card.data, turn.settings);
      StoredNode? target;
      if (turn.nodeId != null) {
        target = _store.node(chatId, turn.nodeId!);
        if (target.message.role != TavernRole.character) throw ArgumentError('The target must be a character message.');
      }
      turn.originalTarget = target;
      var parent = turn.chat.currentLeafId;
      if (turn.kind == _TurnKind.regenerate) parent = target!.message.parentId;
      if (turn.kind == _TurnKind.continueReply) parent = target!.message.nodeId;
      _setInspection(turn, turn.inspection.copyWith(contextNodeId: parent, clearContextNodeId: parent == null));
      final state = _stateAt(chatId, parent);
      final cached = _liveVariables[chatId];
      final local = turn.kind != _TurnKind.regenerate && cached != null && cached.leaf == parent
          ? _runtimeCopy(cached.values)
          : state.containsKey('variables')
          ? _map(state['variables'])
          : turn.kind == _TurnKind.regenerate
          ? <String, Object?>{}
          : _copy(turn.chat.variables);
      turn.variables = local;
      turn.state = state;
      final history = _historyTo(chatId, parent);
      // An inactive target can rewrite remembered edges outside the old active
      // path. Preserve only edges activation can change, including a null
      // selection with still-stored, unselected children below it.
      for (var index = 0; index < history.length; index++) {
        final node = history[index];
        if (index == history.length - 1 || node.selectedChildId != history[index + 1].message.nodeId) {
          turn.previousSelections.add((node.message.nodeId, node.selectedChildId));
        }
      }
      final environment = _MacroEnvironment(
        data,
        turn.settings,
        local,
        _globalVariables,
        history,
        turn.config,
        turn.at,
        _random,
        chatId,
        turn.input,
        turn.generationType,
        chatIdHash: turn.chat.metadata['chat_id_hash'] is num
            ? (turn.chat.metadata['chat_id_hash']! as num).toInt()
            : null,
      );
      if (turn.kind == _TurnKind.send && turn.input.isNotEmpty) {
        final text = environment.expand(turn.input, const {});
        final message = _store.transaction(() {
          final message = _store.append(
            chatId,
            parentId: parent,
            role: TavernRole.user,
            speaker: environment.userName,
            text: text,
            state: turn.currentState,
          );
          _store.updateChat(chatId, variables: _copy(local));
          return message;
        });
        turn.newUserId = message.nodeId;
        parent = message.nodeId;
        _liveVariables[chatId] = (leaf: parent, values: _runtimeCopy(local));
        history.add(_store.node(chatId, message.nodeId));
      }
      final presetRaw = _map(turn.settings['preset']);
      final preset = ChatPreset({
        ...(presetRaw.isEmpty ? ChatPreset.stDefault().raw : presetRaw),
        'show_thoughts': turn.config.thinking,
      });
      environment.preset = preset;
      final prepared = prepareCharacterFields(data, persona: environment.persona, expand: environment.baseExpand);
      final books = await turn.cancellation.wait(_loadBooks(turn.chat.characterId, data, turn.settings));
      turn.cancellation.check();
      final initialInjections = _configuredInjections(turn.settings, prepared, data);
      final scanInjections = <String>[];
      for (final item in initialInjections) {
        if (item.scan) {
          final content = environment.expand(item.injection.fragment.content, const {});
          if (content.isNotEmpty) scanInjections.add(content);
        }
      }
      final world = const WorldInfoEngine().evaluate(
        WorldInfoInput(
          books: books,
          messages: [
            for (final node in history)
              if (!node.message.hidden && !_systemMessage(node))
                WorldInfoMessage(node.message.text, speaker: node.message.speaker),
          ],
          // ST script.js passes getMaxPromptTokens(), excluding the response.
          maxContext: environment.maxContext - environment.maxResponse,
          tokenCount: _counter.countText,
          random: _random,
          expand: (text) => environment.expand(text, const {}),
          settings: WorldInfoSettings.fromJson(_map(turn.settings['worldInfo'])),
          scanInjections: scanInjections,
          personaDescription: prepared.persona,
          characterDescription: prepared['description'],
          characterPersonality: prepared['personality'],
          characterDepthPrompt: prepared['charDepthPrompt'],
          scenario: prepared['scenario'],
          creatorNotes: prepared['creator_notes'],
          trigger: turn.generationType,
          characterName: _characterFilename(turn.settings, turn.chat.characterId),
          characterTags: _characterTags(turn.settings, turn.chat.characterId),
        ),
      );
      _setInspection(turn, turn.inspection.copyWith(worldInfo: _worldInfoTrace(world)));
      environment.outlets.addAll({
        for (final entry in world.outlets.entries) entry.key: entry.value.map((hit) => hit.content).join('\n'),
      });
      final injections = _finishInjections(initialInjections, world);
      final examples = [for (var index = 0; index < world.activated.length; index++) (index, world.activated[index])];
      examples.sort((a, b) {
        final byOrder = b.$2.order.compareTo(a.$2.order);
        return byOrder != 0 ? byOrder : a.$1.compareTo(b.$1);
      });
      final assembly = PromptAssembler(counter: _counter).assemble(
        PromptInput(
          preset: preset,
          card: data,
          history: [for (final node in history) _promptHistory(node)],
          model: turn.config.model,
          userName: environment.userName,
          characterId: turn.chat.characterId,
          generationType: turn.generationType,
          deepseek: turn.config.deepseek,
          persona: environment.persona,
          personaInPrompt: turn.settings['personaInPrompt'] != false,
          worldBefore: world.before.map(_worldFragment).toList(),
          worldAfter: world.after.map(_worldFragment).toList(),
          injections: injections,
          worldExamples: [
            for (final item in examples.reversed)
              if (item.$2.content.isNotEmpty && (item.$2.entry.position == 5 || item.$2.entry.position == 6))
                PromptExample(fragment: _worldFragment(item.$2), before: item.$2.entry.position == 5),
          ],
          pinExamples: turn.settings['pinExamples'] == true,
          stripExamples: turn.settings['stripExamples'] == true,
          bias: _string(turn.settings['bias']),
          stops: _strings(turn.settings['stops']),
          expansion: environment.expand,
          cardExpansion: environment.baseExpand,
          preparedFields: prepared,
        ),
      );
      _inspections[chatId] = TavernInspection(
        prompt: assembly,
        worldInfo: world,
        generationType: turn.generationType,
        at: turn.at,
      );
      _captureAssembly(turn, assembly);
      turn.cancellation.check();
      turn.postfix = _string(preset.settings['continue_postfix']);
      TavernMessage reply;
      if (turn.kind == _TurnKind.impersonate) {
        reply = TavernMessage(
          nodeId: 'temporary-${++_temporaryId}',
          parentId: parent,
          role: TavernRole.user,
          speaker: environment.userName,
          text: '',
          at: turn.at,
        );
        _persistInspection(turn, turn.inspection);
      } else {
        final created = _store.transaction(() {
          _store.updateChat(chatId, variables: _copy(local));
          TavernMessage message;
          if (turn.kind == _TurnKind.continueReply) {
            message = target!.message;
            // Descendants remain stored. The selected path ends at the node
            // whose continuation is now being generated.
            _store.selectNode(chatId, message.nodeId, restoreDescendants: false);
            final extra = _copy(target.extra);
            extra['dshgo'] = {..._map(extra['dshgo']), 'tavernState': turn.currentState};
            message = _store.updateMessage(chatId, message.nodeId, extra: extra);
          } else {
            message = _store.append(
              chatId,
              parentId: parent,
              role: TavernRole.character,
              speaker: record.card.promptName,
              text: '',
              state: turn.currentState,
            );
          }
          final inspection = turn.inspection.copyWith(nodeId: message.nodeId);
          _writeInspection(inspection);
          return (message, inspection);
        });
        reply = created.$1;
        _setInspection(turn, created.$2);
      }
      turn.begin(reply);
      if (turn.kind != _TurnKind.impersonate) {
        _liveVariables[chatId] = (leaf: reply.nodeId, values: _runtimeCopy(local));
      }
      turn.emit(TavernTurnStarted(reply));
      await _consume(turn, _copy(assembly.body));
      turn.cancellation.check();
      _flush(turn);
      if (beforeGlobals != _jsonString(_globalVariables)) await _saveDocument();
      turn.cancellation.check();
      _persistInspection(
        turn,
        turn.inspection.copyWith(status: TavernInspectionStatus.completed, finishedAt: _clock()),
      );
      turn.emit(TavernTurnDone(_latest(turn)));
      turn.terminal = true;
    } catch (error) {
      var failure = error is TavernModelException
          ? error.kind
          : error is PromptBudgetExceeded
          ? TavernFailure.contextTooLong
          : error is TavernImportError || error is FormatException
          ? TavernFailure.invalidCard
          : TavernFailure.server;
      var detail = error is TavernModelException ? error.detail : _safeDetail(error);
      TavernMessage? partial;
      var storageReady = false;
      var inspection = turn.inspection.copyWith(
        status: TavernInspectionStatus.failed,
        finishedAt: _clock(),
        failure: failure,
        detail: detail,
      );
      try {
        _flush(turn);
        if (turn.hasOutput) {
          partial = _latest(turn);
        } else {
          inspection = inspection.copyWith(clearNodeId: true);
          _rollbackEmpty(turn, inspection);
          if (turn.kind == _TurnKind.continueReply) partial = turn.originalTarget?.message;
        }
        storageReady = true;
        if (beforeGlobals != _jsonString(_globalVariables)) await _saveDocument();
      } catch (storageError) {
        // Do not return partial=null after a failed rollback: that would invite
        // the UI to reinsert a user line that might still be in the database.
        failure = TavernFailure.server;
        detail = 'turn_storage_failure (${storageError.runtimeType})';
        if (!storageReady) {
          partial = turn.lastCommitted;
          if (partial == null && turn.newUserId != null) {
            try {
              partial = _store.message(chatId, turn.newUserId!);
            } catch (_) {
              /* Original failure is retained. */
            }
          }
        }
        inspection = turn.inspection.copyWith(
          status: TavernInspectionStatus.failed,
          finishedAt: _clock(),
          failure: failure,
          detail: detail,
        );
      }
      if (storageReady && !identical(inspection, turn.inspection)) {
        try {
          _persistInspection(turn, inspection);
        } catch (storageError) {
          failure = TavernFailure.server;
          detail = 'inspection_storage_failure (${storageError.runtimeType})';
          inspection = inspection.copyWith(failure: failure, detail: detail);
          // The DB may be unwritable. Keep this process's actual failure, but
          // do not retry recursively or claim that this terminal state saved.
        }
      }
      _setInspection(turn, inspection);
      turn.emit(TavernTurnFailed(failure, detail: detail, partial: partial));
      turn.terminal = true;
    } finally {
      turn.flushTimer?.cancel();
      turn.finished = true;
      if (identical(_turns[chatId], turn)) _turns.remove(chatId);
      if (!turn.done.isCompleted) turn.done.complete();
      // A paused consumer can delay stream.close forever. It must not hold the
      // database, a mutation, or engine.close hostage.
      unawaited(turn.controller.close());
      _notifyLists();
    }
  }

  Future<List<WorldInfoBook>> _loadBooks(
    String characterId,
    Map<String, Object?> data,
    Map<String, Object?> settings,
  ) async {
    final result = <WorldInfoBook>[];
    final bindings = _map(settings['lorebooks']);
    for (final source in WorldInfoSource.values) {
      final ids = <String>[
        ..._strings(bindings[source.name]),
        if (source == WorldInfoSource.character) ..._strings(_map(settings['characterLorebooks'])[characterId]),
      ];
      for (final id in ids) {
        final json = await _readBook(id);
        if (json == null) throw const TavernImportError('绑定的世界书不存在。');
        result.add(WorldInfoBook.fromJson(id: id, source: source, json: json));
      }
    }
    final embedded = data['character_book'];
    if (embedded is Map<String, Object?>) {
      result.add(WorldInfoBook.fromJson(id: '$characterId:card', source: WorldInfoSource.character, json: embedded));
    }
    return result;
  }

  Future<void> _consume(_Turn turn, Map<String, Object?> body) async {
    final completed = Completer<void>();
    void fail(Object error, StackTrace stack) {
      if (!completed.isCompleted) completed.completeError(error, stack);
    }

    turn.flushTimer = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (completed.isCompleted) return;
      try {
        _flush(turn);
      } catch (error, stack) {
        fail(error, stack);
      }
    });
    unawaited(
      turn.cancellation.whenCancelled.then<void>((_) {
        fail(const TavernModelException(TavernFailure.cancelled, 'cancelled'), StackTrace.current);
      }),
    );
    StreamSubscription<ModelDelta>? subscription;
    try {
      turn.cancellation.check();
      subscription = _modelClient
          .generate(config: turn.config, body: body, cancellation: turn.cancellation)
          .listen(
            (delta) {
              if (completed.isCompleted || turn.cancellation.isCancelled) return;
              try {
                switch (delta) {
                  case ModelText(:final text):
                    if (text.isEmpty) return;
                    var addition = text;
                    if (turn.kind == _TurnKind.continueReply && !turn.receivedText) {
                      if (!turn.originalTarget!.message.text.endsWith(' ')) addition = '${turn.postfix}$text';
                    }
                    turn.receivedText = true;
                    turn.text!.write(addition);
                    turn.emit(TavernTextDelta(turn.reply!.nodeId, addition));
                  case ModelReasoning(:final text):
                    if (text.isEmpty) return;
                    turn.reasoning!.write(text);
                    turn.emit(TavernReasoningDelta(turn.reply!.nodeId, text));
                  case ModelUsage(:final usage):
                    turn.usage = usage;
                    _setInspection(turn, turn.inspection.copyWith(reportedUsage: usage));
                  case ModelFinished():
                    completed.complete();
                    return;
                }
                turn.hasOutput = true;
                turn.dirty = true;
                turn.chunks++;
                if (turn.chunks >= 16) _flush(turn);
              } catch (error, stack) {
                fail(error, stack);
              }
            },
            onError: (Object error, StackTrace stack) => fail(error, stack),
            onDone: () {
              if (!completed.isCompleted) completed.complete();
            },
            cancelOnError: true,
          );
      await completed.future;
    } finally {
      turn.flushTimer?.cancel();
      // The transport owns its HTTP client. Cancelling an async* subscription
      // can itself wait for I/O, so no tree mutation depends on this Future.
      subscription?.cancel().ignore();
    }
  }

  void _flush(_Turn turn) {
    if (!turn.dirty || turn.reply == null) return;
    final message = _buffered(turn);
    if (turn.kind != _TurnKind.impersonate) {
      final extra = _store.node(turn.chat.id, message.nodeId).extra;
      turn.lastCommitted = _store.updateMessage(
        turn.chat.id,
        message.nodeId,
        text: message.text,
        reasoning: message.reasoning,
        usage: message.usage,
        extra: _inspectionExtra(extra, turn.inspection),
      );
    } else {
      _writeLatestInspection(turn.chat.id, turn.inspection);
      turn.lastCommitted = message;
    }
    turn.dirty = false;
    turn.chunks = 0;
  }

  TavernMessage _buffered(_Turn turn) {
    final reply = turn.reply!;
    final reasoning = turn.reasoning!.toString();
    return TavernMessage(
      nodeId: reply.nodeId,
      parentId: reply.parentId,
      role: reply.role,
      speaker: reply.speaker,
      text: turn.text!.toString(),
      reasoning: reasoning.isEmpty && reply.reasoning == null ? null : reasoning,
      at: reply.at,
      siblingIndex: reply.siblingIndex,
      siblingCount: reply.siblingCount,
      hidden: reply.hidden,
      usage: turn.usage,
    );
  }

  TavernMessage _latest(_Turn turn) =>
      turn.kind == _TurnKind.impersonate ? _buffered(turn) : _store.message(turn.chat.id, turn.reply!.nodeId);

  void _rollbackEmpty(_Turn turn, TavernTurnInspection failed) {
    if (turn.kind == _TurnKind.impersonate) {
      _persistInspection(turn, failed);
      return;
    }
    _store.transaction(() {
      final original = turn.originalTarget;
      if (turn.kind == _TurnKind.continueReply && turn.reply != null && original != null) {
        final message = original.message;
        _store.updateMessage(
          turn.chat.id,
          message.nodeId,
          text: message.text,
          reasoning: message.reasoning,
          clearReasoning: message.reasoning == null,
          usage: message.usage,
          clearUsage: message.usage == null,
          extra: original.extra,
        );
      } else if (turn.reply != null) {
        _store.deleteFrom(turn.chat.id, turn.reply!.nodeId);
      }
      if (turn.newUserId != null) _store.deleteFrom(turn.chat.id, turn.newUserId!);
      // Restore deepest choices first, then the old active leaf. Selecting a
      // child only rewrites its ancestors, never its remembered descendants.
      for (final selection in turn.previousSelections.reversed) {
        _store.selectNode(turn.chat.id, selection.$2 ?? selection.$1, restoreDescendants: selection.$2 != null);
      }
      if (turn.chat.currentLeafId != null) {
        _store.selectNode(turn.chat.id, turn.chat.currentLeafId!, restoreDescendants: false);
      }
      _store.updateChat(turn.chat.id, variables: turn.chat.variables);
      _writeLatestInspection(turn.chat.id, failed);
    });
    _setInspection(turn, failed);
    _liveVariables[turn.chat.id] = (leaf: turn.chat.currentLeafId, values: _runtimeCopy(turn.originalVariables));
  }

  Stream<T> _watch<T>(Stream<void> changes, FutureOr<T> Function() snapshot) {
    late StreamController<T> controller;
    StreamSubscription<void>? subscription;
    var ended = false;
    var dirty = false;
    var pumping = false;
    Future<void> refresh() async {
      dirty = true;
      if (pumping) return;
      pumping = true;
      try {
        while (dirty && !ended && !_closed) {
          dirty = false;
          try {
            final value = await snapshot();
            // A change during the first asynchronous file load must not be
            // lost, nor should it publish a knowingly stale initial snapshot.
            if (!ended && !_closed && !dirty) controller.add(value);
          } catch (error, stack) {
            if (!ended && !_closed) controller.addError(error, stack);
          }
        }
      } finally {
        pumping = false;
      }
    }

    controller = StreamController<T>(
      onListen: () {
        if (_closed) {
          ended = true;
          unawaited(controller.close());
          return;
        }
        subscription = changes.listen(
          (_) => unawaited(refresh()),
          onDone: () {
            ended = true;
            unawaited(controller.close());
          },
        );
        unawaited(refresh());
      },
      onCancel: () {
        ended = true;
        return subscription?.cancel();
      },
    );
    return controller.stream;
  }

  @override
  Future<void> close() => _closeFuture ??= _close();

  Future<void> _close() async {
    _closing = true;
    for (final turn in _turns.values) {
      turn.cancellation.cancel();
    }
    while (_turns.isNotEmpty || _operations.isNotEmpty) {
      await Future.wait<void>([..._operations, for (final turn in _turns.values) turn.done.future]);
    }
    await _fileQueue;
    await _libraryQueue;
    await _personaQueue;
    await _storeSubscription.cancel();
    _liveVariables.clear();
    _latestInspections.clear();
    _inspections.clear();
    _closed = true;
    unawaited(_charactersChanged.close());
    unawaited(_chatsChanged.close());
    unawaited(_paths.close());
    await _personas.close();
    await _store.close();
  }
}

enum _TurnKind { send, regenerate, continueReply, impersonate }

class _Turn {
  _Turn(
    this.chat,
    this.kind,
    this.input,
    this.nodeId,
    this.controller,
    this.config,
    this.settings,
    this.at,
    this.personaSelection,
  ) {
    inspection = TavernTurnInspection(
      chatId: chat.id,
      contextNodeId: chat.currentLeafId,
      generationType: generationType,
      startedAt: at,
    );
  }
  late TavernTurnInspection inspection;
  final StoredChat chat;
  final _TurnKind kind;
  final String input;
  final String? nodeId;
  final StreamController<TavernEvent> controller;
  final TavernModelConfig config;
  final Map<String, Object?> settings;
  final DateTime at;
  final PersonaSelection personaSelection;
  final cancellation = ModelCancellation();
  final done = Completer<void>();
  bool abandoned = false;
  bool finished = false;
  bool terminal = false;
  bool hasOutput = false;
  bool receivedText = false;
  bool dirty = false;
  int chunks = 0;
  String? newUserId;
  StoredNode? originalTarget;
  TavernMessage? reply;
  TavernMessage? lastCommitted;
  StringBuffer? text;
  StringBuffer? reasoning;
  TavernUsage? usage;
  Timer? flushTimer;
  String postfix = '';
  Map<String, Object?> variables = {};
  Map<String, Object?> state = {};
  Map<String, Object?> originalVariables = {};
  final previousSelections = <(String, String?)>[];
  Map<String, Object?> get currentState => {..._copy(state), 'variables': _copy(variables)};
  String get generationType => switch (kind) {
    _TurnKind.send => 'normal',
    _TurnKind.regenerate => 'regenerate',
    _TurnKind.continueReply => 'continue',
    _TurnKind.impersonate => 'impersonate',
  };
  void begin(TavernMessage message) {
    reply = message;
    lastCommitted = message;
    text = StringBuffer(message.text);
    reasoning = StringBuffer(message.reasoning ?? '');
    usage = message.usage;
  }

  void emit(TavernEvent event) {
    if (!abandoned && !terminal && !controller.isClosed) controller.add(event);
  }
}

class _MacroEnvironment {
  _MacroEnvironment(
    this.card,
    this.settings,
    this.local,
    this.global,
    this.history,
    this.config,
    this.now,
    this.random,
    this.chatId,
    this.input,
    this.generationType, {
    this.chatIdHash,
  }) {
    final raw = _map(settings['preset']);
    preset = raw.isEmpty ? ChatPreset.stDefault() : ChatPreset(raw);
  }
  final Map<String, Object?> card;
  final Map<String, Object?> settings;
  final Map<String, Object?> local;
  final Map<String, Object?> global;
  final List<StoredNode> history;
  final TavernModelConfig config;
  final DateTime now;
  final double Function() random;
  final String chatId;
  final int? chatIdHash;
  final String input;
  final String generationType;
  final outlets = <String, String>{};
  late Map<String, Object?> _presetSettings;
  set preset(ChatPreset value) {
    _presetSettings = value.settings;
  }

  String get userName => settings['userName'] is String ? settings['userName'] as String : 'User';
  String get persona => _string(settings['persona']);
  int get maxContext => _integer(_presetSettings['openai_max_context'], 4095);
  int get maxResponse => _integer(_presetSettings['openai_max_tokens'], 300);

  String expand(String text, Map<String, String> overrides) => _expand(text, overrides, true);
  String baseExpand(String text, Map<String, String> overrides) => _expand(text, overrides, false);
  String _expand(String text, Map<String, String> overrides, bool replaceCard) => const MacroEngine().expand(
    text,
    MacroContext(
      localVariables: local,
      globalVariables: global,
      card: card,
      replaceCharacterCard: replaceCard,
      userName: userName,
      persona: persona,
      history: [
        for (final node in history)
          MacroMessage(
            text: node.message.text,
            isUser: node.message.role == TavernRole.user,
            isSystem: node.message.hidden || _systemMessage(node),
            swipeId: node.message.siblingIndex,
            swipeCount: node.message.siblingCount,
            sentAt: node.message.at,
          ),
      ],
      model: config.model,
      input: input,
      maxContext: maxContext,
      maxResponse: maxResponse,
      lastGenerationType: generationType,
      now: now,
      timeZoneOffset: now.timeZoneOffset,
      locale: _string(settings['locale']).isEmpty ? 'en' : _string(settings['locale']),
      random: random,
      chatId: chatId,
      chatIdHash: chatIdHash,
      outlets: outlets,
      extensions: _strings(settings['extensions']).toSet(),
      preferCharacterPrompt: _presetSettings['prefer_character_prompt'] != false,
      preferCharacterJailbreak: _presetSettings['prefer_character_jailbreak'] != false,
      collapseNewlines: settings['collapseNewlines'] == true,
      systemPromptOverride: settings['systemPromptOverride'] as String?,
      scenarioOverride: settings['scenarioOverride'] as String?,
      mesExamplesOverride: settings['mesExamplesOverride'] as String?,
    ),
    overrides: overrides,
  );
}

class _ConfiguredInjection {
  const _ConfiguredInjection(this.injection, {this.scan = false, this.authorNote = false});
  final PromptInjection injection;
  final bool scan;
  final bool authorNote;
}

List<_ConfiguredInjection> _configuredInjections(
  Map<String, Object?> settings,
  PreparedCharacterFields prepared,
  Map<String, Object?> card,
) {
  final result = <_ConfiguredInjection>[];
  final note = _map(settings['authorNote']);
  if (note.isNotEmpty && note['enabled'] != false) {
    result.add(
      _ConfiguredInjection(
        _injection(note, '2_floating_prompt', kind: 'authorNote'),
        scan: note['scan'] == true,
        authorNote: true,
      ),
    );
  }
  final depth = _map(_map(card['extensions'])['depth_prompt']);
  if (prepared['charDepthPrompt'].isNotEmpty) {
    result.add(
      _ConfiguredInjection(
        PromptInjection(
          fragment: PromptFragment(prepared['charDepthPrompt'], const PromptSource('card', 'DEPTH_PROMPT')),
          depth: _injectionDepth(depth['depth']),
          role: _role(depth['role']),
        ),
        scan: settings['scanDepthPrompt'] == true,
      ),
    );
  }
  final injections = settings['injections'];
  if (injections is List<Object?>) {
    for (var index = 0; index < injections.length; index++) {
      final value = injections[index];
      if (value is! Map<String, Object?> || value['enabled'] == false) continue;
      final id = _string(value['id']);
      result.add(
        _ConfiguredInjection(_injection(value, id.isEmpty ? 'custom-$index' : id), scan: value['scan'] == true),
      );
    }
  }
  return result;
}

PromptInjection _injection(Map<String, Object?> value, String id, {String kind = 'extension'}) => PromptInjection(
  fragment: PromptFragment(_string(value['content']), PromptSource(kind, id)),
  role: _role(value['role']),
  depth: _injectionDepth(value['depth']),
  order: _integer(value['order'], 100),
  placement: switch (value['placement']) {
    'beforeMain' => PromptPlacement.beforeMain,
    'afterMain' => PromptPlacement.afterMain,
    _ => PromptPlacement.inChat,
  },
);

List<PromptInjection> _finishInjections(List<_ConfiguredInjection> initial, WorldInfoResult world) {
  final result = <PromptInjection>[];
  for (final item in initial) {
    final injection = item.injection;
    if (!item.authorNote) {
      result.add(injection);
      continue;
    }
    final before = world.authorNoteBefore.map((hit) => hit.content).join('\n');
    final after = world.authorNoteAfter.map((hit) => hit.content).join('\n');
    // ST removes one leading/trailing newline, not arbitrary whitespace.
    final content = '$before\n${injection.fragment.content}\n$after'.replaceAll(RegExp(r'(^\n)|(\n$)'), '');
    result.add(
      PromptInjection(
        fragment: PromptFragment(
          content,
          PromptSource(
            'authorNote',
            injection.fragment.source.id,
            details: {
              'worldInfo': [
                for (final hit in [...world.authorNoteBefore, ...world.authorNoteAfter]) _worldSource(hit).toJson(),
              ],
            },
          ),
        ),
        placement: injection.placement,
        role: injection.role,
        depth: injection.depth,
        order: injection.order,
      ),
    );
  }
  for (final depth in world.depths) {
    result.add(
      PromptInjection(
        fragment: PromptFragment(
          depth.content,
          PromptSource(
            'worldInfo',
            'customDepthWI_${depth.depth}_${depth.role}',
            details: {'entries': depth.entries.map((hit) => _worldSource(hit).toJson()).toList()},
          ),
        ),
        depth: depth.depth,
        role: _role(depth.role),
      ),
    );
  }
  return result;
}

PromptFragment _worldFragment(WorldInfoHit hit) => PromptFragment(hit.content, _worldSource(hit));
Map<String, Object?> _worldInfoTrace(WorldInfoResult world) => _copy({
  'budget': world.budget,
  'overflowed': world.overflowed,
  'scanRounds': world.scanRounds,
  'activated': [
    for (final hit in world.activated)
      {
        'bookId': hit.bookId,
        'uid': hit.uid,
        'source': hit.source.name,
        'reason': hit.reason,
        'content': hit.content,
        'originalContent': hit.originalContent,
        'order': hit.order,
        'position': hit.entry.position,
        'depth': hit.entry.depth,
        'role': hit.entry.role,
        'outlet': hit.entry.outlet,
        'phase': hit.phase.name,
        'round': hit.round,
        'primaryKey': hit.primaryKey,
        'secondaryMatches': hit.secondaryMatches,
        'probabilityRoll': hit.probabilityRoll,
      },
  ],
});

PromptSource _worldSource(WorldInfoHit hit) => PromptSource(
  'worldInfo',
  '${hit.bookId}:${hit.uid}',
  label: hit.entry.comment,
  details: {
    'bookId': hit.bookId,
    'uid': hit.uid,
    'source': hit.source.name,
    'order': hit.order,
    'reason': hit.reason,
    'originalContent': hit.originalContent,
  },
);

bool _systemMessage(StoredNode node) => node.message.role == TavernRole.system || node.original['is_system'] == true;
PromptHistoryMessage _promptHistory(StoredNode node) => PromptHistoryMessage(
  id: node.message.nodeId,
  role: switch (node.message.role) {
    TavernRole.user => 'user',
    TavernRole.character => 'assistant',
    TavernRole.narrator => 'narrator',
    TavernRole.system => 'system',
  },
  content: node.message.text,
  name: node.message.speaker,
  hidden: node.message.hidden,
  isSystem: node.original['is_system'] == true,
  forceAvatar: _jsTruthy(node.original['force_avatar']),
  toolCalls: node.original['tool_calls'] is List<Object?>
      ? (node.original['tool_calls'] as List<Object?>).whereType<Map<String, Object?>>().map(_copy).toList()
      : null,
  toolCallId: node.original['tool_call_id'] as String?,
);

Map<String, Object?> _decodeObject(String text, String description) {
  final value = jsonDecode(text.startsWith('\uFEFF') ? text.substring(1) : text);
  if (value is! Map<String, Object?>) throw FormatException('$description must be a JSON object.');
  return value;
}

// Variable arithmetic follows JS Number, including non-finite values. JS
// JSON.stringify writes those as null; keep that boundary in both SQLite and
// settings rather than letting a legal macro poison every subsequent turn.
Object? _jsonCompatible(Object? value) {
  if (value is num && !value.isFinite) return null;
  if (value is List<Object?>) return value.map(_jsonCompatible).toList();
  if (value is Map<String, Object?>) {
    return {for (final entry in value.entries) entry.key: _jsonCompatible(entry.value)};
  }
  return value;
}

String _jsonString(Map<String, Object?> value) => jsonEncode(_jsonCompatible(value));
Map<String, Object?> _copy(Map<String, Object?> value) => jsonDecode(_jsonString(value)) as Map<String, Object?>;
Object? _runtimeValue(Object? value) {
  if (value is List<Object?>) return value.map(_runtimeValue).toList();
  if (value is Map<String, Object?>) return _runtimeCopy(value);
  return value;
}

Map<String, Object?> _runtimeCopy(Map<String, Object?> value) => {
  for (final entry in value.entries) entry.key: _runtimeValue(entry.value),
};
bool _jsTruthy(Object? value) =>
    value != null && value != false && value != '' && !(value is num && (value == 0 || value.isNaN));
Map<String, Object?> _personaSettings(Map<String, Object?> settings, PersonaSelection selection) {
  final persona = selection.persona;
  if (persona == null) return settings;
  return {...settings, 'userName': persona.name, 'persona': persona.description, 'personaInPrompt': persona.inPrompt};
}

Map<String, Object?> _effectiveCard(Map<String, Object?> raw, Map<String, Object?> settings) {
  final card = _copy(raw);
  for (final key in const {
    'scenarioOverride': 'scenario',
    'systemPromptOverride': 'system_prompt',
    'mesExamplesOverride': 'mes_example',
  }.entries) {
    final value = settings[key.key];
    if (value is String && value.isNotEmpty) card[key.value] = value;
  }
  return card;
}

Map<String, Object?> _map(Object? value) => value is Map<String, Object?> ? _copy(value) : <String, Object?>{};
Map<String, Object?> _merge(Map<String, Object?> base, Map<String, Object?> patch) {
  final result = _copy(base);
  for (final entry in _copy(patch).entries) {
    final previous = result[entry.key];
    result[entry.key] = previous is Map<String, Object?> && entry.value is Map<String, Object?>
        ? _merge(previous, entry.value! as Map<String, Object?>)
        : entry.value;
  }
  return result;
}

String _string(Object? value) => value is String ? value : '';
List<String> _strings(Object? value) => value is List<Object?> ? value.whereType<String>().toList() : <String>[];
int _integer(Object? value, int fallback) => value is num && value.isFinite ? value.toInt() : fallback;
// An invalid in-chat depth remains non-injectable. In particular 4.5 must not
// silently become depth 4. The -1 sentinel is rejected by PromptAssembler but
// retains the extension's independent scan flag for world-info scanning.
int _injectionDepth(Object? value) {
  if (value == null) return 4;
  if (value is! num || !value.isFinite || value != value.truncateToDouble() || value < 0 || value > 10000) return -1;
  return value.toInt();
}

Map<String, Object?> _characterIdentity(Map<String, Object?> settings, String characterId) =>
    _merge(_map(_map(settings['characterIdentities'])[characterId]), _map(settings['characterIdentity']));
String _characterFilename(Map<String, Object?> settings, String characterId) {
  final filename = _string(_characterIdentity(settings, characterId)['avatarFilename']);
  final extension = filename.lastIndexOf('.');
  return extension > 0 ? filename.substring(0, extension) : filename;
}

List<String>? _characterTags(Map<String, Object?> settings, String characterId) {
  final value = _characterIdentity(settings, characterId)['tagIds'];
  return value is List<Object?> ? _strings(value) : null;
}

String _role(Object? value) => switch (value) {
  1 || 'user' => 'user',
  2 || 'assistant' => 'assistant',
  _ => 'system',
};
void _requireBookId(String id) {
  if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$').hasMatch(id)) {
    throw ArgumentError.value(id, 'id', 'Use a filename-safe lorebook id.');
  }
}

String _safeDetail(Object error) => error is TavernImportError
    ? error.message
    : error is PromptBudgetExceeded
    ? error.toString()
    : 'turn_failed (${error.runtimeType})';
String _plainText(String text) => text
    .replaceAll(RegExp(r'<(?:script|style)\b[^>]*>[\s\S]*?</(?:script|style)>', caseSensitive: false), '')
    .replaceAll(RegExp(r'</?[A-Za-z][^>]*>'), '')
    .replaceAllMapped(RegExp(r'!?\[([^\]]*)\]\([^)]*\)'), (match) => match[1]!)
    .replaceAll(RegExp(r'(^|\n)\s{0,3}(?:#{1,6}\s+|>\s*|[-*+]\s+)'), ' ')
    .replaceAll(RegExp(r'[`*_~]'), '')
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&quot;', '"')
    .replaceAll('&#39;', "'")
    .replaceAll('&nbsp;', ' ')
    .replaceAll('&amp;', '&')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();
