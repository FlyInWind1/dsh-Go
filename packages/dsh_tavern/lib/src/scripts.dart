import 'dart:async';
import 'dart:collection';

import 'api.dart' show TavernFailure, TavernRole;
import 'state.dart';

typedef TavernJsonObject = Map<String, Object?>;

enum TavernVariableScope { global, character, chat, message, script }

enum TavernScriptOwnerKind { global, character, preset }

enum TavernScriptRole { user, assistant, system }

enum TavernHiddenFilter { all, hiddenOnly, visibleOnly }

enum TavernScriptRefresh { none, affected, all }

enum TavernVariableChangeKind { set, insertIfAbsent, remove }

enum TavernScriptDispatchKind { cache, lifecycle }

enum TavernScriptAckStatus { completed, failed, cancelled }

enum TavernScriptErrorCode {
  noContext,
  closedContext,
  notFound,
  ambiguousName,
  duplicateId,
  range,
  invalidArgument,
  invalidJson,
  reservedField,
  shapeMismatch,
  stateValidation,
  revisionConflict,
  busy,
  unsupportedCommand,
  unsupportedOption,
  unsupportedCapability,
  hostUnavailable,
  callbackUnavailable,
  cancelled,
  storage,
  model,
  hookFailure,
}

/// Persistent script identity. An iframe instance is deliberately not a key.
class TavernScriptOwner {
  const TavernScriptOwner({required this.kind, required this.scriptId, this.assetId});
  final TavernScriptOwnerKind kind;
  final String? assetId;
  final String scriptId;
  @override
  bool operator ==(Object other) =>
      other is TavernScriptOwner && kind == other.kind && assetId == other.assetId && scriptId == other.scriptId;
  @override
  int get hashCode => Object.hash(kind, assetId, scriptId);
}

class TavernScriptContextSpec {
  const TavernScriptContextSpec({required this.instanceId, this.chatId, this.characterId, this.nodeId, this.script});
  final String instanceId;
  final String? chatId;
  final String? characterId;
  final String? nodeId;
  final TavernScriptOwner? script;
}

class TavernScriptContext {
  const TavernScriptContext({
    required this.id,
    required this.engineEpoch,
    required this.instanceId,
    this.chatId,
    this.characterId,
    this.nodeId,
    this.script,
  });
  final String id;
  final String engineEpoch;
  final String instanceId;
  final String? chatId;
  final String? characterId;
  final String? nodeId;
  final TavernScriptOwner? script;
}

class TavernScriptMessageRef {
  const TavernScriptMessageRef({required this.chatId, required this.nodeId});
  final String chatId;
  final String nodeId;
  @override
  bool operator ==(Object other) => other is TavernScriptMessageRef && chatId == other.chatId && nodeId == other.nodeId;
  @override
  int get hashCode => Object.hash(chatId, nodeId);
}

class TavernMessageRange {
  const TavernMessageRange({this.first, this.last});
  final int? first;
  final int? last;
}

class TavernScriptWriteOptions {
  const TavernScriptWriteOptions({this.expectedPathRevision, this.refresh = TavernScriptRefresh.affected});
  final String? expectedPathRevision;
  final TavernScriptRefresh refresh;
}

class TavernScriptShapeIssue {
  const TavernScriptShapeIssue({required this.fieldPath, required this.actualKind, required this.message});
  final String fieldPath;
  final String actualKind;
  final String message;
}

class TavernScriptSwipe {
  TavernScriptSwipe({
    required this.ref,
    required this.swipeId,
    required this.text,
    this.hasData = false,
    Object? rawData,
    this.dataIssue,
    TavernJsonObject info = const {},
  }) : _rawData = _scriptCopy(rawData),
       _info = _scriptObject(info);
  final TavernScriptMessageRef ref;
  final int swipeId;
  final String text;
  final bool hasData;
  final Object? _rawData;
  final TavernScriptShapeIssue? dataIssue;
  final TavernJsonObject _info;
  Object? get rawData => _scriptCopy(_rawData);
  TavernJsonObject? get data => !hasData
      ? <String, Object?>{}
      : _rawData is TavernJsonObject
      ? _scriptObject(_rawData)
      : null;
  TavernJsonObject get info => _scriptObject(_info);
}

