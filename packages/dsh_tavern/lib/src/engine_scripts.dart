part of 'engine.dart';

class _ScriptContextState {
  _ScriptContextState(this.value);
  final TavernScriptContext value;
  bool closed = false;
  int seq = 0;
  TavernScriptSnapshot? view;
  Future<void> lifecycle = Future.value();
  Future<void>? refreshing;
  bool refreshAgain = false;
  final pending = <String, _ScriptCancellation>{};
  final callbacks = <_ScriptCancellation>{};
}

class _ScriptChatCapture {
  _ScriptChatCapture(this.context, this.chatId, this.revision, List<StoredNode> path) : path = List.unmodifiable(path);
  final _ScriptContextState context;
  final String chatId;
  final String revision;
  final List<StoredNode> path;
}

class _ScriptLifecycle {
  _ScriptLifecycle({required this.name, this.nodeRef, this.location, List<Object?> args = const []})
    : args = _captureScriptJson(args)! as List<Object?>;
  final String name;
  final TavernScriptMessageRef? nodeRef;
  final ({int? messageId, int? swipeId, String? pathRevision})? location;
  final List<Object?> args;
}

class _ScriptSent {
  _ScriptSent(this.ref, this.messageId, this.pathRevision);
  final TavernScriptMessageRef ref;
  final int messageId;
  final String pathRevision;
  bool published = false;
}

class _ScriptCancellation implements TavernScriptCancellation {
  final _done = Completer<void>();
  String reason = 'cancelled';
  @override
  bool get isCancelled => _done.isCompleted;
  @override
  Future<void> get whenCancelled => _done.future;
  void cancel([String why = 'cancelled']) {
    if (isCancelled) {
      return;
    }
    reason = why;
    _done.complete();
  }
}

class _ScriptCoordinator implements TavernScriptBridge {
  _ScriptCoordinator(this.engine);
  final TavernEngine engine;
  final epoch = 'engine-${_newStateId()}';
  final contexts = <String, _ScriptContextState>{};
  final _closedContexts = <String>{};
  final _events = StreamController<TavernScriptEvent>.broadcast();
  final _deliveries = <Future<void>>{};
  final _nativeDirty = <String>{};
  final _variableVersions = <String, _ScriptVariableVersion>{};
  int _nextVariableIdentity = 0;
  TavernScriptHost? _host;
  int _hostVersion = 0;
  bool _closed = false;

  Future<T> _bridgeOperation<T>(FutureOr<T> Function() action) {
    try {
      return engine
          ._operation(action)
          .then(
            (value) => value,
            onError: (Object error, StackTrace stack) {
              Error.throwWithStackTrace(_scriptFailure(error), stack);
            },
          );
    } catch (error, stack) {
      return Future<T>.error(_scriptFailure(error), stack);
    }
  }

  TavernScriptException _scriptFailure(Object error) {
    if (error is TavernScriptException) {
      return error;
    }
    if (engine._closing || engine._closed || _closed) {
      return _scriptError(TavernScriptErrorCode.closedContext, 'bridge', 'The script engine is closed.');
    }
    if (error is TavernModelException) {
      return TavernScriptException(
        code: error.kind == TavernFailure.busy
            ? TavernScriptErrorCode.busy
            : error.kind == TavernFailure.cancelled
            ? TavernScriptErrorCode.cancelled
            : TavernScriptErrorCode.model,
        operation: 'bridge',
        message: error.detail,
        modelFailure: error.kind,
      );
    }
    if (error is StateError) {
      return _scriptError(TavernScriptErrorCode.notFound, 'bridge', 'The captured target is unavailable.');
    }
    if (error is ArgumentError) {
      return _scriptError(TavernScriptErrorCode.invalidArgument, 'bridge', 'An argument is invalid.');
    }
    if (error is FormatException) {
      return _scriptError(TavernScriptErrorCode.invalidJson, 'bridge', 'Stored JSON is invalid.');
    }
    return _scriptError(TavernScriptErrorCode.storage, 'bridge', 'Bridge storage failed (${error.runtimeType}).');
  }

  @override
  TavernScriptCapabilities get capabilities => TavernScriptCapabilities(
    adapterVersion: 'p2-b1',
    hostAttached: _host != null,
    methods: const {
      'openContext',
      'snapshot',
      'closeContext',
      'activateChat',
      'watchEvents',
      'getChatMessages',
      'setChatMessages',
      'createChatMessages',
      'deleteChatMessages',
      'rotateChatMessages',
      'selectSwipe',
      'getVariables',
      'replaceVariables',
      'updateVariablesWith',
      'mutateVariables',
    },
    scopes: TavernVariableScope.values.toSet(),
  );

  _ScriptContextState _context(String id) {
    if (_closed || engine._closing || engine._closed) {
      throw _scriptError(TavernScriptErrorCode.closedContext, 'context', 'The script engine is closed.', contextId: id);
    }
    final value = contexts[id];
    if (value == null || value.closed) {
      throw _scriptError(
        _closedContexts.contains(id) ? TavernScriptErrorCode.closedContext : TavernScriptErrorCode.noContext,
        'context',
        'The script context is not open.',
        contextId: id,
      );
    }
    return value;
  }

  String _pathRevision(String chatId) => '$epoch:path:${engine._store.treeRevision(chatId)}';

  _ScriptChatCapture _captureChat(String contextId) {
    final context = _context(contextId);
    final chatId = context.value.chatId;
    if (chatId == null) {
      throw _scriptError(TavernScriptErrorCode.noContext, 'chat', 'This context has no chat.', contextId: contextId);
    }
    try {
      final chat = engine._store.chat(chatId);
      return _ScriptChatCapture(context, chatId, _pathRevision(chatId), engine._historyTo(chatId, chat.currentLeafId));
    } on StateError {
      throw _scriptError(
        TavernScriptErrorCode.notFound,
        'chat',
        'The captured chat no longer exists.',
        contextId: contextId,
      );
    }
  }

