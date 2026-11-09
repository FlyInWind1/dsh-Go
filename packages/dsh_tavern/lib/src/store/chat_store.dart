import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:sqlite3/sqlite3.dart';

import '../api.dart';

/// The chat settings and original ST metadata, separate from the selected path.
/// JSON values returned by the store are detached copies.
class StoredChat {
  const StoredChat({
    required this.id,
    required this.characterId,
    required this.title,
    required this.createdAt,
    required this.updatedAt,
    required this.metadata,
    required this.variables,
    required this.settings,
    this.personaId,
    this.presetId,
    this.currentLeafId,
    this.selectedRootId,
  });

  final String id;
  final String characterId;
  final String title;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String? personaId;
  final String? presetId;
  final String? currentLeafId;
  final String? selectedRootId;
  final Map<String, Object?> metadata;
  final Map<String, Object?> variables;
  final Map<String, Object?> settings;
}

/// The fields needed by tree/JSONL import and export but not by the chat canvas.
class StoredNode {
  const StoredNode({
    required this.message,
    required this.depth,
    required this.extra,
    required this.original,
    this.selectedChildId,
  });

  final TavernMessage message;
  final int depth;
  final String? selectedChildId;
  final Map<String, Object?> extra;

  /// Original ST message fields not represented by [TavernMessage]. Exporters
  /// overlay the current known fields instead of discarding unknown fields.
  final Map<String, Object?> original;
}

/// The SQLite owner. Methods are synchronous so a tree edit and its remembered
/// path cannot be interleaved by a streaming callback on this isolate.
///
/// Only committed writes emit [changes]. The Tavern facade owns subscriptions
/// and combines these notifications with the character-file library.
class ChatStore {
  ChatStore._(this._db, {DateTime Function()? clock, String Function()? createId})
    : _clock = clock ?? DateTime.now,
      _createId = createId ?? _newId {
    try {
      _initialize();
    } catch (_) {
      _db.close();
      rethrow;
    }
  }

  factory ChatStore.open(String path, {DateTime Function()? clock, String Function()? createId}) {
    File(path).parent.createSync(recursive: true);
    return ChatStore._(sqlite3.open(path), clock: clock, createId: createId);
  }

  factory ChatStore.inMemory({DateTime Function()? clock, String Function()? createId}) {
    return ChatStore._(sqlite3.openInMemory(), clock: clock, createId: createId);
  }

  /// Takes ownership of an open connection, including closing it on failure.
  /// The connection must not have an active transaction. Callers must not run
  /// independent transactions on it while the store is open. This also permits
  /// SQLite configuration and fault injection in integration tests.
  factory ChatStore.fromDatabase(Database database, {DateTime Function()? clock, String Function()? createId}) {
    return ChatStore._(database, clock: clock, createId: createId);
  }

  static const schemaVersion = 1;
  final Database _db;
  final DateTime Function() _clock;
  final String Function() _createId;
  final _changes = StreamController<String>.broadcast();
  final _changedChats = <String>{};
  var _transactionDepth = 0;
  ({Object error, StackTrace stackTrace})? _transactionFailure;
  var _closed = false;

  Stream<String> get changes => _changes.stream;

  void _initialize() {
    if (!_db.autocommit) {
      throw ArgumentError('ChatStore requires a connection without an active transaction.');
    }
    final version = _db.select('PRAGMA user_version').first['user_version'] as int;
    if (version > schemaVersion) {
      throw StateError('This tavern database uses schema $version; supported version is $schemaVersion.');
    }
    _db.execute('PRAGMA foreign_keys = ON');
    _db.execute('PRAGMA busy_timeout = 5000');
    _db.execute('PRAGMA journal_mode = WAL');
    _db.execute('PRAGMA synchronous = FULL');
    if (version == 0) {
      transaction(() {
        _db.execute(_schemaV1);
        _db.execute('PRAGMA user_version = 1');
      });
    }
  }