class TavernScriptMessage {
  TavernScriptMessage({
    required this.messageId,
    required this.ref,
    required this.name,
    required this.role,
    required this.message,
    required this.nativeRole,
    this.hidden = false,
    this.speakerCharacterId,
    this.hasData = false,
    Object? rawData,
    this.dataIssue,
    TavernJsonObject extra = const {},
    this.swipeId = 0,
    List<TavernScriptSwipe> swipes = const [],
  }) : _rawData = _scriptCopy(rawData),
       _extra = _scriptObject(extra),
       swipes = List.unmodifiable(swipes);
  final int messageId;
  final TavernScriptMessageRef ref;
  final String name;
  final TavernScriptRole role;
  final TavernRole nativeRole;
  final String message;
  final bool hidden;
  final String? speakerCharacterId;
  final bool hasData;
  final Object? _rawData;
  final TavernScriptShapeIssue? dataIssue;
  final TavernJsonObject _extra;
  final int swipeId;
  final List<TavernScriptSwipe> swipes;
  Object? get rawData => _scriptCopy(_rawData);
  TavernJsonObject? get data => !hasData
      ? <String, Object?>{}
      : _rawData is TavernJsonObject
      ? _scriptObject(_rawData)
      : null;
  TavernJsonObject get extra => _scriptObject(_extra);
}

class TavernScriptMessagePage {
  TavernScriptMessagePage({
    required this.pathRevision,
    required this.totalPathLength,
    required List<TavernScriptMessage> messages,
  }) : messages = List.unmodifiable(messages);
  final String pathRevision;
  final int totalPathLength;
  final List<TavernScriptMessage> messages;
}

class TavernScriptMessagePatch {
  TavernScriptMessagePatch({this.messageId, this.ref, required TavernJsonObject fields})
    : _fields = _scriptObject(fields);
  final int? messageId;
  final TavernScriptMessageRef? ref;
  final TavernJsonObject _fields;
  TavernJsonObject get fields => _scriptObject(_fields);
}

class TavernScriptMessageDraft {
  TavernScriptMessageDraft({
    required this.role,
    required this.message,
    this.name,
    this.speakerCharacterId,
    this.hidden = false,
    TavernJsonObject? data,
    TavernJsonObject extra = const {},
  }) : _data = data == null ? null : _scriptObject(data),
       _extra = _scriptObject(extra);
  final TavernScriptRole role;
  final String message;
  final String? name;
  final String? speakerCharacterId;
  final bool hidden;
  final TavernJsonObject? _data;
  final TavernJsonObject _extra;

  /// Null means omitted in the native DTO. A wire adapter rejects explicit null.
  TavernJsonObject? get data => _data == null ? null : _scriptObject(_data);
  TavernJsonObject get extra => _scriptObject(_extra);
}

class TavernScriptMutation {
  TavernScriptMutation({
    required this.oldRevision,
    required this.pathRevision,
    List<TavernScriptMessage> upsertMessages = const [],
    List<TavernScriptMessageRef> affectedRefs = const [],
    List<TavernScriptMessageRef> removedRefs = const [],
    Map<int, TavernScriptMessageRef?> indexChanges = const {},
    this.refresh = TavernScriptRefresh.affected,
    Map<String, TavernStateEditResult> stateEdits = const {},
  }) : upsertMessages = List.unmodifiable(upsertMessages),
       affectedRefs = List.unmodifiable(affectedRefs),
       removedRefs = List.unmodifiable(removedRefs),
       indexChanges = Map.unmodifiable(indexChanges),
       stateEdits = Map.unmodifiable(stateEdits);
  final String oldRevision;
  final String pathRevision;
  final List<TavernScriptMessage> upsertMessages;
  final List<TavernScriptMessageRef> affectedRefs;
  final List<TavernScriptMessageRef> removedRefs;
  final Map<int, TavernScriptMessageRef?> indexChanges;
  final TavernScriptRefresh refresh;
  final Map<String, TavernStateEditResult> stateEdits;
}