  void _checkChatCapture(_ScriptChatCapture capture, {String? expectedRevision, bool requireSamePath = false}) {
    _context(capture.context.value.id);
    final chat = engine._store.chat(capture.chatId);
    final current = _ScriptChatCapture(
      capture.context,
      capture.chatId,
      _pathRevision(capture.chatId),
      engine._historyTo(capture.chatId, chat.currentLeafId),
    );
    if ((expectedRevision != null && current.revision != expectedRevision) ||
        (requireSamePath &&
            !_stateJsonEqual(
              [for (final node in capture.path) node.message.nodeId],
              [for (final node in current.path) node.message.nodeId],
            ))) {
      throw _scriptError(
        TavernScriptErrorCode.revisionConflict,
        'write',
        'The captured message path changed.',
        contextId: capture.context.value.id,
      );
    }
  }

  @override
  void attachHost(TavernScriptHost? host) {
    if (_closed || engine._closing || engine._closed) {
      throw _scriptError(TavernScriptErrorCode.closedContext, 'attachHost', 'The script engine is closed.');
    }
    if (identical(_host, host)) {
      return;
    }
    _hostVersion++;
    for (final context in contexts.values) {
      for (final token in context.pending.values) {
        token.cancel('hostUnavailable');
      }
    }
    _host = host;
    resourcesChanged();
  }

  @override
  Future<TavernScriptContext> openContext(TavernScriptContextSpec spec) => _bridgeOperation(() async {
    if (spec.instanceId.isEmpty || spec.chatId == '' || spec.characterId == '' || spec.nodeId == '') {
      throw _scriptError(TavernScriptErrorCode.invalidArgument, 'openContext', 'Context identities must be nonempty.');
    }
    if (spec.nodeId != null && spec.chatId == null) {
      throw _scriptError(TavernScriptErrorCode.noContext, 'openContext', 'A node requires its chat identity.');
    }
    String? characterId = spec.characterId;
    if (spec.chatId case final chatId?) {
      try {
        final chat = engine._store.chat(chatId);
        if (spec.nodeId case final nodeId?) {
          engine._store.node(chatId, nodeId);
        }
        if (characterId == null && engine._store.groupChat(chatId) == null) {
          characterId = chat.characterId;
        }
      } on StateError {
        throw _scriptError(TavernScriptErrorCode.notFound, 'openContext', 'The specified chat or node does not exist.');
      }
    }
    if (characterId != null && await engine._record(characterId) == null) {
      throw _scriptError(TavernScriptErrorCode.notFound, 'openContext', 'The specified character does not exist.');
    }
    final owner = spec.script;
    if (owner != null) {
      await _validateScriptOwner(owner);
    }
    final context = _ScriptContextState(
      TavernScriptContext(
        id: 'context-${_newStateId()}',
        engineEpoch: epoch,
        instanceId: spec.instanceId,
        chatId: spec.chatId,
        characterId: characterId,
        nodeId: spec.nodeId,
        script: owner,
      ),
    );
    contexts[context.value.id] = context;
    try {
      final initial = await _buildView(context);
      _context(context.value.id);
      context.view = initial;
      return context.value;
    } catch (_) {
      contexts.remove(context.value.id);
      context.closed = true;
      rethrow;
    }
  });

  @override
  Future<TavernScriptSnapshot> snapshot(String contextId) => _bridgeOperation(() async {
    final context = _context(contextId);
    // A host can request this while applying a mismatched cache delta. Reading
    // a new snapshot must not await the very cache Ack it is meant to repair.
    final current = await _buildView(context);
    _context(contextId);
    return current!;
  });

  @override
  Future<void> closeContext(String contextId) => _bridgeOperation(() {
    final context = contexts.remove(contextId);
    if (context == null) {
      if (_closedContexts.contains(contextId)) {
        return;
      }
      throw _scriptError(TavernScriptErrorCode.noContext, 'closeContext', 'Unknown context.', contextId: contextId);
    }
    context.closed = true;
    _closedContexts.add(contextId);
    for (final token in context.pending.values) {
      token.cancel();
    }
    for (final token in context.callbacks) {
      token.cancel();
    }
    context.view = null;
  });

  @override
  Future<void> activateChat(String contextId) => _bridgeOperation(() async {
    final capture = _captureChat(contextId);
    await _refreshContext(capture.context);
    _scheduleLifecycle(capture.context, _ScriptLifecycle(name: 'CHAT_CHANGED', args: [capture.chatId]));
  });

  @override
  Stream<TavernScriptEvent> watchEvents({String? chatId}) {
    if (_closed || engine._closing || engine._closed) {
      throw _scriptError(TavernScriptErrorCode.closedContext, 'watchEvents', 'The script engine is closed.');
    }
    return chatId == null ? _events.stream : _events.stream.where((event) => event.chatId == chatId);
  }

