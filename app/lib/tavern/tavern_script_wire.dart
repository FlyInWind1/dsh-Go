// What a card's script asks of the engine (P2 B1, Tavern.scripts) over its
// page's channel, and what it is told back: one JSON request
//   {"id": …, "method": "getVariables", "params": {…}}
// and one JSON reply
//   {"id": …, "ok": true, "result": …} or {"id": …, "ok": false, "error": {…}}.
//
// The rules the engine's App notes set for a wire (API-INTEGRATION, B1 §2):
// versions and revisions go out and come back as the opaque strings they
// are; a member present as null stays present; a message whose data is not
// an object reads data: null with its raw value beside it; every refusal —
// thrown at the call or later — comes back as a structured error, never as
// a channel failure. This first part carries reading (capabilities,
// contexts, messages) and variables; message writes need the host side and
// come with it. updateVariablesWith is not a wire method: a script's
// function stays in the page (read, call it once, replace with the version
// it read).

import 'package:dsh_tavern/dsh_tavern.dart';

class TavernScriptWire {
  TavernScriptWire(this.bridge);

  final TavernScriptBridge bridge;

  /// The reply to [request], always JSON; never throws.
  Future<Map<String, Object?>> handle(Object? request) async {
    final id = request is Map ? request['id'] : null;
    try {
      if (request is! Map) throw _bad('request', 'A request is a JSON object.');
      final method = request['method'];
      if (method is! String) throw _bad('request', 'A request names its method.');
      final params = request['params'] ?? const <String, Object?>{};
      if (params is! Map) throw _bad(method, 'params is a JSON object.');
      final p = _Params(method, params);
      return {'id': id, 'ok': true, 'result': await _call(method, p)};
    } on TavernScriptException catch (e) {
      return {'id': id, 'ok': false, 'error': _error(e)};
    } on Object catch (e) {
      // Not the engine's own refusal: said as such, not dressed as one.
      return {
        'id': id,
        'ok': false,
        'error': {'code': 'internal', 'message': '$e', 'committed': false},
      };
    }
  }

  Future<Object?> _call(String method, _Params p) async {
    switch (method) {
      case 'capabilities':
        final c = bridge.capabilities;
        return {
          'adapterVersion': c.adapterVersion,
          'methods': [...c.methods]..sort(),
          'scopes': [for (final s in c.scopes) s.name]..sort(),
          'hostAttached': c.hostAttached,
          'simulated': c.simulated,
        };
      case 'openContext':
        final context = await bridge.openContext(
          TavernScriptContextSpec(
            instanceId: p.string('instanceId'),
            chatId: p.stringOrNull('chatId'),
            characterId: p.stringOrNull('characterId'),
            nodeId: p.stringOrNull('nodeId'),
            script: p.has('script') ? _owner(p.object('script'), p.method) : null,
          ),
        );
        return _context(context);
      case 'closeContext':
        await bridge.closeContext(p.string('contextId'));
        return null;
      case 'getChatMessages':
        final range = p.has('range') ? p.object('range') : const <String, Object?>{};
        final page = await bridge.getChatMessages(
          p.string('contextId'),
          TavernMessageRange(first: _intOrNull(range, 'first', p.method), last: _intOrNull(range, 'last', p.method)),
          role: p.has('role') ? _enum(TavernScriptRole.values, p.string('role'), 'role', p.method) : null,
          hidden: p.has('hidden')
              ? _enum(TavernHiddenFilter.values, p.string('hidden'), 'hidden', p.method)
              : TavernHiddenFilter.all,
          includeSwipes: p.boolOr('includeSwipes', false),
        );
        return {
          'pathRevision': page.pathRevision,
          'totalPathLength': page.totalPathLength,
          'messages': [for (final m in page.messages) _message(m)],
        };
      case 'getVariables':
        return _snapshot(await bridge.getVariables(p.string('contextId'), _target(p.object('target'), p.method)));
      case 'replaceVariables':
        return _snapshot(
          await bridge.replaceVariables(
            p.string('contextId'),
            _target(p.object('target'), p.method),
            p.object('value'),
            expectedVersion: p.stringOrNull('expectedVersion'),
          ),
        );
      case 'mutateVariables':
        final mutation = await bridge.mutateVariables(p.string('contextId'), _target(p.object('target'), p.method), [
          for (final (i, c) in p.list('changes').indexed) _change(c, i, p.method),
        ], expectedVersion: p.stringOrNull('expectedVersion'));
        return {
          'snapshot': _snapshot(mutation.snapshot),
          'results': [
            for (final r in mutation.results)
              {'kind': r.kind.name, 'path': r.pathTokens, 'existed': r.existed, 'changed': r.changed},
          ],
        };
    }
    throw TavernScriptException(
      code: TavernScriptErrorCode.unsupportedCapability,
      operation: method,
      message: 'The page channel does not carry $method.',
    );
  }
}

