part of 'engine.dart';

extension _ScriptGenerationCommit on _ScriptCoordinator {
  String _generationFieldFingerprint(String chatId, String field) {
    try {
      final chat = engine._store.chat(chatId);
      if (field == 'selection') {
        return _scriptRuntimeFingerprint([
          chat.selectedRootId,
          chat.currentLeafId,
          for (final node in engine._historyTo(chatId, chat.currentLeafId)) node.message.nodeId,
        ]);
      }
      final metadata = engine._chatCodec.metadataForNode(engine._store, chatId);
      final state = chat.currentLeafId == null && engine._store.groupChat(chatId) == null
          ? _emptyChatState(metadata)
          : engine._stateAt(chatId, chat.currentLeafId);
      if (field == 'local') {
        final live = engine._liveVariables[chatId];
        final local = live != null && live.leaf == chat.currentLeafId
            ? live.values
            : state.containsKey('variables')
            ? _map(state['variables'])
            : chat.variables;
        return _scriptRuntimeFingerprint([chat.variables, local]);
      }
      return _scriptRuntimeFingerprint([state.containsKey(field), state[field]]);
    } catch (error) {
      return jsonEncode(['unavailable', error.runtimeType.toString()]);
    }
  }

  String _generationFieldVersion(String chatId, String field) {
    final chat = _generationChatObservations.putIfAbsent(
      chatId,
      () => _ScriptChatObservation(++_nextGenerationObservation),
    );
    final fingerprint = _generationFieldFingerprint(chatId, field);
    final value = chat.fields.putIfAbsent(field, () => _ScriptObservedValue(fingerprint));
    value.observe(fingerprint);
    return '$epoch:preparation:${chat.identity}:$field:${value.revision}';
  }

  void generationStoreCommitted(Set<String> chatIds) {
    // Run at actual outer COMMIT, even when nobody next asks for a snapshot.
    // Only observed targets are read: unrelated scopes cannot invalidate them.
    for (final chatId in chatIds) {
      final observation = _generationChatObservations[chatId];
      if (observation == null) continue;
      for (final entry in observation.fields.entries) {
        entry.value.observe(_generationFieldFingerprint(chatId, entry.key));
      }
      for (final entry in observation.persistent.values) {
        entry.value.observe(_persistentInjectionFingerprint(chatId, entry.source, entry.rawId));
      }
    }
  }

  String _persistentInjectionKey(ChatJsonlMetadataSource source, String rawId) => jsonEncode([source.identity, rawId]);

  String _persistentInjectionFingerprint(String chatId, ChatJsonlMetadataSource source, String rawId) {
    try {
      final chat = engine._store.chat(chatId);
      final metadata = engine._chatCodec.readMetadataSource(chat.metadata, source);
      if (metadata == null) return _scriptRuntimeFingerprint(['missingSource']);
      final raw = metadata['script_injects'];
      return _scriptRuntimeFingerprint(
        raw is Map<String, Object?>
            ? [raw.containsKey(rawId), raw[rawId]]
            : ['container', metadata.containsKey('script_injects'), raw],
      );
    } catch (error) {
      return jsonEncode(['unavailable', error.runtimeType.toString()]);
    }
  }

  String _persistentInjectionToken(_ScriptChatObservation chat, _ScriptPersistentObservation entry) =>
      '$epoch:persistent:${chat.identity}:${entry.identity}:${entry.value.revision}';

  String persistentInjectionVersion(String chatId, ChatJsonlMetadataSource source, String rawId, Object? capturedRaw) {
    final chat = _generationChatObservations.putIfAbsent(
      chatId,
      () => _ScriptChatObservation(++_nextGenerationObservation),
    );
    // The raw value and physical source were captured synchronously together.
    // Re-reading the current leaf here would bind a native branch target to a
    // different source before its original SQL selection has taken place.
    final fingerprint = _scriptRuntimeFingerprint([true, capturedRaw]);
    final entry = chat.persistent.putIfAbsent(
      _persistentInjectionKey(source, rawId),
      () => _ScriptPersistentObservation(
        identity: ++chat.nextPersistentIdentity,
        source: source,
        rawId: rawId,
        fingerprint: fingerprint,
      ),
    );
    entry.value.observe(fingerprint);
    return _persistentInjectionToken(chat, entry);
  }