  @override
  Future<TavernScriptMessagePage> getChatMessages(
    String contextId,
    TavernMessageRange range, {
    TavernScriptRole? role,
    TavernHiddenFilter hidden = TavernHiddenFilter.all,
    bool includeSwipes = false,
  }) => _bridgeOperation(
    () => _getChatMessages(contextId, range, role: role, hidden: hidden, includeSwipes: includeSwipes),
  );
  @override
  Future<TavernScriptMutation> setChatMessages(
    String contextId,
    List<TavernScriptMessagePatch> patches, {
    TavernScriptWriteOptions options = const TavernScriptWriteOptions(),
  }) => _bridgeOperation(() => _setChatMessages(contextId, List.of(patches), options: options));
  @override
  Future<TavernScriptMutation> createChatMessages(
    String contextId,
    List<TavernScriptMessageDraft> messages, {
    int? insertBefore,
    TavernScriptWriteOptions options = const TavernScriptWriteOptions(),
  }) => _bridgeOperation(
    () => _createChatMessages(contextId, List.of(messages), insertBefore: insertBefore, options: options),
  );
  @override
  Future<TavernScriptMutation> deleteChatMessages(
    String contextId,
    List<int> messageIds, {
    TavernScriptWriteOptions options = const TavernScriptWriteOptions(),
  }) => _bridgeOperation(() => _deleteChatMessages(contextId, List.of(messageIds), options: options));
  @override
  Future<TavernScriptMutation> rotateChatMessages(
    String contextId,
    int begin,
    int middle,
    int end, {
    TavernScriptWriteOptions options = const TavernScriptWriteOptions(),
  }) => _bridgeOperation(() => _rotateChatMessages(contextId, begin, middle, end, options: options));
  @override
  Future<TavernScriptMutation> selectSwipe(
    String contextId,
    TavernScriptMessageRef message,
    int swipeId, {
    TavernScriptWriteOptions options = const TavernScriptWriteOptions(),
  }) => _bridgeOperation(() => _selectSwipe(contextId, message, swipeId, options: options));
  @override
  Future<TavernVariableSnapshot> getVariables(String contextId, TavernVariableTarget target) =>
      _getVariables(contextId, target);
  @override
  Future<TavernVariableSnapshot> replaceVariables(
    String contextId,
    TavernVariableTarget target,
    TavernJsonObject value, {
    String? expectedVersion,
  }) => _replaceVariables(contextId, target, value, expectedVersion: expectedVersion);
  @override
  Future<TavernVariableSnapshot> updateVariablesWith(
    String contextId,
    TavernVariableTarget target,
    FutureOr<TavernJsonObject> Function(TavernJsonObject value) updater,
  ) => _updateVariablesWith(contextId, target, updater);
  @override
  Future<TavernVariableMutation> mutateVariables(
    String contextId,
    TavernVariableTarget target,
    List<TavernVariableChange> changes, {
    String? expectedVersion,
  }) => _mutateVariables(contextId, target, changes, expectedVersion: expectedVersion);

  Future<T> _structureWrite<T>(_ScriptChatCapture capture, FutureOr<T> Function() action) {
    _context(capture.context.value.id);
    return engine._withMutation(capture.chatId, () {
      _context(capture.context.value.id);
      return action();
    });
  }

  Future<T> _dataWrite<T>(_ScriptChatCapture capture, FutureOr<T> Function() action) {
    _context(capture.context.value.id);
    final turn = engine._turns[capture.chatId];
    if (turn != null && !turn.scriptWritesAllowed && !turn.modelDrained.isCompleted) {
      return _structureWrite(capture, action);
    }
    final previous = engine._mutations[capture.chatId] ?? Future<void>.value();
    final released = Completer<void>();
    engine._mutations[capture.chatId] = released.future;
    return () async {
      try {
        await previous;
        _context(capture.context.value.id);
        return await action();
      } finally {
        if (identical(engine._mutations[capture.chatId], released.future)) {
          unawaited(engine._mutations.remove(capture.chatId));
        }
        released.complete();
      }
    }();
  }

  Future<void> drainWrites(String chatId, ModelCancellation cancellation) async {
    cancellation.check();
    while (true) {
      final gate = engine._mutations[chatId];
      if (gate == null) break;
      await cancellation.wait(gate);
      cancellation.check();
    }
  }

  Future<TavernScriptSnapshot?> _buildView(_ScriptContextState context) async {
    if (context.closed) {
      return null;
    }
    while (true) {
      final capture = context.value.chatId == null ? null : _captureChat(context.value.id);
      final variables = <TavernVariableSnapshot>[];
      final shapeIssues = <Map<String, Object?>>[];
      final observedVersions = <String, String>{};
      final targets = <TavernVariableTarget>[
        const TavernVariableTarget(scope: TavernVariableScope.global),
        if (context.value.characterId != null) const TavernVariableTarget(scope: TavernVariableScope.character),
        if (capture != null) const TavernVariableTarget(scope: TavernVariableScope.chat),
        if (capture != null && capture.path.isNotEmpty)
          TavernVariableTarget(
            scope: TavernVariableScope.message,
            messageRef: TavernScriptMessageRef(chatId: capture.chatId, nodeId: capture.path.last.message.nodeId),
          ),
        if (context.value.script != null) const TavernVariableTarget(scope: TavernVariableScope.script),
      ];
      for (final target in targets) {
        final resolved = _resolveTarget(context, target);
        try {
          variables.add(
            await _readVariable(
              resolved,
              onReadVersion: (version) {
                observedVersions[_targetKey(resolved.target)] = version;
              },
            ),
          );
        } on TavernScriptException catch (error) {
          if (error.code != TavernScriptErrorCode.shapeMismatch) {
            rethrow;
          }
          shapeIssues.add({
            'scope': target.scope.name,
            'code': error.code.name,
            'message': error.message,
            'fieldPath': ?error.fieldPath,
            'version': observedVersions[_targetKey(resolved.target)],
          });
        }
      }
      if (context.closed) {
        return null;
      }
      if (capture != null && capture.revision != _pathRevision(capture.chatId)) {
        continue;
      }
      // Every resource read can await a different real storage queue. Before
      // taking lastSeq, synchronously check their commit-observed tokens so an
      // older value can never be returned with a newer cache water mark.
      if (observedVersions.entries.any((entry) => _currentVariableVersion(entry.key) != entry.value)) {
        continue;
      }
      final latest = capture == null ? null : _captureChat(context.value.id);
      if (capture != null &&
          latest != null &&
          (capture.revision != latest.revision ||
              capture.path.length != latest.path.length ||
              capture.path.indexed.any((item) => item.$2.message.nodeId != latest.path[item.$1].message.nodeId))) {
        continue;
      }
      // Streaming body checkpoints intentionally do not advance tree_revision.
      // Project fresh StoredNodes in this final synchronous section, after all
      // file awaits, instead of pairing an old body with newer variable data.
      final messages = latest == null ? <TavernScriptMessage>[] : _projectMessages(latest, includeSwipes: true);
      final chat = capture == null ? null : engine._store.chat(capture.chatId);
      final group = chat == null ? null : engine._store.groupChat(chat.id);
      final preset = engine._resolvePreset(chat).selection.effectivePresetId;
      final memberIds = group == null ? <String>[] : [for (final member in group.members) member.characterId];
      return TavernScriptSnapshot(
        context: context.value,
        engineEpoch: epoch,
        lastSeq: context.seq,
        pathRevision: capture?.revision ?? '$epoch:path:none',
        messages: messages,
        variableSnapshots: variables,
        presetId: preset,
        personaId: chat?.personaId,
        memberCharacterIds: memberIds,
        resourceRefs: {
          'presetId': preset,
          'personaId': chat?.personaId,
          'characterId': context.value.characterId,
          'characterRevision': context.value.characterId == null
              ? null
              : '$epoch:card:${engine._directors._cardRevisions[context.value.characterId] ?? 0}',
          'hostCharacterId': group?.hostCharacterId,
          'memberCharacterIds': memberIds,
          'hostVersion': '$epoch:host:$_hostVersion',
          if (shapeIssues.isNotEmpty) 'variableIssues': shapeIssues,
        },
        capabilities: capabilities,
      );
    }
  }