  /// Batches synchronous operations atomically. Nested calls use savepoints;
  /// catching a failed nested operation does not retain half of that operation.
  /// If SQLite aborts the entire transaction, every enclosing batch must fail.
  /// Future-returning callbacks are rejected before invocation when their type
  /// is identifiable. Only synchronous callbacks are supported: this method
  /// cannot cancel asynchronous work a callback schedules or hides behind a
  /// dynamic return type.
  T transaction<T>(T Function() operation) {
    _ensureOpen();
    _checkTransactionState();
    if (operation is Future<dynamic> Function()) {
      throw ArgumentError('ChatStore.transaction requires a synchronous callback.');
    }
    final depth = _transactionDepth;
    final previousChanges = Set<String>.of(_changedChats);
    final savepoint = 'tavern_$depth';
    var started = false;
    var completed = false;
    late T value;
    try {
      _db.execute(depth == 0 ? 'BEGIN IMMEDIATE' : 'SAVEPOINT $savepoint');
      started = true;
      _transactionDepth = depth + 1;
      value = operation();
      if (value is Future<dynamic>) {
        // A callback with an erased return type may already have started.
        // Observe its eventual error, while rejecting the unsupported result.
        value.ignore();
        throw ArgumentError('ChatStore.transaction requires a synchronous callback.');
      }
      _checkTransactionState();
      _db.execute(depth == 0 ? 'COMMIT' : 'RELEASE SAVEPOINT $savepoint');
      completed = true;
    } catch (error, stackTrace) {
      try {
        // FULL/IOERR can make SQLite roll back without another SQL statement.
        // In that case there are no remaining savepoints to roll back to.
        if (started && !_db.autocommit) {
          if (depth == 0 || _transactionFailure != null) {
            _db.execute('ROLLBACK');
          } else {
            _db.execute('ROLLBACK TO SAVEPOINT $savepoint');
            _db.execute('RELEASE SAVEPOINT $savepoint');
          }
        }
        if (depth > 0 && _db.autocommit) {
          _transactionFailure ??= (error: error, stackTrace: stackTrace);
        }
      } catch (_) {
        // Cleanup failure must neither replace the original exception nor let
        // an enclosing batch continue after losing its atomicity.
        _transactionFailure ??= (error: error, stackTrace: stackTrace);
      }
      rethrow;
    } finally {
      _transactionDepth = depth;
      if (!completed) {
        _changedChats.clear();
        if (depth > 0 && _transactionFailure == null) {
          _changedChats.addAll(previousChanges);
        }
      }
      if (depth == 0) _transactionFailure = null;
    }
    if (depth == 0) {
      final changed = List<String>.of(_changedChats);
      _changedChats.clear();
      for (final chatId in changed) {
        _changes.add(chatId);
      }
    }
    return value;
  }

  void _checkTransactionState() {
    final failure = _transactionFailure;
    if (failure != null) {
      Error.throwWithStackTrace(failure.error, failure.stackTrace);
    }
    if (_transactionDepth > 0 && _db.autocommit) {
      throw StateError('SQLite aborted the enclosing chat transaction.');
    }
  }

  String createChat({
    required String characterId,
    String title = '',
    String? id,
    String? personaId,
    String? presetId,
    Map<String, Object?> metadata = const {},
    Map<String, Object?> variables = const {},
    Map<String, Object?> settings = const {},
  }) {
    return transaction(() {
      final chatId = id ?? _createId();
      final at = _clock().millisecondsSinceEpoch;
      _db.execute(
        '''INSERT INTO chats
           (id, character_id, title, created_at, updated_at, persona_id, preset_id, metadata, variables, settings)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)''',
        [
          chatId,
          characterId,
          title,
          at,
          at,
          personaId,
          presetId,
          jsonEncode(metadata),
          jsonEncode(variables),
          jsonEncode(settings),
        ],
      );
      _changedChats.add(chatId);
      return chatId;
    });
  }

  StoredChat chat(String chatId) {
    final row = _chatRow(chatId);
    return StoredChat(
      id: row['id'] as String,
      characterId: row['character_id'] as String,
      title: row['title'] as String,
      createdAt: _date(row['created_at']),
      updatedAt: _date(row['updated_at']),
      personaId: row['persona_id'] as String?,
      presetId: row['preset_id'] as String?,
      currentLeafId: row['current_leaf_id'] as String?,
      selectedRootId: row['selected_root_id'] as String?,
      metadata: _map(row['metadata']),
      variables: _map(row['variables']),
      settings: _map(row['settings']),
    );
  }

  List<TavernChatSummary> listChats({String? characterId}) {
    _ensureOpen();
    final rows = _db.select(
      '''SELECT c.*, n.text AS last_text, COALESCE(n.depth, 0) AS message_count
         FROM chats c LEFT JOIN nodes n ON n.id = c.current_leaf_id
         WHERE (? IS NULL OR c.character_id = ?) ORDER BY c.updated_at DESC, c.id''',
      [characterId, characterId],
    );
    return [
      for (final row in rows)
        TavernChatSummary(
          id: row['id'] as String,
          characterId: row['character_id'] as String,
          title: row['title'] as String,
          updatedAt: _date(row['updated_at']),
          lastText: row['last_text'] as String?,
          messageCount: row['message_count'] as int,
        ),
    ];
  }

