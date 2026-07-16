import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:triage_client/models/daemon_server.dart';
import 'package:triage_client/services/server_store.dart';
import 'package:triage_client/services/storage.dart';

/// Seeds the mocked Keychain and re-hydrates the credential cache from it, the
/// way `main()` does at startup.
Future<void> hydrateCredentials(Map<String, String> keychain) async {
  FlutterSecureStorage.setMockInitialValues(keychain);
  resetCredentialCacheForTesting();
  await loadCredentials();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await hydrateCredentials({});
  });

  group('DaemonServer', () {
    test('defaultLabelFor strips scheme, port, and path', () {
      expect(
        DaemonServer.defaultLabelFor('wss://my-mac.tailnet:7777/ws'),
        'my-mac.tailnet',
      );
      expect(DaemonServer.defaultLabelFor('192.168.1.5:7777'), '192.168.1.5');
      expect(DaemonServer.defaultLabelFor('my-mac'), 'my-mac');
    });

    test('defaultLabelFor keeps a bracketed IPv6 literal intact', () {
      // The port-stripping split is on the last colon, which would otherwise
      // eat half the address.
      expect(DaemonServer.defaultLabelFor('[::1]:7777'), '[::1]');
    });

    test('decodeList drops corrupt entries rather than throwing', () {
      final raw = DaemonServer.encodeList([
        const DaemonServer(id: 'a', label: 'A', address: 'host-a'),
      ]);
      expect(DaemonServer.decodeList(raw).single.id, 'a');

      // A record with no id cannot be keyed to a token, so it is unusable.
      expect(DaemonServer.decodeList('[{"label":"no id"}]'), isEmpty);
      expect(DaemonServer.decodeList('not json'), isEmpty);
      expect(DaemonServer.decodeList(null), isEmpty);
    });
  });

  group('loadServers migration', () {
    test('carries the legacy address and its token onto one server', () async {
      SharedPreferences.setMockInitialValues({
        legacyDaemonAddressPrefKey: 'my-mac.tailnet:7777',
        legacySessionOrderPrefKey: ['b', 'a'],
      });
      await hydrateCredentials({'triage_bearer_token': 'legacy-token'});

      final config = await loadServers();

      final server = config.servers.single;
      expect(server.address, 'my-mac.tailnet:7777');
      expect(server.label, 'my-mac.tailnet');
      expect(config.selectedId, server.id);

      // The token is the point of the migration: without it, every already-paired
      // user would be forced to re-pair on upgrade.
      expect(retrieveTokenFor(server.id), 'legacy-token');
      expect(retrieveLegacyToken(), isNull);

      // The rail order follows the daemon it was recorded against.
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getStringList(sessionOrderPrefKeyFor(server.id)), [
        'b',
        'a',
      ]);
      expect(prefs.getStringList(legacySessionOrderPrefKey), isNull);
    });

    test('consumes the legacy address so it cannot resurrect', () async {
      SharedPreferences.setMockInitialValues({
        legacyDaemonAddressPrefKey: 'my-mac.tailnet:7777',
      });
      await hydrateCredentials({});

      await loadServers();

      // A user who later forgets every server must not find the old one back on
      // the next launch, so the legacy key is deleted once consumed.
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(legacyDaemonAddressPrefKey), isNull);

      await saveServers(const [], selectedId: null);
      final afterRemovingAll = await loadServers();
      expect(afterRemovingAll.servers, isEmpty);
      expect(afterRemovingAll.selectedId, isNull);
    });

    test('does not delete a legacy token it could not read', () async {
      SharedPreferences.setMockInitialValues({
        legacyDaemonAddressPrefKey: 'my-mac.tailnet:7777',
      });
      // The Keychain holds a live token, but the hydrating read failed — locked
      // before first unlock, say — so the cache is empty. That is
      // indistinguishable from "never paired", and deleting on that basis would
      // destroy a working credential.
      FlutterSecureStorage.setMockInitialValues({
        'triage_bearer_token': 'live-token',
      });
      resetCredentialCacheForTesting();
      // Note: no loadCredentials() — this simulates the read having failed.

      await loadServers();

      const storage = FlutterSecureStorage();
      expect(await storage.read(key: 'triage_bearer_token'), 'live-token');
    });

    test('does not run when servers already exist', () async {
      const existing = DaemonServer(id: 'x', label: 'X', address: 'host-x');
      SharedPreferences.setMockInitialValues({
        serversPrefKey: DaemonServer.encodeList([existing]),
        selectedServerPrefKey: 'x',
        legacyDaemonAddressPrefKey: 'stale-host',
      });
      await hydrateCredentials({});

      final config = await loadServers();

      expect(config.servers.single.id, 'x');
      expect(config.selectedId, 'x');
    });

    test('first run with nothing stored yields no servers', () async {
      final config = await loadServers();
      expect(config.servers, isEmpty);
      expect(config.selectedId, isNull);
    });
  });

  group('loadServers selection', () {
    test(
      'falls back to the first server when the selection is dangling',
      () async {
        const a = DaemonServer(id: 'a', label: 'A', address: 'host-a');
        const b = DaemonServer(id: 'b', label: 'B', address: 'host-b');
        SharedPreferences.setMockInitialValues({
          serversPrefKey: DaemonServer.encodeList([a, b]),
          // Names a server that no longer exists — leaving this unresolved would
          // strand the app with nothing to connect to.
          selectedServerPrefKey: 'removed',
        });

        final config = await loadServers();
        expect(config.selectedId, 'a');
      },
    );

    test('honors a selection that still names a known server', () async {
      const a = DaemonServer(id: 'a', label: 'A', address: 'host-a');
      const b = DaemonServer(id: 'b', label: 'B', address: 'host-b');
      SharedPreferences.setMockInitialValues({
        serversPrefKey: DaemonServer.encodeList([a, b]),
        selectedServerPrefKey: 'b',
      });

      final config = await loadServers();
      expect(config.selectedId, 'b');
    });
  });

  group('adoptLegacyToken', () {
    test('moves the unkeyed token onto the given server', () async {
      // The web client is served by its daemon and never stored a daemon
      // address, so loadServers' migration — which keys off that address — never
      // sees it. Its origin server adopts the credential through this instead;
      // without it every existing web user is silently un-paired on upgrade.
      await hydrateCredentials({'triage_bearer_token': 'web-token'});

      adoptLegacyToken('web-my-mac-7777');

      expect(retrieveTokenFor('web-my-mac-7777'), 'web-token');
      expect(retrieveLegacyToken(), isNull);
    });

    test('is a no-op when there is no legacy token', () async {
      await hydrateCredentials({});

      adoptLegacyToken('web-my-mac-7777');

      expect(retrieveTokenFor('web-my-mac-7777'), isNull);
    });
  });

  group('tokens are per server', () {
    test('pairing with one daemon leaves the other daemon token intact', () {
      persistTokenFor('server-a', 'token-a');
      persistTokenFor('server-b', 'token-b');

      expect(retrieveTokenFor('server-a'), 'token-a');
      expect(retrieveTokenFor('server-b'), 'token-b');

      // Forgetting one daemon must not un-pair the other.
      clearTokenFor('server-a');
      expect(retrieveTokenFor('server-a'), isNull);
      expect(retrieveTokenFor('server-b'), 'token-b');
    });
  });
}