class TavernVariableTarget {
  const TavernVariableTarget({
    required this.scope,
    this.characterId,
    this.chatId,
    this.messageRef,
    this.messageId,
    this.scriptOwner,
  });
  final TavernVariableScope scope;
  final String? characterId;
  final String? chatId;
  final TavernScriptMessageRef? messageRef;
  final int? messageId;
  final TavernScriptOwner? scriptOwner;
}

class TavernVariableSnapshot {
  TavernVariableSnapshot({
    required this.resolvedTarget,
    required this.version,
    required TavernJsonObject value,
    this.stateEdit,
  }) : _value = _scriptObject(value);
  final TavernVariableTarget resolvedTarget;
  final String version;
  final TavernJsonObject _value;
  final TavernStateEditResult? stateEdit;
  TavernJsonObject get value => _scriptObject(_value);
}

const Object _scriptAbsent = Object();

class TavernVariableChange {
  TavernVariableChange({required this.kind, required List<Object> pathTokens, Object? value = _scriptAbsent})
    : pathTokens = List.unmodifiable(pathTokens),
      hasValue = !identical(value, _scriptAbsent),
      _value = identical(value, _scriptAbsent) ? null : _scriptCopy(value);
  final TavernVariableChangeKind kind;
  final List<Object> pathTokens;
  final bool hasValue;
  final Object? _value;
  Object? get value => _scriptCopy(_value);
}

class TavernVariableChangeResult {
  TavernVariableChangeResult({
    required this.kind,
    required List<Object> pathTokens,
    required this.existed,
    required this.changed,
  }) : pathTokens = List.unmodifiable(pathTokens);
  final TavernVariableChangeKind kind;
  final List<Object> pathTokens;
  final bool existed;
  final bool changed;
}

class TavernVariableMutation {
  TavernVariableMutation({required this.snapshot, required List<TavernVariableChangeResult> results})
    : results = List.unmodifiable(results);
  final TavernVariableSnapshot snapshot;
  final List<TavernVariableChangeResult> results;
}

class TavernScriptCapabilities {
  TavernScriptCapabilities({
    required this.adapterVersion,
    required Set<String> methods,
    required Set<TavernVariableScope> scopes,
    Set<String> slashCommands = const {},
    Set<String> generationOptions = const {},
    required this.hostAttached,
    this.simulated = false,
  }) : methods = Set.unmodifiable(methods),
       scopes = Set.unmodifiable(scopes),
       slashCommands = Set.unmodifiable(slashCommands),
       generationOptions = Set.unmodifiable(generationOptions);
  final String adapterVersion;
  final Set<String> methods;
  final Set<TavernVariableScope> scopes;
  final Set<String> slashCommands;
  final Set<String> generationOptions;
  final bool hostAttached;
  final bool simulated;
}

class TavernScriptSnapshot {
  TavernScriptSnapshot({
    required this.context,
    required this.engineEpoch,
    required this.lastSeq,
    required this.pathRevision,
    required List<TavernScriptMessage> messages,
    List<TavernVariableSnapshot> variableSnapshots = const [],
    this.presetId,
    this.personaId,
    List<String> memberCharacterIds = const [],
    TavernJsonObject resourceRefs = const {},
    required this.capabilities,
  }) : messages = List.unmodifiable(messages),
       variableSnapshots = List.unmodifiable(variableSnapshots),
       memberCharacterIds = List.unmodifiable(memberCharacterIds),
       _resourceRefs = _scriptObject(resourceRefs);
  final TavernScriptContext context;
  final String engineEpoch;
  final int lastSeq;
  final String pathRevision;
  final List<TavernScriptMessage> messages;
  final List<TavernVariableSnapshot> variableSnapshots;
  final String? presetId;
  final String? personaId;
  final List<String> memberCharacterIds;
  final TavernJsonObject _resourceRefs;
  final TavernScriptCapabilities capabilities;
  TavernJsonObject get resourceRefs => _scriptObject(_resourceRefs);
}