  String? currentPersistentInjectionVersion(String chatId, ChatJsonlMetadataSource source, String rawId) {
    final chat = _generationChatObservations[chatId];
    final entry = chat?.persistent[_persistentInjectionKey(source, rawId)];
    if (chat == null || entry == null) return null;
    entry.value.observe(_persistentInjectionFingerprint(chatId, entry.source, entry.rawId));
    return _persistentInjectionToken(chat, entry);
  }

  Future<_ScriptGenerationCapture> _captureGeneration(_ScriptGenerationRecord record) async {
    final context = _context(record.context.value.id);
    final request = record.request;
    final chatId = context.value.chatId;
    final chat = chatId == null ? null : engine._store.chat(chatId);
    if (request is! TavernScriptRawRequest && chat == null) {
      throw _scriptError(TavernScriptErrorCode.noContext, 'generate', 'Normal generation requires a chat.');
    }
    final metadata = chat == null ? <String, Object?>{} : engine._chatCodec.metadataForNode(engine._store, chat.id);
    final persistentSource = chat == null ? null : engine._chatCodec.metadataSourceForNode(engine._store, chat.id);
    final candidates = injectionRegistry.capture(
      chatId: chatId,
      metadata: metadata,
      persistentSource: persistentSource,
      request: request.injects,
    );
    final needs = generationNeeds(request, candidates);
    final stateNeeded = needs.history || needs.worldInfo;
    final anchor = stateNeeded ? chat?.currentLeafId : null;
    final group = chat == null ? null : engine._store.groupChat(chat.id);
    final state = !stateNeeded || chat == null
        ? <String, Object?>{}
        : anchor == null && group == null
        ? _emptyChatState(metadata)
        : engine._stateAt(chat.id, anchor);
    final history = !stateNeeded || chat == null ? <StoredNode>[] : engine._historyTo(chat.id, anchor);
    final live = chat == null ? null : engine._liveVariables[chat.id];
    final local = !stateNeeded || chat == null
        ? <String, Object?>{}
        : live != null && live.leaf == anchor
        ? _runtimeCopy(live.values)
        : state.containsKey('variables')
        ? _runtimeCopy(_map(state['variables']))
        : _runtimeCopy(chat.variables);
    final global = _ScriptRuntimeIntentMap(_runtimeCopy(engine._globalVariables));
    final observation = _ScriptGenerationObservation(
      globalRuntime: engine._globalVariables.observation,
      globalCommitted: _variableVersion(
        const TavernVariableTarget(scope: TavernVariableScope.global),
        _fieldVariable(engine._document, 'globalVariables'),
      ),
      selection: stateNeeded && chat != null ? _generationFieldVersion(chat.id, 'selection') : null,
      targets: {
        if (stateNeeded && chat != null)
          for (final target in const ['local', 'timedWorldInfo', 'decoratorState', 'stChatIdHash'])
            target: _generationFieldVersion(chat.id, target),
      },
    );
    final resourcesNeeded = needs.history || needs.card || needs.worldInfo || request is! TavernScriptRawRequest;
    final persona = resourcesNeeded ? engine._personas.resolve(personaId: chat?.personaId) : null;
    final settings = resourcesNeeded
        ? _runtimeCopy(_personaSettings(engine._effectiveSettings(chat, metadata), persona!))
        : <String, Object?>{};
    final contextPresetRaw = _map(settings['preset']);
    final contextRegexPreset = resourcesNeeded
        ? (contextPresetRaw.isEmpty ? ChatPreset.stDefault() : ChatPreset(contextPresetRaw)).settings
        : <String, Object?>{};
    ChatPreset? promptPreset;
    if (request.presetId != null) {
      promptPreset = ChatPreset(engine._requirePreset(request.presetId!).raw);
    } else if (request is! TavernScriptRawRequest) {
      promptPreset = contextPresetRaw.isEmpty ? ChatPreset.stDefault() : ChatPreset(contextPresetRaw);
    }
    final actorId =
        request.speakerCharacterId ?? context.value.characterId ?? (group == null ? chat?.characterId : null);
    if (group != null &&
        request.speakerCharacterId != null &&
        !group.members.any((member) => member.characterId == request.speakerCharacterId)) {
      throw _scriptError(
        TavernScriptErrorCode.noContext,
        'generate',
        'The requested actor is not a member of this group.',
      );
    }
    StoredCharacter? actor;
    if ((needs.card || request.speakerCharacterId != null || request is! TavernScriptRawRequest) && actorId != null) {
      actor = await record.cancellation.wait(engine._trackOperation(engine._record(actorId)));
      if (actor == null) {
        throw _scriptError(TavernScriptErrorCode.notFound, 'generate', 'The requested character is missing.');
      }
    }
    _GroupView? groupView;
    if (group != null && (needs.card || needs.worldInfo)) {
      groupView = await record.cancellation.wait(
        engine._trackOperation(engine._groups.capture(group, checkCancelled: record.cancellation.check)),
      );
    }
    record.cancellation.check();
    _context(context.value.id);
    return _ScriptGenerationCapture(
      generationId: record.id,
      context: context,
      request: request,
      config: record.config,
      at: record.at,
      settings: settings,
      card: actor == null ? {} : _effectiveCard(actor.card.data, settings),
      metadata: _runtimeCopy(metadata),
      state: _runtimeCopy(state),
      local: _ScriptRuntimeIntentMap(local),
      global: global,
      observation: observation,
      injectionCandidates: candidates,
      history: history,
      contextRegexPresetSettings: _runtimeCopy(contextRegexPreset),
      chat: chat,
      anchor: anchor,
      actorId: actorId,
      personaId: persona?.persona?.id,
      groupView: groupView,
      promptPreset: promptPreset,
      capturedChatState: stateNeeded && chat != null,
    );
  }

