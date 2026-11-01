import 'dart:async';

import 'package:dsh_client/dsh_client.dart';

import '../../l10n/l10n.dart';
import '../link_status.dart';
import 'direct_host_config.dart';

/// Loads the saved launch token for the host.
typedef DirectTokenLoader = Future<String?> Function();

/// Loads the saved session cookie (survives `dsh web` restarts: the Host's
/// signing secret is durable; only the launch token rotates).
typedef DirectCookieLoader = Future<DshCookie?> Function();

/// Persists the cookie issued by a token login.
typedef DirectCookieSaver = Future<void> Function(DshCookie cookie);

/// Logs in to the `dsh web` behind the origin, with the token or the cookie.
typedef DirectClientConnector =
    Future<DshClient> Function({required Uri baseUri, String? token, DshCookie? cookie});

/// Direct HTTPS host: `DshClient.connect(origin, …)` against a `dsh web` the
/// person reaches through their own reverse proxy — no SSH, no relay server.
///
/// Each open tries the saved session cookie first (the Host keeps its
/// signing secret across restarts, so a cookie outlives them); only when the
/// cookie is missing, expired or refused does it fall back to the launch
/// token, and a successful token login saves the fresh cookie. The link
/// fails closed only when neither credential works — the person pastes a
/// new launch URL.
class DirectHostLink implements HostLink {
  DirectHostLink({
    required this.config,
    required this._loadToken,
    this._loadCookie,
    this._saveCookie,
    DirectClientConnector? connectClient,
    Stream<void>? kicks,
    Backoff? backoff,
    this.retryFirstOpen = true,
  }) : _connectClient = connectClient ?? _defaultConnector,
       _backoff = backoff ?? Backoff(maxAttempts: 8) {
    _kickSub = kicks?.listen((_) => kick());
  }

  final DirectHostConfig config;
  final DirectTokenLoader _loadToken;
  final DirectCookieLoader? _loadCookie;
  final DirectCookieSaver? _saveCookie;
  final DirectClientConnector _connectClient;
  final Backoff _backoff;

  /// False for "测试连接": report the first network failure instead of
  /// grinding through the backoff.
  final bool retryFirstOpen;

  final _statuses = StreamController<HostLinkStatus>.broadcast(sync: true);
  final _clients = StreamController<DshClient>.broadcast();
  final _delay = InterruptibleDelay();
  StreamSubscription<void>? _kickSub;
  StreamSubscription<DshConnectionState>? _muxSub;
  HostLinkStatus _status = HostLinkStatus.idle;
  DshClient? _client;
  Future<DshClient>? _opening;
  bool _closed = false;
  bool _reauthing = false;

  @override
  HostLinkStatus get status => _status;

  @override
  DshClient? get currentClient => _status.isConnected ? _client : null;

  @override
  Stream<HostLinkStatus> get statuses => _statuses.stream;

  @override
  Stream<DshClient> get clients => _clients.stream;

  void _emit(HostLinkStatus next) {
    if (_closed && next.phase != HostLinkPhase.idle) return;
    _status = next;
    _statuses.add(next);
  }

  @override
  Future<DshClient> open() {
    if (_closed) return Future.error(StateError('link closed'));
    final client = _client;
    if (client != null && _status.isConnected) return Future.value(client);
    return _opening ??= _openWithRetry().whenComplete(() => _opening = null);
  }

  Future<DshClient> _openWithRetry() async {
    while (true) {
      try {
        return await _openOnce();
      } on HostLinkError catch (e) {
        if (!e.retryable || !retryFirstOpen || _backoff.exhausted || _closed) {
          _emit(HostLinkStatus(HostLinkPhase.failed, error: e, attempt: _backoff.attempt));
          rethrow;
        }
        final wait = _backoff.next();
        _emit(
          HostLinkStatus(
            HostLinkPhase.reconnecting,
            error: e,
            attempt: _backoff.attempt,
            nextRetryAt: DateTime.now().add(wait),
          ),
        );
        await _delay.wait(wait);
        if (_closed) throw StateError('link closed');
      }
    }
  }