  Future<void> _refreshContext(_ScriptContextState context) async {
    if (context.closed) {
      return;
    }
    final running = context.refreshing;
    if (running != null) {
      context.refreshAgain = true;
      await running;
      return;
    }
    final completed = Completer<void>();
    context.refreshing = completed.future;
    try {
      do {
        context.refreshAgain = false;
        final before = context.view;
        // A turn may stop waiting for this view when a resource mutation is
        // waiting for that turn to finish. The admitted carrier reads still
        // belong to the engine drain; host acknowledgements below do not.
        final after = await engine._trackOperation(_buildView(context));
        if (context.closed) {
          return;
        }
        if (after == null) {
          return;
        }
        // Public snapshot reads do not move this published-delta baseline.
        context.view = after;
        if (before == null) {
          continue;
        }
        final oldById = {for (final message in before.messages) message.ref.nodeId: message};
        final newById = {for (final message in after.messages) message.ref.nodeId: message};
        final changed = [
          for (final message in after.messages)
            if (!_sameScriptMessage(oldById[message.ref.nodeId], message)) message,
        ];
        final removed = [
          for (final message in before.messages)
            if (!newById.containsKey(message.ref.nodeId)) message.ref,
        ];
        final index = <int, TavernScriptMessageRef?>{};
        for (var i = 0; i < max(before.messages.length, after.messages.length); i++) {
          final old = i < before.messages.length ? before.messages[i].ref : null;
          final next = i < after.messages.length ? after.messages[i].ref : null;
          if (old != next) {
            index[i] = next;
          }
        }
        final oldVariables = {
          for (final value in before.variableSnapshots) _targetKey(value.resolvedTarget): value.version,
        };
        final variableChanges = [
          for (final value in after.variableSnapshots)
            if (oldVariables[_targetKey(value.resolvedTarget)] != value.version) value,
        ];
        final resourcesChanged = !_stateJsonEqual(before.resourceRefs, after.resourceRefs);
        if (changed.isEmpty &&
            removed.isEmpty &&
            index.isEmpty &&
            variableChanges.isEmpty &&
            !resourcesChanged &&
            before.pathRevision == after.pathRevision) {
          continue;
        }
        final delta = TavernScriptDelta(
          baseRevision: before.pathRevision,
          newRevision: after.pathRevision,
          upsertMessages: changed,
          removedRefs: removed,
          indexChanges: index,
          variableSnapshots: variableChanges,
          resourceRefs: resourcesChanged ? after.resourceRefs : const {},
        );
        final request = _dispatch(context, kind: TavernScriptDispatchKind.cache, delta: delta);
        final issues = await _deliver(context, request, committed: true);
        if (issues.isNotEmpty) {
          throw _scriptError(
            TavernScriptErrorCode.hookFailure,
            'cache',
            'The committed cache delivery was not acknowledged.',
            contextId: context.value.id,
            committed: true,
            issues: issues,
          );
        }
      } while (context.refreshAgain && !context.closed);
    } catch (error, stack) {
      final TavernScriptException failure;
      if (error is TavernScriptException && error.committed && error.issues.isNotEmpty) {
        failure = error;
      } else {
        final classified = _scriptFailure(error);
        final request = _dispatch(context, kind: TavernScriptDispatchKind.cache);
        final issue = TavernScriptIssue(
          code: classified.code.name,
          message: 'The committed cache view could not be read.',
          committed: true,
          contextId: context.value.id,
          eventId: request.eventId,
          stage: 'cache',
        );
        _observe(request, 'failed', true, issues: [issue]);
        failure = _scriptError(
          classified.code,
          'cache',
          issue.message,
          contextId: context.value.id,
          committed: true,
          issues: [issue],
        );
      }
      completed.completeError(failure, stack);
      // This completion is also awaited by reentrant refresh callers.
      completed.future.ignore();
      Error.throwWithStackTrace(failure, stack);
    } finally {
      context.refreshing = null;
      if (!completed.isCompleted) {
        completed.complete();
      }
    }
  }

  TavernScriptDispatch _dispatch(
    _ScriptContextState context, {
    required TavernScriptDispatchKind kind,
    String? name,
    TavernScriptMessageRef? ref,
    String? generationId,
    List<Object?> args = const [],
    TavernScriptDelta? delta,
    String? eventId,
    ({int? messageId, int? swipeId, String? pathRevision})? location,
  }) {
    context.seq++;
    final view = context.view;
    final message = view?.messages.where((item) => item.ref == ref).firstOrNull;
    if (view != null) {
      context.view = TavernScriptSnapshot(
        context: view.context,
        engineEpoch: epoch,
        lastSeq: context.seq,
        pathRevision: view.pathRevision,
        messages: view.messages,
        variableSnapshots: view.variableSnapshots,
        presetId: view.presetId,
        personaId: view.personaId,
        memberCharacterIds: view.memberCharacterIds,
        resourceRefs: view.resourceRefs,
        capabilities: capabilities,
      );
    }
    final captured =
        location ?? (messageId: message?.messageId, swipeId: message?.swipeId, pathRevision: view?.pathRevision);
    return TavernScriptDispatch(
      kind: kind,
      eventId: eventId ?? 'event-${_newStateId()}',
      contextId: context.value.id,
      chatId: context.value.chatId,
      seq: context.seq,
      namespace: kind == TavernScriptDispatchKind.lifecycle ? 'tavern' : null,
      name: name,
      generationId: generationId,
      nodeRef: ref,
      messageId: captured.messageId,
      swipeId: captured.swipeId,
      pathRevision: captured.pathRevision,
      args: args,
      delta: delta,
    );
  }

