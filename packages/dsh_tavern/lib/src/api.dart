// The tavern's surface for the app (docs/design/roleplay.md §4): what the
// screens read and call. The engine behind it — card IO, the chat store, the
// prompt assembler, the model client — implements [Tavern]; the app holds one
// and never reaches past it.
//
// Pure Dart, no Flutter. Everything here is value types and one interface, so
// the app can be built against a fake before the engine lands.

import 'dart:typed_data';

import 'inspection.dart';
import 'persona.dart';

/// One character in the library: the card's V3 `data` plus what the library
/// knows about it.
class TavernCharacter {
  const TavernCharacter({
    required this.id,
    required this.name,
    this.nickname,
    this.creator,
    this.tags = const [],
    this.avatarPath,
    this.description = '',
    this.creatorNotes = '',
    this.greetings = const [],
    this.regexCount = 0,
    this.scriptCount = 0,
    this.hasLorebook = false,
    this.chatCount = 0,
    this.lastChatAt,
    this.importedAt,
  });

  final String id;
  final String name;
  final String? nickname;
  final String? creator;
  final List<String> tags;

  /// The card picture on this phone (the PNG it came in, or the `main` icon).
  final String? avatarPath;
  final String description;

  /// May carry HTML; the canvas renders it.
  final String creatorNotes;

  /// `first_mes` first, then `alternate_greetings`.
  final List<String> greetings;

  /// The card's own regex scripts and 酒馆助手 scripts (roleplay-compat.md §6.1).
  final int regexCount;
  final int scriptCount;
  final bool hasLorebook;

  final int chatCount;
  final DateTime? lastChatAt;
  final DateTime? importedAt;
}

/// A conversation in the list.
class TavernChatSummary {
  const TavernChatSummary({
    required this.id,
    required this.characterId,
    required this.title,
    required this.updatedAt,
    this.lastText,
    this.messageCount = 0,
  });

  final String id;
  final String characterId;
  final String title;
  final DateTime updatedAt;

  /// The last message on the current path, plain text, for a preview line.
  final String? lastText;
  final int messageCount;
}

enum TavernRole { user, character, narrator, system }

/// One message on the current path. Alternatives are siblings in the tree
/// (roleplay.md §5.2): [siblingIndex] of [siblingCount].
class TavernMessage {
  const TavernMessage({
    required this.nodeId,
    required this.role,
    required this.speaker,
    required this.text,
    required this.at,
    this.parentId,
    this.reasoning,
    this.siblingIndex = 0,
    this.siblingCount = 1,
    this.hidden = false,
    this.usage,
  });

  final String nodeId;
  final String? parentId;
  final TavernRole role;

  /// Display name: the character's or the persona's.
  final String speaker;

  /// The stored text (after write-back regex). Display regex and Markdown run
  /// in the canvas, not here.
  final String text;
  final String? reasoning;
  final DateTime at;
  final int siblingIndex;
  final int siblingCount;

  /// Kept out of the prompt (ST `/hide`).
  final bool hidden;
  final TavernUsage? usage;
}

/// What one model call cost, as the API reported it.
class TavernUsage {
  const TavernUsage({this.promptTokens = 0, this.cacheHitTokens = 0, this.completionTokens = 0, this.model});

  final int promptTokens;
  final int cacheHitTokens;
  final int completionTokens;
  final String? model;
}

/// A turn as it streams. A turn always ends with exactly one [TavernTurnDone]
/// or [TavernTurnFailed].
sealed class TavernEvent {
  const TavernEvent();
}

/// The node the reply is written into exists (a new one, or a new sibling).
class TavernTurnStarted extends TavernEvent {
  const TavernTurnStarted(this.message);

  /// Empty text so far; carries the node id and its place among siblings.
  final TavernMessage message;
}

class TavernTextDelta extends TavernEvent {
  const TavernTextDelta(this.nodeId, this.text);
  final String nodeId;
  final String text;
}

class TavernReasoningDelta extends TavernEvent {
  const TavernReasoningDelta(this.nodeId, this.text);
  final String nodeId;
  final String text;
}

class TavernTurnDone extends TavernEvent {
  const TavernTurnDone(this.message, {this.finishReason});

  /// As stored: write-back regex applied, usage filled in.
  final TavernMessage message;

  /// The provider's finish_reason, including length or content_filter. Null
  /// means the transport did not report one; unknown future values are kept.
  final String? finishReason;
}

enum TavernFailure {
  noKey,
  badKey,
  busy,
  network,
  server,
  contextTooLong,
  cancelled,
  invalidCard,
  insufficientBalance,
  invalidParameters,
}

class TavernTurnFailed extends TavernEvent {
  const TavernTurnFailed(this.kind, {this.detail, this.partial});
  final TavernFailure kind;

