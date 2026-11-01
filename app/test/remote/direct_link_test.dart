
import 'package:dsh_app/remote/direct/direct_host_config.dart';
import 'package:dsh_app/remote/direct/direct_link.dart';
import 'package:dsh_app/remote/link_status.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> _until(bool Function() test, {Duration timeout = const Duration(seconds: 5)}) async {
  final deadline = DateTime.now().add(timeout);
  while (!test()) {
    if (DateTime.now().isAfter(deadline)) throw StateError('_until timed out');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

Future<Object?> outcome(Future<DshClient> future) =>
    future.then<Object?>((client) => client, onError: (Object error) => error);

class FakeDirectClient extends DshClient {
  FakeDirectClient.withTestCarrier(super.carrier) : super.withCarrier();

  bool closed = false;

  @override
  Future<void> close() async {
    closed = true;
    await super.close();
  }
}

/// A carrier whose link refuses with 401 — parks the mux in `unauthorized`
/// without a live Host.
class _RefuseCarrier extends DshCarrier {
  @override
  String get kind => 'test-refuse';

  @override
  DshTracer? get tracer => null;

  @override
  Future<RpcResult> call(String endpoint, Map<String, Object?> args, {Duration? timeout}) async =>
      throw DshTransportException('no call in test', null);

  @override
  Future<DshMuxLink> openLink(MuxOptions options) async => throw const DshHttpException(401, 'fence refused');

  @override
  Future<void> close() async {}
}

const sampleDirect = DirectHostConfig(id: 'direct-test', name: '电脑', url: 'https://dsh.example.com');

void main() {
  test('normalizeOrigin keeps scheme/host/port and accepts a launch URL', () {
    expect(DirectHostConfig.normalizeOrigin('https://dsh.example.com'), 'https://dsh.example.com');
    expect(DirectHostConfig.normalizeOrigin('https://dsh.example.com/remote?x=1'), 'https://dsh.example.com');
    expect(DirectHostConfig.normalizeOrigin('dsh.example.com'), 'https://dsh.example.com');
    expect(DirectHostConfig.normalizeOrigin('ftp://x.y'), isNull);
    expect(DirectHostConfig.normalizeOrigin(''), isNull);
    expect(DirectHostConfig.tokenFrom('https://h/?token=abc'), 'abc');
    expect(DirectHostConfig.tokenFrom('https://h/'), isNull);
  });

  test('missing token fails closed without a connect attempt', () async {
    var connects = 0;
    final link = DirectHostLink(
      config: sampleDirect,
      loadToken: () async => null,
      connectClient: ({required baseUri, token, cookie}) {
        connects++;
        return Future.value(FakeDirectClient.withTestCarrier(_RefuseCarrier()));
      },
      retryFirstOpen: false,
    );
    addTearDown(link.close);
    final error = await outcome(link.open());
    expect(error, isA<HostLinkError>());
    expect((error as HostLinkError).kind, HostLinkErrorKind.authFailed);
    expect(connects, 0);
    expect(link.status.phase, HostLinkPhase.failed);
  });

  test('a 401 login is authFailed and not retried', () async {
    var connects = 0;
    final link = DirectHostLink(
      config: sampleDirect,
      loadToken: () async => 'tok',
      connectClient: ({required baseUri, token, cookie}) async {
        connects++;
        throw DshHttpException(401, 'fence refused');
      },
      retryFirstOpen: false,
    );
    addTearDown(link.close);
    final error = await outcome(link.open());
    expect(error, isA<HostLinkError>());
    expect((error as HostLinkError).kind, HostLinkErrorKind.authFailed);
    expect(error.retryable, isFalse);
    expect(connects, 1);
  });

  test('a network failure retries and the later success connects', () async {
    var attempt = 0;
    final client = FakeDirectClient.withTestCarrier(_RefuseCarrier());
    final link = DirectHostLink(
      config: sampleDirect,
      loadToken: () async => 'tok',
      connectClient: ({required baseUri, token, cookie}) async {
        attempt++;
        if (attempt == 1) throw DshTransportException('connect refused', null);
        return client;
      },
      backoff: Backoff(initial: const Duration(milliseconds: 1), max: const Duration(milliseconds: 2)),
    );
    addTearDown(link.close);
    addTearDown(client.close);
    final opened = await link.open();
    expect(identical(opened, client), isTrue);
    expect(attempt, 2);
    expect(link.status.phase, HostLinkPhase.connected);
    expect(link.currentClient, same(client));
  });

  test('a saved cookie logs in without the token and no cookie save runs', () async {
    final client = FakeDirectClient.withTestCarrier(_RefuseCarrier());
    final calls = <String>[];
    final link = DirectHostLink(
      config: sampleDirect,
      loadToken: () async {
        calls.add('token');
        return 'tok';
      },
      loadCookie: () async => DshCookie(name: 'n', value: 'v', authority: 'dsh.example.com'),
      saveCookie: (_) async => calls.add('save'),
      connectClient: ({required baseUri, token, cookie}) async {
        calls.add(cookie != null ? 'cookie' : 'tokenlogin');
        return client;
      },
    );
    addTearDown(link.close);
    addTearDown(client.close);
    await link.open();
    expect(calls, ['cookie']);
  });

  test('a refused cookie falls back to the token and saves the issued cookie', () async {
    final calls = <String>[];
    final tokenClient = FakeDirectClient.withTestCarrier(DshHttpCarrier(DshConnection(Uri.parse('https://dsh.example.com'))));
    final link = DirectHostLink(
      config: sampleDirect,
      loadToken: () async => 'tok',
      loadCookie: () async => DshCookie(name: 'n', value: 'v', authority: 'dsh.example.com'),
      saveCookie: (c) async {
        calls.add('save:${c.name}');
        return;
      },
      connectClient: ({required baseUri, token, cookie}) async {
        if (cookie != null) {
          calls.add('cookie-refused');
          throw DshHttpException(401, 'stale');
        }
        calls.add('tokenlogin');
        tokenClient.connection.cookie = DshCookie(name: 'fresh', value: 'x', authority: 'dsh.example.com');
        return tokenClient;
      },
      retryFirstOpen: false,
    );
    addTearDown(link.close);
    await link.open();
    expect(calls, ['cookie-refused', 'tokenlogin', 'save:fresh']);
  });

  test('close after a successful open closes the client', () async {
    final client = FakeDirectClient.withTestCarrier(_RefuseCarrier());
    final link = DirectHostLink(
      config: sampleDirect,
      loadToken: () async => 'tok',
      connectClient: ({required baseUri, token, cookie}) async => client,
    );
    await link.open();
    await link.close();
    expect(client.closed, isTrue);
    expect(link.currentClient, isNull);
  });

  test('an unauthorized mux re-opens and ends failed when no credential works', () async {
    final client = FakeDirectClient.withTestCarrier(_RefuseCarrier());
    var tokenCalls = 0;
    final link = DirectHostLink(
      config: sampleDirect,
      loadToken: () async => ++tokenCalls == 1 ? 'tok' : null, // the re-open cannot recover
      connectClient: ({required baseUri, token, cookie}) async => client,
    );
    addTearDown(link.close);
    await link.open();
    expect(tokenCalls, 1);
    // The mux's own retry hits the refusing carrier: 401 parks it in
    // unauthorized, which must trigger a re-open, not a silent dead link.
    await expectLater(client.mux.ready(), throwsA(isA<DshHttpException>()));
    await _until(() => link.status.phase == HostLinkPhase.failed);
    expect(tokenCalls, greaterThan(1)); // it actually tried to re-open
    expect(link.status.error?.kind, HostLinkErrorKind.authFailed);
  });
}