  Future<List<TavernScriptIssue>> _deliver(
    _ScriptContextState context,
    TavernScriptDispatch request, {
    required bool committed,
    ModelCancellation? cancellation,
    _ScriptCancellation? pendingToken,
  }) {
    return _ownDelivery(
      () => _deliverCaptured(
        context,
        request,
        committed: committed,
        cancellation: cancellation,
        pendingToken: pendingToken,
      ),
    );
  }

  Future<T> _ownDelivery<T>(Future<T> Function() action) {
    final completed = Completer<void>();
    _deliveries.add(completed.future);
    // Ownership precedes the App call, including a host which synchronously
    // begins close() from inside dispatch/refresh before returning its Future.
    final result = Future<T>.sync(action);
    void release() {
      _deliveries.remove(completed.future);
      completed.complete();
    }

    unawaited(
      result.then<void>(
        (_) {
          release();
        },
        onError: (Object _, StackTrace _) {
          release();
        },
      ),
    );
    return result;
  }

  Future<List<TavernScriptIssue>> _deliverCaptured(
    _ScriptContextState context,
    TavernScriptDispatch request, {
    required bool committed,
    ModelCancellation? cancellation,
    _ScriptCancellation? pendingToken,
  }) async {
    final host = _host;
    _observe(request, 'published', committed);
    if (host == null && pendingToken?.isCancelled != true && !context.closed && !_closed) {
      context.pending.remove(request.eventId);
      return [];
    }
    final hostVersion = _hostVersion;
    final token = pendingToken ?? _ScriptCancellation();
    context.pending[request.eventId] = token;
    if (context.closed || _closed) {
      token.cancel();
    }
    if (cancellation != null) {
      if (cancellation.isCancelled) {
        token.cancel();
      }
      unawaited(cancellation.whenCancelled.then((_) => token.cancel()));
    }
    List<TavernScriptIssue> failure(String code, String message, {bool cancelled = false}) => [
      TavernScriptIssue(
        code: code,
        message: message,
        committed: committed,
        contextId: context.value.id,
        eventId: request.eventId,
        generationId: request.generationId,
        nodeRef: request.nodeRef,
        stage: request.kind.name,
        cancelled: cancelled,
      ),
    ];
    late final List<TavernScriptIssue> issues;
    try {
      if (token.isCancelled) {
        issues = failure(token.reason, 'Host delivery was cancelled.', cancelled: true);
      } else {
        final ack = await Future.any<TavernScriptDispatchAck?>([
          Future<TavernScriptDispatchAck>.sync(() => host!.dispatch(request, token)),
          token.whenCancelled.then<TavernScriptDispatchAck?>((_) => null),
        ]);
        if (ack == null || context.closed || hostVersion != _hostVersion) {
          issues = failure(token.reason, 'Host delivery ended before acknowledgement.', cancelled: token.isCancelled);
        } else if (ack.eventId != request.eventId) {
          issues = failure('hookFailure', 'Host acknowledged a different event identity.');
        } else {
          issues = [
            ...ack.issues,
            if (ack.status != TavernScriptAckStatus.completed)
              ...failure(
                ack.status == TavernScriptAckStatus.cancelled ? 'cancelled' : 'hookFailure',
                'Host handler did not complete.',
                cancelled: ack.status == TavernScriptAckStatus.cancelled,
              ),
          ];
        }
      }
    } catch (error) {
      issues = failure('hookFailure', 'Host callback failed (${error.runtimeType}).');
    } finally {
      context.pending.remove(request.eventId);
    }
    _observe(request, issues.isEmpty ? 'acknowledged' : 'failed', committed, issues: issues);
    return issues;
  }

  void _observe(
    TavernScriptDispatch request,
    String phase,
    bool committed, {
    List<TavernScriptIssue> issues = const [],
  }) {
    if (!_events.isClosed) {
      _events.add(TavernScriptEvent(dispatch: request, phase: phase, committed: committed, issues: issues));
    }
  }

