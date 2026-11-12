// The App's TavernScriptHost (P2 B1): what the engine delivers to a script
// context goes to the page holding that context.
//
// - cache: the change (variables, messages, revisions) is put into the page
//   for its own copy, at once; it never waits on any script's handler, as the
//   engine's notes require (a handler awaiting a write needs that write's
//   cache to get through).
// - lifecycle: the page has no event handlers yet, so each is acknowledged
//   as completed with nothing run — which is what happened. Handlers
//   (eventOn) come next and will then hold the acknowledgement.
// - UI requests, callbacks and slash lookups are refused as unsupported,
//   never answered with an empty success.
// - refresh: the chat page redraws from its own watch of the path.

import 'package:dsh_tavern/dsh_tavern.dart';

import 'tavern_script_wire.dart';

/// Puts one delivery (JSON) into a page.
typedef TavernScriptPage = Future<void> Function(Map<String, Object?> delivery);

class TavernScriptPages implements TavernScriptHost {
  final _pages = <String, TavernScriptPage>{};
  TavernScriptBridge? _attached;

  /// Becomes [bridge]'s host, once.
  void attach(TavernScriptBridge bridge) {
    if (identical(_attached, bridge)) return;
    _attached = bridge;
    bridge.attachHost(this);
  }

  void add(String contextId, TavernScriptPage page) => _pages[contextId] = page;

  void remove(String contextId) => _pages.remove(contextId);

  @override
  Future<TavernScriptDispatchAck> dispatch(TavernScriptDispatch request, TavernScriptCancellation cancellation) async {
    final page = _pages[request.contextId];
    if (page != null && request.kind == TavernScriptDispatchKind.cache && !cancellation.isCancelled) {
      try {
        await page(tavernScriptDeliveryJson(request));
      } on Object {
        // The page went (its renderer, the screen): it reloads a snapshot
        // when it comes back. The engine's write is not undone by that.
      }
    }
    return TavernScriptDispatchAck(eventId: request.eventId);
  }

  @override
  Future<TavernScriptUiResult> interact(TavernScriptUiRequest request, TavernScriptCancellation cancellation) =>
      Future.error(_unsupported('interact'));

  @override
  Future<TavernScriptCallbackResult> invoke(
    TavernScriptCallbackRequest request,
    TavernScriptCancellation cancellation,
  ) => Future.error(_unsupported('invoke'));

  @override
  Future<TavernResolvedSlash?> resolveSlash(TavernSlashReference request, TavernScriptCancellation cancellation) =>
      Future.error(_unsupported('resolveSlash'));

  @override
  Future<void> refresh(TavernScriptRefreshRequest request) async {}
}

TavernScriptException _unsupported(String operation) => TavernScriptException(
  code: TavernScriptErrorCode.unsupportedCapability,
  operation: operation,
  message: 'The app does not answer $operation for card scripts yet.',
);

/// A delivery as the page reads it; a revision is the string it was given,
/// and a floor whose message went is kept as null.
Map<String, Object?> tavernScriptDeliveryJson(TavernScriptDispatch d) {
  final delta = d.delta;
  return {
    'kind': d.kind.name,
    'eventId': d.eventId,
    'contextId': d.contextId,
    'seq': d.seq,
    'name': d.name,
    'pathRevision': d.pathRevision,
    'delta': delta == null
        ? null
        : {
            'baseRevision': delta.baseRevision,
            'newRevision': delta.newRevision,
            'upsertMessages': [for (final m in delta.upsertMessages) tavernScriptMessageJson(m)],
            'removedRefs': [for (final r in delta.removedRefs) tavernScriptRefJson(r)],
            'indexChanges': {
              for (final MapEntry(:key, :value) in delta.indexChanges.entries)
                '$key': value == null ? null : tavernScriptRefJson(value),
            },
            'variables': [for (final v in delta.variableSnapshots) tavernScriptVariablesJson(v)],
            'resourceRefs': delta.resourceRefs,
          },
  };
}