  void _checkGenerationTargets(_ScriptPreparedGeneration prepared, {bool global = true, bool chat = true}) {
    final capture = prepared.capture;
    _context(capture.context.value.id);
    if (global && capture.global.hasIntents) {
      final committed = _variableVersion(
        const TavernVariableTarget(scope: TavernVariableScope.global),
        _fieldVariable(engine._document, 'globalVariables'),
      );
      if (capture.observation.globalRuntime != engine._globalVariables.observation ||
          capture.observation.globalCommitted != committed) {
        throw _scriptError(
          TavernScriptErrorCode.revisionConflict,
          'generate',
          'Global runtime, pending intent or committed value changed.',
        );
      }
    }
    if (!chat || prepared.chatTargets.isEmpty) return;
    final chatId = capture.chat?.id;
    if (chatId == null || !capture.capturedChatState) {
      throw _scriptError(TavernScriptErrorCode.noContext, 'generate', 'Preparation needs a captured chat state.');
    }
    final active = engine._turns[chatId];
    if (active != null && active.nativePreparationStarted && !active.modelDrained.isCompleted) {
      throw _scriptError(TavernScriptErrorCode.busy, 'generate', 'A native turn still owns the preparation state.');
    }
    if (capture.observation.selection != _generationFieldVersion(chatId, 'selection')) {
      throw _scriptError(TavernScriptErrorCode.revisionConflict, 'generate', 'The captured selection changed.');
    }
    for (final target in prepared.chatTargets) {
      if (!const {'local', 'timedWorldInfo', 'decoratorState', 'stChatIdHash'}.contains(target)) {
        throw _scriptError(
          TavernScriptErrorCode.reservedField,
          'generate',
          'Preparation cannot replace this state field.',
        );
      }
      if (capture.observation.targets[target] != _generationFieldVersion(chatId, target)) {
        throw _scriptError(TavernScriptErrorCode.revisionConflict, 'generate', 'A preparation target changed.');
      }
    }
  }

  Future<T> _generationChatWrite<T>(String chatId, T Function() action) {
    final previous = engine._mutations[chatId] ?? Future<void>.value();
    final released = Completer<void>();
    engine._mutations[chatId] = released.future;
    return () async {
      try {
        await previous;
        return action();
      } finally {
        if (identical(engine._mutations[chatId], released.future)) {
          unawaited(engine._mutations.remove(chatId));
        }
        released.complete();
      }
    }();
  }