  /// Replaces only the provided JSON documents. To clear a persona/preset,
  /// pass the corresponding explicit clear flag.
  void updateChat(
    String chatId, {
    String? title,
    String? personaId,
    String? presetId,
    bool clearPersona = false,
    bool clearPreset = false,
    Map<String, Object?>? metadata,
    Map<String, Object?>? variables,
    Map<String, Object?>? settings,
  }) {
    transaction(() {
      final row = _chatRow(chatId);
      _db.execute(
        '''UPDATE chats SET title = ?, persona_id = ?, preset_id = ?, metadata = ?, variables = ?, settings = ?
           WHERE id = ?''',
        [
          title ?? row['title'],
          clearPersona ? null : personaId ?? row['persona_id'],
          clearPreset ? null : presetId ?? row['preset_id'],
          metadata == null ? row['metadata'] : jsonEncode(metadata),
          variables == null ? row['variables'] : jsonEncode(variables),
          settings == null ? row['settings'] : jsonEncode(settings),
          chatId,
        ],
      );
      _touch(chatId);
    });
  }

  /// A null [parentId] means a root sibling, never "the current leaf". Normal
  /// turns pass [StoredChat.currentLeafId]; a regeneration passes the old
  /// message's parent. Siblings retain their insertion order across restarts.
  TavernMessage append(
    String chatId, {
    required String? parentId,
    required TavernRole role,
    required String speaker,
    required String text,
    String? id,
    String? reasoning,
    DateTime? at,
    bool hidden = false,
    bool makeCurrent = true,
    TavernUsage? usage,
    Map<String, Object?> extra = const {},
    Map<String, Object?> original = const {},
    Map<String, Object?>? state,
  }) {
    return transaction(() {
      final chat = _chatRow(chatId);
      final parent = parentId == null ? null : _nodeRow(chatId, parentId);
      final depth = parent == null ? 1 : (parent['depth'] as int) + 1;
      final nodeId = id ?? _createId();
      _db.execute(
        '''INSERT INTO nodes
           (id, chat_id, parent_id, depth, role, speaker, text, reasoning, at, hidden, usage, extra, original)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)''',
        [
          nodeId,
          chatId,
          parentId,
          depth,
          role.name,
          speaker,
          text,
          reasoning,
          (at ?? _clock()).millisecondsSinceEpoch,
          hidden ? 1 : 0,
          _encodeUsage(usage),
          jsonEncode(extra),
          jsonEncode(original),
        ],
      );
      final parentState = parentId == null ? <String, Object?>{} : nodeState(chatId, parentId);
      final currentState = state ?? parentState;
      final checkpoint = depth == 1 || depth % 20 == 0;
      _db.execute('INSERT INTO node_states (node_id, delta_json, full_json) VALUES (?, ?, ?)', [
        nodeId,
        jsonEncode(_stateDiff(parentState, currentState)),
        checkpoint ? jsonEncode(currentState) : null,
      ]);
      if (makeCurrent) {
        if (parentId != null && parentId == chat['current_leaf_id']) {
          // The common append is constant-time; do not rewrite every ancestor
          // for every token/message in a long conversation.
          _db.execute('UPDATE nodes SET selected_child_id = ? WHERE id = ?', [nodeId, parentId]);
          _db.execute('UPDATE chats SET current_leaf_id = ? WHERE id = ?', [nodeId, chatId]);
        } else {
          _activate(chatId, nodeId);
        }
      }
      _touch(chatId);
      return message(chatId, nodeId);
    });
  }

  TavernMessage message(String chatId, String nodeId) => _message(_nodeRow(chatId, nodeId));

  StoredNode node(String chatId, String nodeId) => _storedNode(_nodeRow(chatId, nodeId));

  List<StoredNode> allNodes(String chatId) {
    _chatRow(chatId);
    return [
      for (final row in _db.select('SELECT n.*, $_siblingColumns FROM nodes n WHERE n.chat_id = ? ORDER BY n.seq', [
        chatId,
      ]))
        _storedNode(row),
    ];
  }