  /// For 「详情」: a status code, the first part of an error body.
  final String? detail;

  /// Whatever arrived before it failed or was stopped; null when nothing was
  /// stored (the user's line goes back into the composer).
  final TavernMessage? partial;
}

enum TavernCardFormat { png, json, charx }

/// A named ST JSONL document. The filename is a label, never a path to read.
/// Bytes are copied at construction and cannot be changed through this value.
final class TavernChatFile {
  TavernChatFile({required this.fileName, required Uint8List bytes})
    : bytes = Uint8List.fromList(bytes).asUnmodifiableView();

  final String fileName;
  final Uint8List bytes;
}

/// One atomic batch may contain several independent chats and their branches.
final class TavernChatImportResult {
  TavernChatImportResult({
    required List<String> chatIds,
    required Map<String, String> chatsByFile,
    required List<String> notices,
  }) : chatIds = List<String>.unmodifiable(chatIds),
       chatsByFile = Map<String, String>.unmodifiable(chatsByFile),
       notices = List<String>.unmodifiable(notices);

  final List<String> chatIds;
  final Map<String, String> chatsByFile;
  final List<String> notices;
}

/// Where the model calls go. The key is read through [apiKey] each call, so
/// the app keeps it in secure storage and the engine never stores it.
class TavernModelConfig {
  const TavernModelConfig({
    required this.apiKey,
    this.baseUrl = 'https://api.deepseek.com',
    this.model = 'deepseek-flash',
    this.deepseek = true,
    this.thinking = false,
  });

  final Future<String?> Function() apiKey;
  final String baseUrl;
  final String model;

  /// DeepSeek's own API: ST's DeepSeek post-processing and `/beta` prefix
  /// continuation (roleplay-compat.md §3.4). False: a plain OpenAI-compatible
  /// endpoint.
  final bool deepseek;
  final bool thinking;
}

/// The tavern. One per app; [open] it on the app's support directory.
abstract interface class Tavern {
  // Library ------------------------------------------------------------------

  /// Every character, newest chat first, then newest import. Emits the current
  /// list first.
  Stream<List<TavernCharacter>> watchCharacters();

  Future<TavernCharacter?> character(String id);

  /// The complete V3 `data` object, including read-only unknown fields. The
  /// returned map is detached: editing it does not change the stored card.
  /// Optional fields may be absent. Null means the character does not exist.
  Future<Map<String, Object?>?> characterFields(String characterId);

  /// Saves only the supplied fields, retaining the rest of the card and all
  /// original assets. Editable strings: `name`, `nickname`, `description`,
  /// `personality`, `scenario`, `first_mes`, `mes_example`, `system_prompt`,
  /// `post_history_instructions`, `creator_notes`, `creator`,
  /// `character_version`. `alternate_greetings` and `tags` are string lists.
  ///
  /// Empty strings/lists clear a field; null and other keys/types throw
  /// [ArgumentError]. A nonempty patch updates V3 `modification_date` in Unix
  /// seconds. An empty patch is a read. Missing characters throw
  /// [TavernImportError]. Existing messages keep their text and speaker names.
  Future<TavernCharacter> updateCharacterFields(String characterId, Map<String, Object?> fields);

  /// A PNG / JSON / CHARX card (sniffed from the bytes, not the name), or an
  /// ST lorebook JSON (then it throws [TavernImportError] with
  /// [TavernImportError.isLorebook]; lorebooks import elsewhere later).
  Future<TavernCharacter> importCard(Uint8List bytes, {String? fileName});

  Future<Uint8List> exportCard(String characterId, {TavernCardFormat format = TavernCardFormat.png});

  /// Its chats go with it.
  Future<void> deleteCharacter(String characterId);

  // User personas ------------------------------------------------------------

  /// Saved personas, with the current committed list emitted first. Default
  /// and chat-binding changes also notify selectors through this stream.
  Stream<List<TavernPersona>> watchPersonas();

  Future<TavernPersona?> persona(String personaId);

  /// The optional avatar is a caller-owned file reference. Persona text is
  /// saved as entered; macros run only in the normal generation pipeline.
  /// Only position 0 currently injects the personaDescription prompt marker.
  Future<TavernPersona> createPersona({
    required String name,
    String description = '',
    String? avatarPath,
    int descriptionPosition = PersonaDescriptionPosition.inPrompt,
  });

  /// Null means unchanged; empty text is a real change. Use [clearAvatar] to
  /// remove an avatar reference. Active turns retain their captured persona.
  Future<TavernPersona> updatePersona(
    String personaId, {
    String? name,
    String? description,
    String? avatarPath,
    bool clearAvatar = false,
    int? descriptionPosition,
  });