TavernScriptException _bad(String operation, String message, {String? fieldPath}) => TavernScriptException(
  code: TavernScriptErrorCode.invalidArgument,
  operation: operation,
  message: message,
  fieldPath: fieldPath,
);

Map<String, Object?> _error(TavernScriptException e) => {
  'code': e.code.name,
  'operation': e.operation,
  'message': e.message,
  'committed': e.committed,
  'contextId': e.contextId,
  'nodeId': e.nodeId,
  'fieldPath': e.fieldPath,
};

/// A request's params, read strictly: the wrong type is the caller's error,
/// named by its field.
class _Params {
  _Params(this.method, this._map);

  final String method;
  final Map<Object?, Object?> _map;

  bool has(String key) => _map.containsKey(key) && _map[key] != null;

  Object? _need(String key) {
    if (!_map.containsKey(key)) throw _bad(method, '$key is missing.', fieldPath: key);
    return _map[key];
  }

  String string(String key) => switch (_need(key)) {
    final String s => s,
    _ => throw _bad(method, '$key is a string.', fieldPath: key),
  };

  String? stringOrNull(String key) => switch (_map[key]) {
    null => null,
    final String s => s,
    _ => throw _bad(method, '$key is a string.', fieldPath: key),
  };

  bool boolOr(String key, bool otherwise) => switch (_map[key]) {
    null => otherwise,
    final bool b => b,
    _ => throw _bad(method, '$key is true or false.', fieldPath: key),
  };

  Map<String, Object?> object(String key) => _asObject(_need(key), key, method);

  List<Object?> list(String key) => switch (_need(key)) {
    final List<Object?> l => l,
    _ => throw _bad(method, '$key is a list.', fieldPath: key),
  };
}

Map<String, Object?> _asObject(Object? value, String field, String method) {
  if (value is! Map) throw _bad(method, '$field is a JSON object.', fieldPath: field);
  final out = <String, Object?>{};
  for (final MapEntry(:key, :value) in value.entries) {
    if (key is! String) throw _bad(method, '$field has a key that is not a string.', fieldPath: field);
    out[key] = value;
  }
  return out;
}

int? _intOrNull(Map<String, Object?> map, String key, String method) => switch (map[key]) {
  null => null,
  final int n => n,
  _ => throw _bad(method, '$key is a whole number.', fieldPath: key),
};

T _enum<T extends Enum>(List<T> values, String name, String field, String method) {
  for (final v in values) {
    if (v.name == name) return v;
  }
  throw _bad(method, '$field is one of ${values.map((v) => v.name).join(', ')}.', fieldPath: field);
}

TavernScriptOwner _owner(Map<String, Object?> json, String method) {
  final p = _Params(method, json);
  return TavernScriptOwner(
    kind: _enum(TavernScriptOwnerKind.values, p.string('kind'), 'script.kind', method),
    scriptId: p.string('scriptId'),
    assetId: p.stringOrNull('assetId'),
  );
}