  Future<DshClient> _openOnce() async {
    _emit(HostLinkStatus(HostLinkPhase.connecting, step: HostLinkStep.login));
    DshClient? client;
    DshHttpException? cookieRefused;
    final saved = await _loadCookie?.call();
    final cookie = (saved != null && !saved.isExpiredAt(DateTime.now())) ? saved : null;
    if (cookie != null) {
      try {
        client = await _connectClient(baseUri: config.baseUri, cookie: cookie);
      } on DshHttpException catch (e) {
        if (e.statusCode != 401 && e.statusCode != 403) {
          throw HostLinkError(loginFailedKind(e), appL10n.remoteErrDshSignIn, detail: '$e', retryable: true);
        }
        cookieRefused = e; // stale or revoked: fall back to the launch token
      } on DshException catch (e) {
        throw HostLinkError(
          HostLinkErrorKind.unreachable,
          appL10n.remoteErrDirectUnreachable,
          detail: '$e',
          retryable: true,
        );
      }
      if (client != null) return _publish(client);
    }
    final token = await _loadToken();
    if (token == null || token.isEmpty) {
      throw cookieRefused != null
          ? HostLinkError(HostLinkErrorKind.authFailed, appL10n.remoteErrDirectTokenExpired, detail: '$cookieRefused')
          : HostLinkError(HostLinkErrorKind.authFailed, appL10n.remoteErrDirectNoToken);
    }
    try {
      client = await _connectClient(baseUri: config.baseUri, token: token);
    } on DshHttpException catch (e) {
      final refused = e.statusCode == 401 || e.statusCode == 403;
      throw HostLinkError(
        refused ? HostLinkErrorKind.authFailed : HostLinkErrorKind.loginFailed,
        refused ? appL10n.remoteErrDirectTokenExpired : appL10n.remoteErrDshSignIn,
        detail: '$e',
        retryable: !refused,
      );
    } on DshException catch (e) {
      throw HostLinkError(
        HostLinkErrorKind.unreachable,
        appL10n.remoteErrDirectUnreachable,
        detail: '$e',
        retryable: true,
      );
    }
    // A token login mints the cookie that will carry the next restart.
    final issued = _issuedCookie(client);
    if (issued != null) await _saveCookie?.call(issued);
    return _publish(client);
  }

  static HostLinkErrorKind loginFailedKind(DshHttpException e) => HostLinkErrorKind.loginFailed;

  static DshCookie? _issuedCookie(DshClient client) {
    if (client.carrier is! DshHttpCarrier) return null;
    try {
      return client.connection.cookie;
    } catch (_) {
      return null;
    }
  }

  Future<DshClient> _publish(DshClient client) async {
    if (_closed) {
      await client.close().catchError((_) {});
      throw StateError('link closed');
    }
    final existing = _client;
    _backoff.reset();
    _client = client;
    _watchMux(client);
    _emit(HostLinkStatus(HostLinkPhase.connected, completed: HostLinkStep.values.toSet()));
    if (existing != null) {
      _clients.add(client);
      unawaited(existing.close().catchError((_) {}));
    }
    return client;
  }

  void _watchMux(DshClient client) {
    unawaited(_muxSub?.cancel());
    _muxSub = client.mux.states.listen((state) {
      if (!identical(client, _client) || _closed) return;
      switch (state) {
        case DshConnectionState.unauthorized:
          // The cookie stopped verifying (30-day life, or the person signed
          // out on the Host): re-open, which retries cookie then token.
          _reauth();
        case DshConnectionState.connected:
          if (!_status.isConnected) {
            _emit(HostLinkStatus(HostLinkPhase.connected, completed: HostLinkStep.values.toSet()));
          }
        case DshConnectionState.reconnecting:
          if (_status.isConnected) {
            _emit(
              HostLinkStatus(
                HostLinkPhase.reconnecting,
                error: HostLinkError(
                  HostLinkErrorKind.unreachable,
                  appL10n.remoteErrDirectUnreachable,
                  retryable: true,
                ),
              ),
            );
          }
        default:
          break;
      }
    });
  }

  void _reauth() {
    if (_closed || _reauthing) return;
    _reauthing = true;
    unawaited(
      () async {
        try {
          final old = _client;
          _client = null;
          await old?.close().catchError((_) {});
          await _openWithRetry();
        } on HostLinkError {
          // _openWithRetry already surfaced the final failure.
        } finally {
          _reauthing = false;
        }
      }(),
    );
  }

  @override
  void kick() {
    if (_closed) return;
    final client = _client;
    if (_status.isConnected && client != null) {
      // Network returned: don't wait for the mux's own backoff timer.
      client.mux.reconnect();
      return;
    }
    _delay.cancel();
    unawaited(open().then((_) {}, onError: (_) {}));
  }

  @override
  void retry() {
    _backoff.reset();
    _delay.cancel();
    unawaited(open().then((_) {}, onError: (_) {}));
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _delay.cancel();
    await _kickSub?.cancel();
    await _muxSub?.cancel();
    await _client?.close().catchError((_) {});
    _client = null;
    await _statuses.close();
    await _clients.close();
  }
}

Future<DshClient> _defaultConnector({required Uri baseUri, String? token, DshCookie? cookie}) =>
    DshClient.connect(baseUri: baseUri, token: token, cookie: cookie, backgroundLists: true);