  /// Cancels affected turns before removing the profile, default and matching
  /// chat bindings. Partial output and old messages remain; avatar files stay.
  Future<void> deletePersona(String personaId);

  /// Without [chatId], selects the global default. With it: chat binding,
  /// then global default, then no profile. This read never runs macros.
  Future<PersonaSelection> personaSelection({String? chatId});

  /// Null clears the default. Changes take effect on the next turn.
  Future<void> setDefaultPersona(String? personaId);

  /// Null restores inheritance from the global default. Cancels and waits for
  /// this chat's current turn before changing its binding.
  Future<void> bindPersona(String chatId, String? personaId);

  // Chats --------------------------------------------------------------------

  /// Newest first; all characters when [characterId] is null.
  Stream<List<TavernChatSummary>> watchChats({String? characterId});

  /// A new chat whose first message is greeting [greeting] (0 = `first_mes`).
  Future<String> createChat(String characterId, {int greeting = 0});

  /// Imports a same-character batch without adding greetings or evaluating
  /// macros. Related main_chat files become branches; unrelated files remain
  /// separate chats. A malformed document rejects the whole batch.
  ///
  /// [lorebookIds] maps ST world_info names to existing local lorebook IDs.
  /// Unmapped names remain in the exported header and produce a notice.
  Future<TavernChatImportResult> importChats(
    String characterId,
    List<TavernChatFile> files, {
    Map<String, String> lorebookIds = const {},
  });

  /// Exports the current path first, then the other stored branches. Each
  /// document has a fresh integrity UUID. Reading during a turn does not stop
  /// generation; only the state already committed to storage is included.
  Future<List<TavernChatFile>> exportChat(String chatId, {String? fileName});

  Future<void> deleteChat(String chatId);

  /// The current path, oldest first: the last [limit] messages, or the
  /// [limit] before [beforeNodeId] when paging back.
  Future<List<TavernMessage>> path(String chatId, {int limit = 60, String? beforeNodeId});

  /// Fires whenever the current path changes (a turn, a swipe, an edit) so the
  /// screen re-reads [path].
  Stream<void> pathChanges(String chatId);

  /// The recorded request for a node, or the chat's latest admitted attempt
  /// when [nodeId] is omitted. Reading never repeats macros, WI or assembly.
  /// Missing/deleted records return null. Branch selection does not change
  /// which attempt is latest. Ephemeral/empty failed attempts have no node.
  /// Estimates and this call's provider-reported usage are separate fields.
  Future<TavernTurnInspection?> inspectTurn(String chatId, {String? nodeId});

  // Turns --------------------------------------------------------------------

  /// Appends [text] as the user's message and streams the character's reply.
  /// Empty [text]: the character speaks next without a new user line.
  Stream<TavernEvent> send(String chatId, String text);

  /// A new reply as a sibling of [nodeId] (a character message), which becomes
  /// current.
  Stream<TavernEvent> regenerate(String chatId, String nodeId);

  /// More text at the end of [nodeId] (ST 「继续」).
  Stream<TavernEvent> continueReply(String chatId, String nodeId);

  /// Writes the user's next line for them (ST impersonate); not stored.
  Stream<TavernEvent> impersonate(String chatId);

  /// Stops whatever turn [chatId] is running. Its stream ends with
  /// [TavernTurnFailed] `cancelled`, keeping what arrived.
  void stop(String chatId);

  // Editing the tree -----------------------------------------------------------

  /// Makes sibling [index] of [nodeId] current (and its subtree's remembered
  /// path below it).
  Future<void> selectSibling(String chatId, String nodeId, int index);

  Future<void> edit(String chatId, String nodeId, String text);

  /// Removes [nodeId] and everything after it on every branch.
  Future<void> deleteFrom(String chatId, String nodeId);

  Future<void> setHidden(String chatId, String nodeId, bool hidden);

  // Settings -----------------------------------------------------------------

  /// Where model calls go from now on.
  void configure(TavernModelConfig config);

  /// A detached effective settings snapshot: global, imported source, then
  /// explicit chat settings. Reading does not evaluate macros or world info.
  Future<Map<String, Object?>> readSettings({String? chatId});

  /// Recursively merges objects; arrays/scalars replace their previous values.
  /// Null is a stored value, not a deletion. Chat changes cancel and await its
  /// active turn. Global changes apply to turns admitted after this call.
  Future<void> setSettings(Map<String, Object?> patch, {String? chatId});

  Future<void> close();
}

class TavernImportError implements Exception {
  const TavernImportError(this.message, {this.isLorebook = false});
  final String message;
  final bool isLorebook;

  @override
  String toString() => 'TavernImportError: $message';
}