class TavernScriptDelta {
  TavernScriptDelta({
    required this.baseRevision,
    required this.newRevision,
    List<TavernScriptMessage> upsertMessages = const [],
    List<TavernScriptMessageRef> removedRefs = const [],
    Map<int, TavernScriptMessageRef?> indexChanges = const {},
    List<TavernVariableSnapshot> variableSnapshots = const [],
    TavernJsonObject resourceRefs = const {},
  }) : upsertMessages = List.unmodifiable(upsertMessages),
       removedRefs = List.unmodifiable(removedRefs),
       indexChanges = Map.unmodifiable(indexChanges),
       variableSnapshots = List.unmodifiable(variableSnapshots),
       _resourceRefs = _scriptObject(resourceRefs);
  final String baseRevision;
  final String newRevision;
  final List<TavernScriptMessage> upsertMessages;
  final List<TavernScriptMessageRef> removedRefs;
  final Map<int, TavernScriptMessageRef?> indexChanges;
  final List<TavernVariableSnapshot> variableSnapshots;
  final TavernJsonObject _resourceRefs;
  TavernJsonObject get resourceRefs => _scriptObject(_resourceRefs);
}

class TavernScriptSourceSpan {
  const TavernScriptSourceSpan({
    this.sourceId,
    required this.start,
    required this.end,
    required this.line,
    required this.column,
  });
  final String? sourceId;
  final int start;
  final int end;
  final int line;
  final int column;
}

class TavernScriptIssue {
  TavernScriptIssue({
    required this.code,
    required this.message,
    required this.committed,
    TavernJsonObject details = const {},
    this.contextId,
    this.eventId,
    this.generationId,
    this.nodeRef,
    this.sourceSpan,
    this.stage,
    this.cancelled = false,
  }) : _details = _scriptObject(details);
  final String code;
  final String message;
  final bool committed;
  final TavernJsonObject _details;
  final String? contextId;
  final String? eventId;
  final String? generationId;
  final TavernScriptMessageRef? nodeRef;
  final TavernScriptSourceSpan? sourceSpan;
  final String? stage;
  final bool cancelled;
  TavernJsonObject get details => _scriptObject(_details);
}

class TavernScriptException implements Exception {
  TavernScriptException({
    required this.code,
    required this.operation,
    required this.message,
    this.contextId,
    this.nodeId,
    this.generationId,
    this.executionId,
    this.fieldPath,
    this.sourceSpan,
    this.committed = false,
    this.modelFailure,
    List<TavernScriptIssue> issues = const [],
    this.stateEdit,
  }) : issues = List.unmodifiable(issues);
  final TavernScriptErrorCode code;
  final String operation;
  final String message;
  final String? contextId;
  final String? nodeId;
  final String? generationId;
  final String? executionId;
  final String? fieldPath;
  final TavernScriptSourceSpan? sourceSpan;
  final bool committed;
  final TavernFailure? modelFailure;
  final List<TavernScriptIssue> issues;
  final TavernStateEditResult? stateEdit;
  @override
  String toString() => 'TavernScriptException(${code.name}, $operation): $message';
}

class TavernScriptDispatch {
  TavernScriptDispatch({
    required this.kind,
    required this.eventId,
    required this.contextId,
    required this.seq,
    this.chatId,
    this.namespace,
    this.name,
    this.generationId,
    this.nodeRef,
    this.messageId,
    this.swipeId,
    this.pathRevision,
    List<Object?> args = const [],
    this.delta,
  }) : _args = _scriptCopy(args)! as List<Object?>;
  final TavernScriptDispatchKind kind;
  final String eventId;
  final String contextId;
  final String? chatId;
  final String? namespace;
  final String? name;
  final int seq;
  final String? generationId;
  final TavernScriptMessageRef? nodeRef;
  final int? messageId;
  final int? swipeId;
  final String? pathRevision;
  final List<Object?> _args;
  final TavernScriptDelta? delta;
  List<Object?> get args => _scriptCopy(_args)! as List<Object?>;
}

