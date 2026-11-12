// A canvas page's calls into the engine: what a card's script asks with
// `await dsh.call('getVariables', {target: {scope: 'chat'}})`. Each goes
// through [TavernScriptWire] within this chat's own script context, which is
// opened on the first call that needs one and closed with the page; a call
// may still name another context it opened itself.

import 'package:dsh_tavern/dsh_tavern.dart';

import 'tavern_script_wire.dart';

class TavernCanvasCalls {
  TavernCanvasCalls(this._bridge, {required this.chatId, required this.characterId, this.instanceId = 'canvas'});

  final TavernScriptBridge _bridge;
  final String chatId;

  /// The chat's character as it is when the context opens; null for a group
  /// (the engine does not guess a member for it).
  final String? Function() characterId;

  /// Who the page is to the engine: its running instance, not a saved key.
  final String instanceId;

  late final _wire = TavernScriptWire(_bridge);
  Future<String>? _context;

  static const _own = {'capabilities', 'openContext'};

  Future<String> _open() async => (await _bridge.openContext(
    TavernScriptContextSpec(instanceId: instanceId, chatId: chatId, characterId: characterId()),
  )).id;

  /// The reply to [request], always JSON; never throws.
  Future<Map<String, Object?>> handle(Object? request) async {
    if (request is! Map || request['method'] is! String || _own.contains(request['method'])) {
      return _wire.handle(request);
    }
    final params = request['params'] ?? const <Object?, Object?>{};
    if (params is! Map || params.containsKey('contextId')) return _wire.handle(request);
    final String context;
    try {
      context = await (_context ??= _open());
    } on TavernScriptException catch (e) {
      _context = null;
      return {'id': request['id'], 'ok': false, 'error': tavernScriptErrorJson(e)};
    } on Object catch (e) {
      _context = null;
      return {
        'id': request['id'],
        'ok': false,
        'error': {'code': 'internal', 'message': '$e', 'committed': false},
      };
    }
    final reply = await _wire.handle({
      ...request,
      'params': {...params, 'contextId': context},
    });
    // The engine let it go (reopened, closed): the next call opens anew.
    if (reply['error'] case {'code': 'closedContext' || 'noContext'}) _context = null;
    return reply;
  }

  /// The page is gone: its context goes with it.
  Future<void> close() async {
    final context = _context;
    _context = null;
    if (context == null) return;
    try {
      await _bridge.closeContext(await context);
    } on Object {
      // Never opened, or already closed: nothing to release.
    }
  }
}