  List<StoredNode> children(String chatId, String? parentId) {
    _chatRow(chatId);
    if (parentId != null) _nodeRow(chatId, parentId);
    return [
      for (final row in _db.select(
        'SELECT n.*, $_siblingColumns FROM nodes n WHERE n.chat_id = ? AND n.parent_id IS ? ORDER BY n.seq',
        [chatId, parentId],
      ))
        _storedNode(row),
    ];
  }

  /// Reads at most [limit] ancestors, starting at the current leaf or just
  /// before a cursor on that path. The result is always oldest first.
  List<TavernMessage> path(String chatId, {int limit = 60, String? beforeNodeId}) {
    if (limit < 0) throw ArgumentError.value(limit, 'limit', 'Must be non-negative.');
    final row = _chatRow(chatId);
    final currentLeaf = row['current_leaf_id'] as String?;
    var lastId = currentLeaf;
    if (beforeNodeId != null) {
      final before = _nodeRow(chatId, beforeNodeId);
      if (currentLeaf == null || !_isAncestor(chatId, beforeNodeId, currentLeaf)) {
        throw StateError('The page cursor is not on the current path.');
      }
      lastId = before['parent_id'] as String?;
    }
    if (limit == 0 || lastId == null) return [];
    final rows = _db.select(
      '''WITH RECURSIVE path(id, parent_id, distance) AS (
           SELECT id, parent_id, 0 FROM nodes WHERE chat_id = ? AND id = ?
           UNION ALL
           SELECT n.id, n.parent_id, p.distance + 1
           FROM nodes n JOIN path p ON n.id = p.parent_id WHERE p.distance + 1 < ?
         )
         SELECT n.*, $_siblingColumns FROM path p JOIN nodes n ON n.id = p.id ORDER BY p.distance DESC''',
      [chatId, lastId, limit],
    );
    return [for (final item in rows) _message(item)];
  }

  void selectSibling(String chatId, String nodeId, int index) {
    transaction(() {
      final row = _nodeRow(chatId, nodeId);
      final siblings = _db.select('SELECT id FROM nodes WHERE chat_id = ? AND parent_id IS ? ORDER BY seq', [
        chatId,
        row['parent_id'],
      ]);
      RangeError.checkValidIndex(index, siblings, 'index');
      _activate(chatId, siblings[index]['id'] as String);
      _touch(chatId);
    });
  }

  /// Selects a node and restores the path remembered beneath it. Clearing that
  /// remembered selection keeps descendants stored and stops the path here.
  void selectNode(String chatId, String nodeId, {bool restoreDescendants = true}) {
    transaction(() {
      _nodeRow(chatId, nodeId);
      if (!restoreDescendants) _db.execute('UPDATE nodes SET selected_child_id = NULL WHERE id = ?', [nodeId]);
      _activate(chatId, nodeId);
      _touch(chatId);
    });
  }

  /// Restores a complete selection snapshot, including inactive branches and
  /// explicit null stops. Every stored node must occur exactly once in the
  /// map. A null root keeps the tree but selects an empty path.
  ///
  /// Importers can assemble a tree with makeCurrent:false and publish all
  /// choices in O(nodes), without selectNode rewriting every ancestor for
  /// every imported row. Validation finishes before any selection is changed.
  void restoreSelection(
    String chatId, {
    required String? selectedRootId,
    required Map<String, String?> selectedChildren,
  }) {
    transaction(() {
      _chatRow(chatId);
      final choices = Map<String, String?>.of(selectedChildren);
      final rows = _db.select('SELECT id, parent_id, selected_child_id FROM nodes WHERE chat_id = ?', [chatId]);
      final parents = <String, String?>{for (final row in rows) row['id'] as String: row['parent_id'] as String?};
      if (choices.length != parents.length || parents.keys.any((id) => !choices.containsKey(id))) {
        throw ArgumentError('A selection snapshot must contain every node of this chat, and no other nodes.');
      }
      if (selectedRootId != null && (!parents.containsKey(selectedRootId) || parents[selectedRootId] != null)) {
        throw ArgumentError.value(selectedRootId, 'selectedRootId', 'Must be a root of this chat.');
      }
      for (final entry in choices.entries) {
        final child = entry.value;
        if (child != null && (!parents.containsKey(child) || parents[child] != entry.key)) {
          throw ArgumentError('Selected child $child is not a child of ${entry.key} in this chat.');
        }
      }
      var leaf = selectedRootId;
      while (leaf != null && choices[leaf] != null) {
        leaf = choices[leaf];
      }
      for (final row in rows) {
        final id = row['id'] as String;
        if (row['selected_child_id'] != choices[id]) {
          _db.execute('UPDATE nodes SET selected_child_id = ? WHERE id = ?', [choices[id], id]);
        }
      }
      _db.execute('UPDATE chats SET selected_root_id = ?, current_leaf_id = ? WHERE id = ?', [
        selectedRootId,
        leaf,
        chatId,
      ]);
      _touch(chatId);
    });
  }