class TavernScriptDispatchAck {
  TavernScriptDispatchAck({
    required this.eventId,
    this.status = TavernScriptAckStatus.completed,
    List<TavernScriptIssue> issues = const [],
    Map<String, String> revisions = const {},
  }) : issues = List.unmodifiable(issues),
       revisions = Map.unmodifiable(revisions);
  final String eventId;
  final TavernScriptAckStatus status;
  final List<TavernScriptIssue> issues;
  final Map<String, String> revisions;
}

class TavernScriptEvent {
  TavernScriptEvent({
    required this.dispatch,
    required this.phase,
    required this.committed,
    List<TavernScriptIssue> issues = const [],
  }) : issues = List.unmodifiable(issues);
  final TavernScriptDispatch dispatch;
  final String phase;
  final bool committed;
  final List<TavernScriptIssue> issues;
  String get contextId => dispatch.contextId;
  String? get chatId => dispatch.chatId;
  String? get name => dispatch.name;
  int get seq => dispatch.seq;
}

abstract interface class TavernScriptCancellation {
  bool get isCancelled;
  Future<void> get whenCancelled;
}

class TavernScriptRefreshRequest {
  TavernScriptRefreshRequest({
    required this.requestId,
    required this.contextId,
    required this.mode,
    required this.pathRevision,
    required List<TavernScriptMessageRef> refs,
    required this.reason,
  }) : refs = List.unmodifiable(refs);
  final String requestId;
  final String contextId;
  final TavernScriptRefresh mode;
  final String pathRevision;
  final List<TavernScriptMessageRef> refs;
  final String reason;
}

/// JSON-only host messages. UI and callback execution are supplied by the App.
class TavernScriptUiRequest {
  TavernScriptUiRequest({
    required this.requestId,
    required this.contextId,
    required this.executionId,
    required this.kind,
    TavernJsonObject fields = const {},
  }) : _fields = _scriptObject(fields);
  final String requestId;
  final String contextId;
  final String executionId;
  final String kind;
  final TavernJsonObject _fields;
  TavernJsonObject get fields => _scriptObject(_fields);
}

class TavernScriptUiResult {
  const TavernScriptUiResult({required this.requestId, required this.status, this.text, this.buttonIndex, this.label});
  final String requestId;
  final String status;
  final String? text;
  final int? buttonIndex;
  final String? label;
}

class TavernScriptCallbackRef {
  const TavernScriptCallbackRef({required this.contextId, required this.instanceId, required this.callbackId});
  final String contextId;
  final String instanceId;
  final String callbackId;
}

class TavernScriptCallbackRequest {
  TavernScriptCallbackRequest({
    required this.requestId,
    required this.ref,
    required this.kind,
    List<Object?> args = const [],
  }) : _args = _scriptCopy(args)! as List<Object?>;
  final String requestId;
  final TavernScriptCallbackRef ref;
  final String kind;
  final List<Object?> _args;
  List<Object?> get args => _scriptCopy(_args)! as List<Object?>;
}

class TavernScriptCallbackResult {
  TavernScriptCallbackResult({
    required this.requestId,
    required this.status,
    this.value,
    List<TavernScriptIssue> issues = const [],
  }) : issues = List.unmodifiable(issues);
  final String requestId;
  final String status;
  final bool? value;
  final List<TavernScriptIssue> issues;
}

class TavernSlashReference {
  const TavernSlashReference({required this.contextId, required this.label, this.setName, this.sourceSpan});
  final String contextId;
  final String label;
  final String? setName;
  final TavernScriptSourceSpan? sourceSpan;
}

class TavernResolvedSlash {
  const TavernResolvedSlash({required this.assetId, required this.version, required this.source});
  final String assetId;
  final String version;
  final String source;
}

abstract interface class TavernScriptHost {
  Future<TavernScriptDispatchAck> dispatch(TavernScriptDispatch request, TavernScriptCancellation cancellation);
  Future<TavernScriptUiResult> interact(TavernScriptUiRequest request, TavernScriptCancellation cancellation);
  Future<TavernScriptCallbackResult> invoke(TavernScriptCallbackRequest request, TavernScriptCancellation cancellation);
  Future<TavernResolvedSlash?> resolveSlash(TavernSlashReference request, TavernScriptCancellation cancellation);
  Future<void> refresh(TavernScriptRefreshRequest request);
}

