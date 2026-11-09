// A [Tavern] that is still opening (the engine opens its database and reads
// its settings asynchronously). Calls wait for it; streams start once it is
// open. The latest [configure] reaches it when it opens, so 酒馆设置 can be
// applied straight away.

import 'dart:async';
import 'dart:typed_data';

import 'package:dsh_tavern/dsh_tavern.dart';

class DeferredTavern implements Tavern {
  DeferredTavern(Future<Tavern> opening) {
    _ready = opening.then((tavern) {
      _open = tavern;
      if (_config case final config?) tavern.configure(config);
      return tavern;
    });
  }

  late final Future<Tavern> _ready;
  Tavern? _open;
  TavernModelConfig? _config;

  Stream<T> _stream<T>(Stream<T> Function(Tavern t) call) => Stream.fromFuture(_ready).asyncExpand(call);

  @override
  Stream<List<TavernCharacter>> watchCharacters() => _stream((t) => t.watchCharacters());

  @override
  Future<TavernCharacter?> character(String id) async => (await _ready).character(id);

  @override
  Future<TavernCharacter> importCard(Uint8List bytes, {String? fileName}) async =>
      (await _ready).importCard(bytes, fileName: fileName);

  @override
  Future<Uint8List> exportCard(String characterId, {TavernCardFormat format = TavernCardFormat.png}) async =>
      (await _ready).exportCard(characterId, format: format);

  @override
  Future<void> deleteCharacter(String characterId) async => (await _ready).deleteCharacter(characterId);

  @override
  Stream<List<TavernChatSummary>> watchChats({String? characterId}) =>
      _stream((t) => t.watchChats(characterId: characterId));

  @override
  Future<String> createChat(String characterId, {int greeting = 0}) async =>
      (await _ready).createChat(characterId, greeting: greeting);

  @override
  Future<void> deleteChat(String chatId) async => (await _ready).deleteChat(chatId);

  @override
  Future<List<TavernMessage>> path(String chatId, {int limit = 60, String? beforeNodeId}) async =>
      (await _ready).path(chatId, limit: limit, beforeNodeId: beforeNodeId);

  @override
  Stream<void> pathChanges(String chatId) => _stream((t) => t.pathChanges(chatId));

  @override
  Stream<TavernEvent> send(String chatId, String text) => _stream((t) => t.send(chatId, text));

  @override
  Stream<TavernEvent> regenerate(String chatId, String nodeId) => _stream((t) => t.regenerate(chatId, nodeId));

  @override
  Stream<TavernEvent> continueReply(String chatId, String nodeId) => _stream((t) => t.continueReply(chatId, nodeId));

  @override
  Stream<TavernEvent> impersonate(String chatId) => _stream((t) => t.impersonate(chatId));

  /// Nothing to stop before it is open: no turn can be running yet.
  @override
  void stop(String chatId) => _open?.stop(chatId);

  @override
  Future<void> selectSibling(String chatId, String nodeId, int index) async =>
      (await _ready).selectSibling(chatId, nodeId, index);

  @override
  Future<void> edit(String chatId, String nodeId, String text) async => (await _ready).edit(chatId, nodeId, text);

  @override
  Future<void> deleteFrom(String chatId, String nodeId) async => (await _ready).deleteFrom(chatId, nodeId);

  @override
  Future<void> setHidden(String chatId, String nodeId, bool hidden) async =>
      (await _ready).setHidden(chatId, nodeId, hidden);

  @override
  void configure(TavernModelConfig config) {
    _config = config;
    _open?.configure(config);
  }

  @override
  Future<void> close() async => (await _ready).close();
}