  TavernMessage updateMessage(
    String chatId,
    String nodeId, {
    String? text,
    String? reasoning,
    TavernUsage? usage,
    bool clearReasoning = false,
    bool clearUsage = false,
    Map<String, Object?>? extra,
    Map<String, Object?>? original,
  }) {
    return transaction(() {
      final row = _nodeRow(chatId, nodeId);
      _db.execute('UPDATE nodes SET text = ?, reasoning = ?, usage = ?, extra = ?, original = ? WHERE id = ?', [
        text ?? row['text'],
        clearReasoning ? null : reasoning ?? row['reasoning'],
        clearUsage
            ? null
            : usage == null
            ? row['usage']
            : _encodeUsage(usage),
        extra == null ? row['extra'] : jsonEncode(extra),
        original == null ? row['original'] : jsonEncode(original),
        nodeId,
      ]);
      _touch(chatId);
      return message(chatId, nodeId);
    });
  }

  void edit(String chatId, String nodeId, String text) {
    updateMessage(chatId, nodeId, text: text);
  }

  void setHidden(String chatId, String nodeId, bool hidden) {
    transaction(() {
      _nodeRow(chatId, nodeId);
      _db.execute('UPDATE nodes SET hidden = ? WHERE id = ?', [hidden ? 1 : 0, nodeId]);
      _touch(chatId);
    });
  }

  /// Removes every descendant in one SQL statement, avoiding the SQLite
  /// cascade-trigger depth limit on long conversations. If the selected child
  /// is deleted, choose its next surviving sibling (or the previous last one).
  /// Deleting a different branch does not move the current leaf.
  void deleteFrom(String chatId, String nodeId) {
    transaction(() {
      final chat = _chatRow(chatId);
      final target = _nodeRow(chatId, nodeId);
      final parentId = target['parent_id'] as String?;
      final leafId = chat['current_leaf_id'] as String?;
      final changesCurrent = leafId != null && _isAncestor(chatId, nodeId, leafId);
      final selectedId = parentId == null
          ? chat['selected_root_id'] as String?
          : _nodeRow(chatId, parentId)['selected_child_id'] as String?;
      final siblings = _db.select(
        'SELECT id FROM nodes WHERE chat_id = ? AND parent_id IS ? AND id != ? ORDER BY seq',
        [chatId, parentId, nodeId],
      );
      final oldIndex = target['sibling_index'] as int;
      final replacement = siblings.isEmpty ? null : siblings[min(oldIndex, siblings.length - 1)]['id'] as String;
      _db.execute(
        '''WITH RECURSIVE subtree(id) AS (
             SELECT id FROM nodes WHERE chat_id = ? AND id = ?
             UNION ALL SELECT n.id FROM nodes n JOIN subtree s ON n.parent_id = s.id
           ) DELETE FROM nodes WHERE id IN (SELECT id FROM subtree)''',
        [chatId, nodeId],
      );
      if (selectedId == nodeId) {
        if (parentId == null) {
          _db.execute('UPDATE chats SET selected_root_id = ? WHERE id = ?', [replacement, chatId]);
        } else {
          _db.execute('UPDATE nodes SET selected_child_id = ? WHERE id = ?', [replacement, parentId]);
        }
      }
      if (changesCurrent) {
        final newSelection = replacement ?? parentId;
        if (newSelection == null) {
          _db.execute('UPDATE chats SET current_leaf_id = NULL, selected_root_id = NULL WHERE id = ?', [chatId]);
        } else {
          _activate(chatId, newSelection);
        }
      }
      _touch(chatId);
    });
  }

  void deleteChat(String chatId) {
    transaction(() {
      _chatRow(chatId);
      _db.execute('DELETE FROM chats WHERE id = ?', [chatId]);
      _changedChats.add(chatId);
    });
  }