/// B1's persisted data and awaited lifecycle surface. Capabilities never claim
/// the later background-generation, injection or STscript implementations.
abstract interface class TavernScriptBridge {
  TavernScriptCapabilities get capabilities;
  void attachHost(TavernScriptHost? host);
  Future<TavernScriptContext> openContext(TavernScriptContextSpec spec);
  Future<TavernScriptSnapshot> snapshot(String contextId);
  Future<void> closeContext(String contextId);
  Future<void> activateChat(String contextId);
  Stream<TavernScriptEvent> watchEvents({String? chatId});
  Future<TavernScriptMessagePage> getChatMessages(
    String contextId,
    TavernMessageRange range, {
    TavernScriptRole? role,
    TavernHiddenFilter hidden = TavernHiddenFilter.all,
    bool includeSwipes = false,
  });
  Future<TavernScriptMutation> setChatMessages(
    String contextId,
    List<TavernScriptMessagePatch> patches, {
    TavernScriptWriteOptions options = const TavernScriptWriteOptions(),
  });
  Future<TavernScriptMutation> createChatMessages(
    String contextId,
    List<TavernScriptMessageDraft> messages, {
    int? insertBefore,
    TavernScriptWriteOptions options = const TavernScriptWriteOptions(),
  });
  Future<TavernScriptMutation> deleteChatMessages(
    String contextId,
    List<int> messageIds, {
    TavernScriptWriteOptions options = const TavernScriptWriteOptions(),
  });
  Future<TavernScriptMutation> rotateChatMessages(
    String contextId,
    int begin,
    int middle,
    int end, {
    TavernScriptWriteOptions options = const TavernScriptWriteOptions(),
  });
  Future<TavernScriptMutation> selectSwipe(
    String contextId,
    TavernScriptMessageRef message,
    int swipeId, {
    TavernScriptWriteOptions options = const TavernScriptWriteOptions(),
  });
  Future<TavernVariableSnapshot> getVariables(String contextId, TavernVariableTarget target);
  Future<TavernVariableSnapshot> replaceVariables(
    String contextId,
    TavernVariableTarget target,
    TavernJsonObject value, {
    String? expectedVersion,
  });
  Future<TavernVariableSnapshot> updateVariablesWith(
    String contextId,
    TavernVariableTarget target,
    FutureOr<TavernJsonObject> Function(TavernJsonObject value) updater,
  );
  Future<TavernVariableMutation> mutateVariables(
    String contextId,
    TavernVariableTarget target,
    List<TavernVariableChange> changes, {
    String? expectedVersion,
  });
}

Object? _scriptCopy(Object? value, [Set<Object>? seen]) {
  if (value == null || value is String || value is bool) {
    return value;
  }
  if (value is num && value.isFinite) {
    return value;
  }
  final active = seen ?? HashSet<Object>.identity();
  if (value is Map<Object?, Object?> || value is List<Object?>) {
    if (!active.add(value)) {
      throw TavernScriptException(
        code: TavernScriptErrorCode.invalidJson,
        operation: 'capture',
        message: 'Script JSON must not contain a cycle.',
      );
    }
    try {
      if (value is Map<Object?, Object?>) {
        final result = <String, Object?>{};
        for (final entry in value.entries) {
          if (entry.key is! String) {
            throw TavernScriptException(
              code: TavernScriptErrorCode.invalidJson,
              operation: 'capture',
              message: 'Script JSON object keys must be strings.',
            );
          }
          result[entry.key as String] = _scriptCopy(entry.value, active);
        }
        return result;
      }
      return [for (final item in value as List<Object?>) _scriptCopy(item, active)];
    } finally {
      active.remove(value);
    }
  }
  throw TavernScriptException(
    code: TavernScriptErrorCode.invalidJson,
    operation: 'capture',
    message: 'Expected finite standard JSON.',
  );
}

TavernJsonObject _scriptObject(Object? value) => _scriptCopy(value)! as TavernJsonObject;