TavernScriptMessageRef _ref(Map<String, Object?> json, String method) {
  final p = _Params(method, json);
  return TavernScriptMessageRef(chatId: p.string('chatId'), nodeId: p.string('nodeId'));
}

TavernVariableTarget _target(Map<String, Object?> json, String method) {
  final p = _Params(method, json);
  return TavernVariableTarget(
    scope: _enum(TavernVariableScope.values, p.string('scope'), 'target.scope', method),
    characterId: p.stringOrNull('characterId'),
    chatId: p.stringOrNull('chatId'),
    messageId: _intOrNull(json, 'messageId', method),
    messageRef: p.has('messageRef') ? _ref(p.object('messageRef'), method) : null,
    scriptOwner: p.has('scriptOwner') ? _owner(p.object('scriptOwner'), method) : null,
  );
}

/// One change; `value` present (even as null) is a value, absent is none.
TavernVariableChange _change(Object? json, int at, String method) {
  final change = _asObject(json, 'changes[$at]', method);
  final p = _Params(method, change);
  final path = <Object>[
    for (final token in p.list('path'))
      switch (token) {
        final String s => s,
        final int n when n >= 0 => n,
        _ => throw _bad(method, 'A path step is a key or an index from 0.', fieldPath: 'changes[$at].path'),
      },
  ];
  final kind = _enum(TavernVariableChangeKind.values, p.string('kind'), 'changes[$at].kind', method);
  return change.containsKey('value')
      ? TavernVariableChange(kind: kind, pathTokens: path, value: change['value'])
      : TavernVariableChange(kind: kind, pathTokens: path);
}

Map<String, Object?>? _ownerJson(TavernScriptOwner? o) =>
    o == null ? null : {'kind': o.kind.name, 'scriptId': o.scriptId, 'assetId': o.assetId};

Map<String, Object?> _refJson(TavernScriptMessageRef r) => {'chatId': r.chatId, 'nodeId': r.nodeId};

Map<String, Object?> _context(TavernScriptContext c) => {
  'id': c.id,
  'engineEpoch': c.engineEpoch,
  'instanceId': c.instanceId,
  'chatId': c.chatId,
  'characterId': c.characterId,
  'nodeId': c.nodeId,
  'script': _ownerJson(c.script),
};

Map<String, Object?> _targetJson(TavernVariableTarget t) => {
  'scope': t.scope.name,
  'characterId': t.characterId,
  'chatId': t.chatId,
  'messageId': t.messageId,
  'messageRef': t.messageRef == null ? null : _refJson(t.messageRef!),
  'scriptOwner': _ownerJson(t.scriptOwner),
};

Map<String, Object?> _snapshot(TavernVariableSnapshot s) => {
  'target': _targetJson(s.resolvedTarget),
  'version': s.version,
  'value': s.value,
};

Map<String, Object?>? _issue(TavernScriptShapeIssue? i) =>
    i == null ? null : {'fieldPath': i.fieldPath, 'actualKind': i.actualKind, 'message': i.message};

Map<String, Object?> _message(TavernScriptMessage m) => {
  'messageId': m.messageId,
  'ref': _refJson(m.ref),
  'name': m.name,
  'role': m.role.name,
  'nativeRole': m.nativeRole.name,
  'message': m.message,
  'hidden': m.hidden,
  'speakerCharacterId': m.speakerCharacterId,
  'hasData': m.hasData,
  'data': m.data,
  'rawData': m.rawData,
  'dataIssue': _issue(m.dataIssue),
  'extra': m.extra,
  'swipeId': m.swipeId,
  'swipes': [
    for (final s in m.swipes)
      {
        'ref': _refJson(s.ref),
        'swipeId': s.swipeId,
        'text': s.text,
        'hasData': s.hasData,
        'data': s.data,
        'rawData': s.rawData,
        'dataIssue': _issue(s.dataIssue),
        'info': s.info,
      },
  ],
};