  void deleteCharacterChats(String characterId) {
    transaction(() {
      final rows = _db.select('SELECT id FROM chats WHERE character_id = ?', [characterId]);
      _db.execute('DELETE FROM chats WHERE character_id = ?', [characterId]);
      _changedChats.addAll(rows.map((row) => row['id'] as String));
    });
  }

  /// Rebuilds from the nearest checkpoint, at most 19 intervening deltas.
  /// The initial empty state has [] deltas and {} checkpoints. Imported states
  /// can use top-level RFC 6902 add/replace/remove operations without losing
  /// nested arrays or objects; a changed top-level value is replaced whole.
  Map<String, Object?> nodeState(String chatId, String nodeId) {
    _nodeRow(chatId, nodeId);
    final rows = _db.select(
      '''WITH RECURSIVE states(id, parent_id, delta_json, full_json, distance) AS (
           SELECT n.id, n.parent_id, s.delta_json, s.full_json, 0
           FROM nodes n JOIN node_states s ON s.node_id = n.id WHERE n.chat_id = ? AND n.id = ?
           UNION ALL
           SELECT n.id, n.parent_id, s.delta_json, s.full_json, p.distance + 1
           FROM states p JOIN nodes n ON n.id = p.parent_id JOIN node_states s ON s.node_id = n.id
           WHERE p.full_json IS NULL
         ) SELECT * FROM states ORDER BY distance DESC''',
      [chatId, nodeId],
    );
    var state = <String, Object?>{};
    for (final row in rows) {
      if (row['full_json'] != null) {
        state = _map(row['full_json']);
      } else {
        final delta = jsonDecode(row['delta_json'] as String) as List<Object?>;
        for (final value in delta) {
          final operation = value as Map<String, Object?>;
          final path = operation['path'] as String;
          final key = path.substring(1).replaceAll('~1', '/').replaceAll('~0', '~');
          switch (operation['op']) {
            case 'remove':
              state.remove(key);
            case 'add' || 'replace':
              state[key] = operation['value'];
            default:
              throw StateError('Unsupported stored state delta operation: ${operation['op']}');
          }
        }
      }
    }
    return state;
  }

  List<TavernMessage> search(String query, {String? chatId, int limit = 50}) {
    _ensureOpen();
    if (limit < 0) throw ArgumentError.value(limit, 'limit', 'Must be non-negative.');
    if (query.trim().isEmpty || limit == 0) return [];
    final rows = _db.select(
      '''SELECT n.*, $_siblingColumns FROM nodes_fts JOIN nodes n ON n.seq = nodes_fts.rowid
         WHERE nodes_fts MATCH ? AND (? IS NULL OR n.chat_id = ?) ORDER BY rank LIMIT ?''',
      [query, chatId, chatId, limit],
    );
    return [for (final row in rows) _message(row)];
  }

  Future<void> close() async {
    if (_closed) return;
    if (_transactionDepth != 0) throw StateError('Cannot close a chat store inside a transaction.');
    _closed = true;
    _db.close();
    await _changes.close();
  }

  void _activate(String chatId, String nodeId) {
    final ancestors = _db.select(
      '''WITH RECURSIVE ancestors(id, parent_id, distance) AS (
           SELECT id, parent_id, 0 FROM nodes WHERE chat_id = ? AND id = ?
           UNION ALL SELECT n.id, n.parent_id, a.distance + 1 FROM nodes n JOIN ancestors a ON n.id = a.parent_id
         ) SELECT id FROM ancestors ORDER BY distance DESC''',
      [chatId, nodeId],
    );
    for (var index = 0; index + 1 < ancestors.length; index++) {
      _db.execute('UPDATE nodes SET selected_child_id = ? WHERE id = ?', [
        ancestors[index + 1]['id'],
        ancestors[index]['id'],
      ]);
    }
    final descendants = _db.select(
      '''WITH RECURSIVE descendants(id, selected_child_id, distance) AS (
           SELECT id, selected_child_id, 0 FROM nodes WHERE id = ?
           UNION ALL SELECT n.id, n.selected_child_id, d.distance + 1
           FROM nodes n JOIN descendants d ON n.id = d.selected_child_id
         ) SELECT id FROM descendants ORDER BY distance DESC LIMIT 1''',
      [nodeId],
    );
    _db.execute('UPDATE chats SET selected_root_id = ?, current_leaf_id = ? WHERE id = ?', [
      ancestors.first['id'],
      descendants.first['id'],
      chatId,
    ]);
  }