  Future<List<TavernScriptIssue>> _lifecycle(
    _ScriptContextState context,
    _ScriptLifecycle event, {
    String? generationId,
    ModelCancellation? cancellation,
    bool committed = true,
    bool serialized = false,
  }) {
    final eventId = 'event-${_newStateId()}';
    final message = context.view?.messages.where((item) => item.ref == event.nodeRef).firstOrNull;
    final location =
        event.location ??
        (messageId: message?.messageId, swipeId: message?.swipeId, pathRevision: context.view?.pathRevision);
    final token = _ScriptCancellation();
    context.pending[eventId] = token;
    if (cancellation != null) {
      if (cancellation.isCancelled) {
        token.cancel();
      }
      unawaited(cancellation.whenCancelled.then((_) => token.cancel()));
    }
    Future<List<TavernScriptIssue>> deliver() {
      // Register cancellation ownership immediately, but assign seq at actual
      // publication. Main lifecycle can bypass a pending derived notification
      // without a later publication moving the context sequence backwards.
      final request = _dispatch(
        context,
        kind: TavernScriptDispatchKind.lifecycle,
        name: event.name,
        ref: event.nodeRef,
        generationId: generationId,
        args: event.args,
        eventId: eventId,
        location: location,
      );
      return _deliver(context, request, committed: committed, pendingToken: token);
    }

    // A new generation must not queue behind an ENDED handler that is itself
    // awaiting that generation. Only detached mutation notifications share
    // the ordinary per-context notification tail.
    if (!serialized) {
      return deliver();
    }
    final result = context.lifecycle.then((_) {
      return deliver();
    });
    context.lifecycle = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  void _scheduleLifecycle(
    _ScriptContextState context,
    _ScriptLifecycle event, {
    String? generationId,
    bool mainLifecycle = false,
    ModelCancellation? cancellation,
  }) {
    // The storage setter must not await a lifecycle queued behind its caller.
    // Failures are observed by _deliver; cancellation/detach releases its wait.
    unawaited(
      _lifecycle(
        context,
        event,
        generationId: generationId,
        serialized: !mainLifecycle,
        cancellation: cancellation,
      ).then<void>(
        (_) {},
        onError: (Object error, StackTrace _) {
          final request = _dispatch(
            context,
            kind: TavernScriptDispatchKind.lifecycle,
            name: event.name,
            ref: event.nodeRef,
            generationId: generationId,
          );
          _observe(
            request,
            'failed',
            true,
            issues: [
              TavernScriptIssue(
                code: 'hookFailure',
                message: 'Lifecycle scheduling failed (${error.runtimeType}).',
                committed: true,
                contextId: context.value.id,
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _publishMutation(
    _ScriptContextState origin,
    TavernScriptMutation mutation, {
    List<_ScriptLifecycle> events = const [],
  }) async {
    final related = contexts.values.where((item) => !item.closed && item.value.chatId == origin.value.chatId).toList();
    for (final context in related) {
      await _refreshContext(context);
    }
    for (final context in related) {
      for (final event in events) {
        _scheduleLifecycle(context, event);
      }
    }
    if (mutation.refresh == TavernScriptRefresh.none || _host == null || origin.closed) {
      return;
    }
    _scheduleRefresh(origin, mutation);
  }

  void _scheduleRefresh(_ScriptContextState origin, TavernScriptMutation mutation) {
    final host = _host;
    if (host == null || origin.closed) {
      return;
    }
    final hostVersion = _hostVersion;
    final token = _ScriptCancellation();
    final request = _dispatch(origin, kind: TavernScriptDispatchKind.cache);
    origin.pending[request.eventId] = token;
    unawaited(
      _ownDelivery(() async {
        try {
          final completed = await Future.any<bool>([
            Future<void>.sync(
              () => host.refresh(
                TavernScriptRefreshRequest(
                  requestId: request.eventId,
                  contextId: origin.value.id,
                  mode: mutation.refresh,
                  pathRevision: mutation.pathRevision,
                  refs: [...mutation.affectedRefs, ...mutation.removedRefs],
                  reason: 'messages',
                ),
              ),
            ).then((_) => true),
            token.whenCancelled.then((_) => false),
          ]);
          if (!completed || hostVersion != _hostVersion || !identical(host, _host) || origin.closed) {
            _observe(
              request,
              'failed',
              true,
              issues: [
                TavernScriptIssue(
                  code: token.reason,
                  message: 'Canvas refresh was cancelled.',
                  committed: true,
                  cancelled: true,
                  contextId: origin.value.id,
                  eventId: request.eventId,
                  stage: 'refresh',
                ),
              ],
            );
          } else if (mutation.refresh == TavernScriptRefresh.all && !origin.closed) {
            _scheduleLifecycle(origin, _ScriptLifecycle(name: 'CHAT_CHANGED', args: [origin.value.chatId]));
          }
        } catch (error) {
          _observe(
            request,
            'failed',
            true,
            issues: [
              TavernScriptIssue(
                code: 'hookFailure',
                message: 'Canvas refresh failed (${error.runtimeType}).',
                committed: true,
                contextId: origin.value.id,
                eventId: request.eventId,
                stage: 'refresh',
              ),
            ],
          );
        } finally {
          origin.pending.remove(request.eventId);
        }
      }),
    );
  }

  void nativeChanged(String chatId) {
    if (_closed || !contexts.values.any((context) => !context.closed && context.value.chatId == chatId)) {
      return;
    }
    if (!_nativeDirty.add(chatId)) {
      return;
    }
    unawaited(
      Future<void>(() async {
        _nativeDirty.remove(chatId);
        for (final context in contexts.values.where((item) => !item.closed && item.value.chatId == chatId).toList()) {
          try {
            // Streaming checkpoints change only the draft body, not the durable
            // tree revision. They already have native token events; do not copy
            // the entire stored path into every iframe for each checkpoint.
            if (context.view?.pathRevision != _pathRevision(chatId)) {
              await _refreshContext(context);
            }
          } catch (_) {
            /* _deliver publishes structured issues. */
          }
        }
      }),
    );
  }

  void resourcesChanged() {
    if (_closed || contexts.isEmpty) {
      return;
    }
    const key = '\u0000resources';
    if (!_nativeDirty.add(key)) {
      return;
    }
    unawaited(
      Future<void>(() async {
        _nativeDirty.remove(key);
        for (final context in contexts.values.toList()) {
          if (context.closed) {
            continue;
          }
          try {
            await _refreshContext(context);
          } catch (_) {
            /* Cache errors are observable separately. */
          }
        }
      }),
    );
  }

  void cancelChat(String chatId) {
    // Ownership survives removal of _turns, including queued actor ENDED
    // notifications while the outer group still owns the chat.
    for (final context in contexts.values) {
      if (context.value.chatId != chatId) {
        continue;
      }
      for (final token in context.pending.values) {
        token.cancel();
      }
    }
  }

  Future<void> groupSettled(String chatId, ModelCancellation cancellation) async {
    cancellation.check();
    for (final context in contexts.values.where((item) => !item.closed && item.value.chatId == chatId).toList()) {
      cancellation.check();
      try {
        await cancellation.wait(_refreshContext(context));
      } catch (_) {
        // Ordinary cache failures remain visible in script events. An outer
        // group cancellation must release the group-owned logical barrier.
        cancellation.check();
      }
      cancellation.check();
    }
  }

  Future<void> nativeMutation(
    String chatId,
    String name, {
    String? nodeId,
    String? generationId,
    ModelCancellation? cancellation,
    List<Object?> args = const [],
    ({int? messageId, int? swipeId, String? pathRevision})? location,
  }) async {
    for (final context in contexts.values.where((item) => !item.closed && item.value.chatId == chatId).toList()) {
      try {
        await _refreshContext(context);
      } catch (_) {
        /* Cache issues remain observable. */
      }
      if (!context.closed) {
        _scheduleLifecycle(
          context,
          _ScriptLifecycle(
            name: name,
            nodeRef: nodeId == null ? null : TavernScriptMessageRef(chatId: chatId, nodeId: nodeId),
            location: location,
            args: args,
          ),
          generationId: generationId,
          mainLifecycle: name == 'MESSAGE_SENT',
          cancellation: cancellation,
        );
      }
    }
  }

  _ScriptSent? captureSent(String chatId, String nodeId) {
    if (!contexts.values.any((context) => !context.closed && context.value.chatId == chatId)) {
      return null;
    }
    final path = engine._historyTo(chatId, engine._store.chat(chatId).currentLeafId);
    return _ScriptSent(
      TavernScriptMessageRef(chatId: chatId, nodeId: nodeId),
      path.indexWhere((node) => node.message.nodeId == nodeId),
      _pathRevision(chatId),
    );
  }

  void publishSent(_ScriptSent? sent, {String? generationId, ModelCancellation? cancellation}) {
    if (sent == null || sent.published) {
      return;
    }
    sent.published = true;
    // User SQL has committed, but no handler runs while the request is still
    // being assembled. A failed preparation still publishes this commit fact
    // once, with its captured floor even if the old rollback removed the node.
    unawaited(
      nativeMutation(
        sent.ref.chatId,
        'MESSAGE_SENT',
        nodeId: sent.ref.nodeId,
        generationId: generationId,
        cancellation: cancellation,
        location: (messageId: sent.messageId, swipeId: null, pathRevision: sent.pathRevision),
      ),
    );
  }

  Future<void> beforeTurn(_Turn turn) async {
    turn.scriptWritesAllowed = true;
    try {
      final active = contexts.values.where((item) => !item.closed && item.value.chatId == turn.chat.id).toList();
      for (final context in active) {
        turn.cancellation.check();
        await turn.cancellation.wait(_refreshContext(context));
        turn.cancellation.check();
      }
      for (final name in const ['GENERATION_STARTED', 'GENERATION_AFTER_COMMANDS']) {
        for (final context in active) {
          if (context.closed) {
            continue;
          }
          turn.hookIssues.addAll(
            await _lifecycle(
              context,
              _ScriptLifecycle(name: name),
              generationId: turn.generationId,
              cancellation: turn.cancellation,
              committed: false,
            ),
          );
          turn.cancellation.check();
        }
      }
      await drainWrites(turn.chat.id, turn.cancellation);
    } catch (error) {
      if (error is TavernScriptException) {
        turn.hookIssues.addAll(error.issues);
      }
      turn.cancellation.check();
      rethrow;
    } finally {
      turn.scriptWritesAllowed = false;
    }
  }

  Future<void> afterMessage(_Turn turn) async {
    final reply = turn.lastCommitted;
    if (reply == null || turn.kind == _TurnKind.impersonate) {
      return;
    }
    try {
      for (final context
          in contexts.values.where((item) => !item.closed && item.value.chatId == turn.chat.id).toList()) {
        try {
          turn.cancellation.check();
          await turn.cancellation.wait(_refreshContext(context));
          turn.cancellation.check();
          if (!context.closed) {
            turn.hookIssues.addAll(
              await _lifecycle(
                context,
                _ScriptLifecycle(
                  name: 'MESSAGE_RECEIVED',
                  nodeRef: TavernScriptMessageRef(chatId: turn.chat.id, nodeId: reply.nodeId),
                ),
                generationId: turn.generationId,
                cancellation: turn.cancellation,
              ),
            );
          }
        } catch (error) {
          final cancelled = turn.cancellation.isCancelled;
          turn.hookIssues.add(
            TavernScriptIssue(
              code: cancelled ? 'cancelled' : 'hookFailure',
              committed: true,
              message: 'Committed message hook failed (${error.runtimeType}).',
              contextId: context.value.id,
              generationId: turn.generationId,
              nodeRef: TavernScriptMessageRef(chatId: turn.chat.id, nodeId: reply.nodeId),
              cancelled: cancelled,
            ),
          );
          if (cancelled) {
            break;
          }
        }
      }
      // Direct handler writes are flushed by the Ack. The native short queue
      // also drains before the next actor reads state. Derived lifecycle is not
      // part of this barrier and may still be queued in the App.
      if (!turn.cancellation.isCancelled) {
        await drainWrites(turn.chat.id, turn.cancellation);
      }
      final current = engine._store.node(turn.chat.id, reply.nodeId);
      turn.lastCommitted = current.message;
      turn.state = engine._stateAt(turn.chat.id, reply.nodeId);
      turn.variables = _runtimeCopy(_map(turn.state['variables']));
    } catch (error) {
      turn.hookIssues.add(
        TavernScriptIssue(
          code: turn.cancellation.isCancelled ? 'cancelled' : 'hookFailure',
          message: 'Post-commit anchor changed (${error.runtimeType}).',
          committed: true,
          generationId: turn.generationId,
          cancelled: turn.cancellation.isCancelled,
        ),
      );
    }
  }

  void ended(_Turn turn) {
    final terminal = turn.terminalEvent;
    final success = terminal is TavernTurnDone ? terminal : null;
    final failure = terminal is TavernTurnFailed ? terminal : null;
    final cancelled = turn.cancellation.isCancelled || failure?.kind == TavernFailure.cancelled;
    final message = success?.message ?? failure?.partial;
    final ref = message == null || turn.kind == _TurnKind.impersonate
        ? null
        : TavernScriptMessageRef(chatId: turn.chat.id, nodeId: message.nodeId);
    final payload = <String, Object?>{
      'status': success != null
          ? 'completed'
          : failure != null
          ? (failure.kind == TavernFailure.cancelled ? 'cancelled' : 'failed')
          : turn.inspection.status.name,
      'generationType': turn.generationType,
      'cancelled': cancelled,
      // This flag means successful model settlement, not that a failed turn
      // could not retain a partial or an earlier user/secret-state commit.
      'committed': turn.modelCommitted,
      'finishReason': success?.finishReason ?? turn.finishReason,
      'modelFailure': failure?.kind.name,
      'replyRef': success != null && ref != null ? {'chatId': ref.chatId, 'nodeId': ref.nodeId} : null,
      'partialRef': failure?.partial != null && ref != null ? {'chatId': ref.chatId, 'nodeId': ref.nodeId} : null,
      'hookIssues': [
        for (final issue in success?.hookIssues ?? failure?.hookIssues ?? turn.hookIssues) _scriptIssueJson(issue),
      ],
    };
    for (final context in contexts.values.where((item) => !item.closed && item.value.chatId == turn.chat.id).toList()) {
      if (cancelled) {
        _scheduleLifecycle(
          context,
          _ScriptLifecycle(name: 'GENERATION_STOPPED', nodeRef: ref, args: [payload]),
          generationId: turn.generationId,
          mainLifecycle: true,
        );
      }
      _scheduleLifecycle(
        context,
        _ScriptLifecycle(name: 'GENERATION_ENDED', nodeRef: ref, args: [payload]),
        generationId: turn.generationId,
        mainLifecycle: true,
      );
    }
  }

  void close() {
    _closed = true;
    for (final context in contexts.values) {
      context.closed = true;
      for (final token in context.pending.values) {
        token.cancel('hostUnavailable');
      }
      for (final token in context.callbacks) {
        token.cancel();
      }
    }
    _host = null;
    // Cancellation resolves our races even when a host ignores its token.
    // Keep the observation stream open until those outcomes are published;
    // a paused observer must still never hold engine.close().
    unawaited(() async {
      await Future.wait<void>([..._deliveries, for (final context in contexts.values) context.lifecycle]);
      unawaited(_events.close());
    }());
  }
}

TavernScriptException _scriptError(
  TavernScriptErrorCode code,
  String operation,
  String message, {
  String? contextId,
  String? nodeId,
  String? fieldPath,
  bool committed = false,
  List<TavernScriptIssue> issues = const [],
  TavernStateEditResult? stateEdit,
}) => TavernScriptException(
  code: code,
  operation: operation,
  message: message,
  contextId: contextId,
  nodeId: nodeId,
  fieldPath: fieldPath,
  committed: committed,
  issues: issues,
  stateEdit: stateEdit,
);

Map<String, Object?> _scriptIssueJson(TavernScriptIssue issue) => {
  'code': issue.code,
  'message': issue.message,
  'committed': issue.committed,
  'contextId': ?issue.contextId,
  'eventId': ?issue.eventId,
  'generationId': ?issue.generationId,
  if (issue.nodeRef case final ref?) 'nodeRef': {'chatId': ref.chatId, 'nodeId': ref.nodeId},
  if (issue.sourceSpan case final span?)
    'sourceSpan': {
      'sourceId': ?span.sourceId,
      'start': span.start,
      'end': span.end,
      'line': span.line,
      'column': span.column,
    },
  'stage': ?issue.stage,
  'cancelled': issue.cancelled,
  'details': issue.details,
};

Object? _captureScriptJson(Object? value, [Set<Object>? visited]) {
  if (value == null || value is String || value is bool) {
    return value;
  }
  if (value is num && value.isFinite) {
    return value;
  }
  final seen = visited ?? HashSet<Object>.identity();
  if (value is Map<Object?, Object?> || value is List<Object?>) {
    if (!seen.add(value)) {
      throw _scriptError(TavernScriptErrorCode.invalidJson, 'capture', 'JSON contains a cycle.');
    }
    try {
      if (value is Map<Object?, Object?>) {
        final result = <String, Object?>{};
        for (final entry in value.entries) {
          if (entry.key is! String) {
            throw _scriptError(TavernScriptErrorCode.invalidJson, 'capture', 'JSON keys must be strings.');
          }
          result[entry.key as String] = _captureScriptJson(entry.value, seen);
        }
        return result;
      }
      return [for (final item in value as List<Object?>) _captureScriptJson(item, seen)];
    } finally {
      seen.remove(value);
    }
  }
  throw _scriptError(TavernScriptErrorCode.invalidJson, 'capture', 'Expected finite standard JSON.');
}

Map<String, Object?> _captureScriptObject(Object? value) {
  final result = _captureScriptJson(value);
  if (result is! Map<String, Object?>) {
    throw _scriptError(TavernScriptErrorCode.shapeMismatch, 'variables', 'Expected a JSON object.');
  }
  return result;
}

bool _sameScriptMessage(TavernScriptMessage? a, TavernScriptMessage b) =>
    a != null &&
    a.messageId == b.messageId &&
    a.ref == b.ref &&
    a.name == b.name &&
    a.role == b.role &&
    a.nativeRole == b.nativeRole &&
    a.message == b.message &&
    a.hidden == b.hidden &&
    a.speakerCharacterId == b.speakerCharacterId &&
    a.swipeId == b.swipeId &&
    a.hasData == b.hasData &&
    _stateJsonEqual(a.rawData, b.rawData) &&
    _stateJsonEqual(a.extra, b.extra) &&
    a.swipes.length == b.swipes.length &&
    List.generate(a.swipes.length, (i) => i).every((i) {
      final x = a.swipes[i], y = b.swipes[i];
      return x.ref == y.ref &&
          x.text == y.text &&
          x.hasData == y.hasData &&
          _stateJsonEqual(x.rawData, y.rawData) &&
          _stateJsonEqual(x.info, y.info);
    });