  Future<void> _commitGeneration(_ScriptGenerationRecord record, _ScriptPreparedGeneration prepared) async {
    final capture = prepared.capture;
    final receipt = record.receipt;
    if (capture.global.hasIntents) receipt.requiredTargets.add('global');
    if (prepared.chatTargets.isNotEmpty) receipt.requiredTargets.add('chat');
    record.cancellation.check();
    receipt.phase = 'accept';
    _checkGenerationTargets(prepared);
    receipt.claimedInjectionVersions.addAll(injectionRegistry.claim(prepared.injectionUses, generationId: record.id));
    receipt.accepted = true;
    record.status = TavernScriptGenerationStatus.accepted;
    if (capture.global.hasIntents) {
      receipt.phase = 'global';
      record.cancellation.check();
      await engine._settingsDocument((document) async {
        record.cancellation.check();
        receipt.startedTargets.add('global');
        receipt.failedTarget = 'global';
        _checkGenerationTargets(prepared, chat: false);
        final through = engine._globalVariables.revision;
        final runtime = capture.global.applyTo(engine._globalVariables.project(through));
        final value = _copy(runtime);
        final sameJson = _stateJsonEqual(value, document['globalVariables']);
        if (sameJson) {
          engine._adoptGlobals(runtime, through);
          receipt.persistedTargets.add({'targetKind': 'global', 'status': 'adopted'});
        } else {
          final next = _copy(document)..['globalVariables'] = value;
          await engine._commitSettingsDocument(
            next,
            globals: (runtime: runtime, through: through),
            onCommitted: () {
              receipt.persistedTargets.add({'targetKind': 'global', 'status': 'written'});
              receipt.failedTarget = null;
            },
          );
        }
        receipt.failedTarget = null;
      });
    }
    if (prepared.chatTargets.isNotEmpty) {
      receipt.phase = 'chat';
      record.cancellation.check();
      final chatId = capture.chat!.id;
      await _generationChatWrite(chatId, () {
        record.cancellation.check();
        receipt.startedTargets.add('chat');
        receipt.failedTarget = 'chat';
        _checkGenerationTargets(prepared, global: false);
        final chat = engine._store.chat(chatId);
        final group = engine._store.groupChat(chatId);
        final metadata = engine._chatCodec.metadataForNode(engine._store, chatId);
        final state = capture.anchor == null && group == null
            ? _emptyChatState(metadata)
            : engine._stateAt(chatId, capture.anchor);
        final live = engine._liveVariables[chatId];
        final current = live != null && live.leaf == capture.anchor
            ? live.values
            : state.containsKey('variables')
            ? _map(state['variables'])
            : chat.variables;
        final local = capture.local.hasIntents ? capture.local.applyTo(current) : _runtimeCopy(current);
        if (capture.local.hasIntents) state['variables'] = _copy(local);
        for (final entry in prepared.stateUpdates.entries) {
          state[entry.key] = _copy({'value': entry.value})['value'];
        }
        if (prepared.hasHashUpdate) state['stChatIdHash'] = prepared.stChatIdHash;
        final adopted = (leaf: capture.anchor, values: local);
        engine._store.transaction(
          () {
            if (capture.anchor != null) {
              engine._store.writeNodeState(chatId, capture.anchor!, state);
              engine._writeNodeState(chatId, capture.anchor!, state);
            } else if (group != null) {
              engine._store.setGroupInitialState(chatId, state);
            }
            engine._store.updateChat(chatId, variables: _copy(local), metadata: _runtimeMetadata(chat.metadata, state));
          },
          onCommitted: () {
            engine._liveVariables[chatId] = adopted;
            receipt.persistedTargets.add({
              'targetKind': 'chat',
              'chatId': chatId,
              if (capture.anchor != null) 'nodeId': capture.anchor,
              'status': 'written',
            });
            receipt.failedTarget = null;
          },
        );
      });
    }
    if (receipt.persistedTargets.isNotEmpty) resourcesChanged();
  }
}