  bool _isAncestor(String chatId, String ancestorId, String nodeId) => _db
      .select(
        '''WITH RECURSIVE ancestors(id, parent_id) AS (
         SELECT id, parent_id FROM nodes WHERE chat_id = ? AND id = ?
         UNION ALL SELECT n.id, n.parent_id FROM nodes n JOIN ancestors a ON n.id = a.parent_id
       ) SELECT 1 FROM ancestors WHERE id = ? LIMIT 1''',
        [chatId, nodeId, ancestorId],
      )
      .isNotEmpty;

  Row _chatRow(String chatId) {
    _ensureOpen();
    final rows = _db.select('SELECT * FROM chats WHERE id = ?', [chatId]);
    if (rows.isEmpty) throw StateError('Chat not found: $chatId');
    return rows.first;
  }

  Row _nodeRow(String chatId, String nodeId) {
    _ensureOpen();
    final rows = _db.select('SELECT n.*, $_siblingColumns FROM nodes n WHERE n.chat_id = ? AND n.id = ?', [
      chatId,
      nodeId,
    ]);
    if (rows.isEmpty) throw StateError('Node does not belong to chat: $nodeId');
    return rows.first;
  }

  void _touch(String chatId) {
    _db.execute('UPDATE chats SET updated_at = ? WHERE id = ?', [_clock().millisecondsSinceEpoch, chatId]);
    _changedChats.add(chatId);
  }

  void _ensureOpen() {
    if (_closed) throw StateError('The chat store is closed.');
  }

  static StoredNode _storedNode(Row row) => StoredNode(
    message: _message(row),
    depth: row['depth'] as int,
    selectedChildId: row['selected_child_id'] as String?,
    extra: _map(row['extra']),
    original: _map(row['original']),
  );

  static TavernMessage _message(Row row) => TavernMessage(
    nodeId: row['id'] as String,
    parentId: row['parent_id'] as String?,
    role: TavernRole.values.byName(row['role'] as String),
    speaker: row['speaker'] as String,
    text: row['text'] as String,
    reasoning: row['reasoning'] as String?,
    at: _date(row['at']),
    hidden: row['hidden'] == 1,
    siblingIndex: row['sibling_index'] as int,
    siblingCount: row['sibling_count'] as int,
    usage: _decodeUsage(row['usage']),
  );

  static DateTime _date(Object? value) => DateTime.fromMillisecondsSinceEpoch(value as int, isUtc: true);
  static Map<String, Object?> _map(Object? value) => jsonDecode(value as String) as Map<String, Object?>;

  static String? _encodeUsage(TavernUsage? usage) => usage == null
      ? null
      : jsonEncode({
          'promptTokens': usage.promptTokens,
          'cacheHitTokens': usage.cacheHitTokens,
          'completionTokens': usage.completionTokens,
          'model': usage.model,
        });

  static TavernUsage? _decodeUsage(Object? value) {
    if (value == null) return null;
    final usage = _map(value);
    return TavernUsage(
      promptTokens: usage['promptTokens'] as int,
      cacheHitTokens: usage['cacheHitTokens'] as int,
      completionTokens: usage['completionTokens'] as int,
      model: usage['model'] as String?,
    );
  }

  static List<Map<String, Object?>> _stateDiff(Map<String, Object?> before, Map<String, Object?> after) {
    String pointer(String key) => '/${key.replaceAll('~', '~0').replaceAll('/', '~1')}';
    return [
      for (final key in before.keys)
        if (!after.containsKey(key)) {'op': 'remove', 'path': pointer(key)},
      for (final key in after.keys)
        if (!before.containsKey(key))
          {'op': 'add', 'path': pointer(key), 'value': after[key]}
        else if (jsonEncode(before[key]) != jsonEncode(after[key]))
          {'op': 'replace', 'path': pointer(key), 'value': after[key]},
    ];
  }

  static String _newId() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final hex = bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-'
        '${hex.substring(16, 20)}-${hex.substring(20)}';
  }

  static const _siblingColumns = '''
    (SELECT COUNT(*) FROM nodes s WHERE s.chat_id = n.chat_id AND s.parent_id IS n.parent_id AND s.seq < n.seq)
      AS sibling_index,
    (SELECT COUNT(*) FROM nodes s WHERE s.chat_id = n.chat_id AND s.parent_id IS n.parent_id) AS sibling_count''';

  static const _schemaV1 = '''
CREATE TABLE chats (
  id TEXT PRIMARY KEY NOT NULL,
  character_id TEXT NOT NULL,
  title TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  persona_id TEXT,
  preset_id TEXT,
  selected_root_id TEXT REFERENCES nodes(id) ON DELETE SET NULL DEFERRABLE INITIALLY DEFERRED,
  current_leaf_id TEXT REFERENCES nodes(id) ON DELETE SET NULL DEFERRABLE INITIALLY DEFERRED,
  metadata TEXT NOT NULL DEFAULT '{}',
  variables TEXT NOT NULL DEFAULT '{}',
  settings TEXT NOT NULL DEFAULT '{}'
);
CREATE INDEX chats_character_updated ON chats(character_id, updated_at DESC);
CREATE TABLE nodes (
  seq INTEGER PRIMARY KEY AUTOINCREMENT,
  id TEXT UNIQUE NOT NULL,
  chat_id TEXT NOT NULL REFERENCES chats(id) ON DELETE CASCADE,
  parent_id TEXT REFERENCES nodes(id) DEFERRABLE INITIALLY DEFERRED,
  selected_child_id TEXT REFERENCES nodes(id) ON DELETE SET NULL DEFERRABLE INITIALLY DEFERRED,
  depth INTEGER NOT NULL CHECK(depth >= 1),
  role TEXT NOT NULL CHECK(role IN ('user', 'character', 'narrator', 'system')),
  speaker TEXT NOT NULL,
  text TEXT NOT NULL,
  reasoning TEXT,
  at INTEGER NOT NULL,
  hidden INTEGER NOT NULL DEFAULT 0 CHECK(hidden IN (0, 1)),
  usage TEXT,
  extra TEXT NOT NULL DEFAULT '{}',
  original TEXT NOT NULL DEFAULT '{}'
);
CREATE INDEX nodes_chat_parent ON nodes(chat_id, parent_id, seq);
CREATE INDEX nodes_parent ON nodes(parent_id);
CREATE INDEX nodes_selected_child ON nodes(selected_child_id);
CREATE INDEX chats_selected_root ON chats(selected_root_id);
CREATE INDEX chats_current_leaf ON chats(current_leaf_id);
CREATE TABLE node_states (
  node_id TEXT PRIMARY KEY NOT NULL REFERENCES nodes(id) ON DELETE CASCADE,
  delta_json TEXT NOT NULL DEFAULT '[]',
  full_json TEXT
);
CREATE TABLE summaries (
  id TEXT PRIMARY KEY NOT NULL,
  chat_id TEXT NOT NULL REFERENCES chats(id) ON DELETE CASCADE,
  from_node_id TEXT REFERENCES nodes(id) ON DELETE CASCADE,
  to_node_id TEXT REFERENCES nodes(id) ON DELETE CASCADE,
  text TEXT NOT NULL,
  manually_edited INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE memories (
  id TEXT PRIMARY KEY NOT NULL,
  chat_id TEXT NOT NULL REFERENCES chats(id) ON DELETE CASCADE,
  entry_json TEXT NOT NULL
);
CREATE TABLE agent_runs (
  id TEXT PRIMARY KEY NOT NULL,
  chat_id TEXT NOT NULL REFERENCES chats(id) ON DELETE CASCADE,
  node_id TEXT REFERENCES nodes(id) ON DELETE SET NULL,
  kind TEXT NOT NULL,
  at INTEGER NOT NULL,
  usage TEXT,
  result_json TEXT
);
CREATE VIRTUAL TABLE nodes_fts USING fts5(text, speaker, content = 'nodes', content_rowid = 'seq');
CREATE TRIGGER nodes_fts_insert AFTER INSERT ON nodes BEGIN
  INSERT INTO nodes_fts(rowid, text, speaker) VALUES (new.seq, new.text, new.speaker);
END;
CREATE TRIGGER nodes_fts_delete AFTER DELETE ON nodes BEGIN
  INSERT INTO nodes_fts(nodes_fts, rowid, text, speaker) VALUES ('delete', old.seq, old.text, old.speaker);
END;
CREATE TRIGGER nodes_fts_update AFTER UPDATE OF text, speaker ON nodes BEGIN
  INSERT INTO nodes_fts(nodes_fts, rowid, text, speaker) VALUES ('delete', old.seq, old.text, old.speaker);
  INSERT INTO nodes_fts(rowid, text, speaker) VALUES (new.seq, new.text, new.speaker);
END;
''';
}
