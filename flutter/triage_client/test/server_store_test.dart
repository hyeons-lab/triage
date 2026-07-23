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

  group('copyLegacyTokenTo', () {
    test('copies the unkeyed token but leaves the legacy key intact', () async {
      // The web client is served by its daemon and never stored a daemon
      // address, so loadServers' migration — which keys off that address — never
      // sees it. Its origin server copies the credential through this instead;
      // without it every existing web user is silently un-paired on upgrade.
      await hydrateCredentials({'triage_bearer_token': 'web-token'});

      expect(copyLegacyTokenTo('web-my-mac-7777'), isTrue);

      expect(retrieveTokenFor('web-my-mac-7777'), 'web-token');
      // The legacy token is deliberately NOT cleared here: the caller retires it
      // only after the server entry is durably saved, so a failed save can be
      // retried from the legacy key instead of orphaning the copy.
      expect(retrieveLegacyToken(), 'web-token');
    });

    test(
      'returns false and copies nothing when there is no legacy token',
      () async {
        await hydrateCredentials({});

        expect(copyLegacyTokenTo('web-my-mac-7777'), isFalse);

        expect(retrieveTokenFor('web-my-mac-7777'), isNull);
      },
    );
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

  group('reconcileWebOriginSelection', () {
    // A web-origin entry from an earlier origin (e.g. loopback:7777 on the
    // pre-proxy build) that a since-proxied client would otherwise keep dialing.
    const stale = DaemonServer(
      id: 'web-127.0.0.1-7777',
      label: '127.0.0.1',
      address: 'ws://127.0.0.1:7777/ws',
    );
    // The current page origin the client is now served from.
    const origin = DaemonServer(
      id: 'web-proxy.example.com-443',
      label: 'proxy.example.com',
      address: 'wss://proxy.example.com:443/ws',
    );

    test('repoints a stale web selection at the current origin, carrying the '
        'token', () {
      persistTokenFor(stale.id, 'paired-token');
      final (reconciled, staleServerId) = reconcileWebOriginSelection(
        const ServerConfig(servers: [stale], selectedId: 'web-127.0.0.1-7777'),
        origin,
      );

      // The selection now names the current origin, and the dead entry is gone
      // rather than accumulating alongside it.
      expect(reconciled.selectedId, origin.id);
      expect(reconciled.servers.single.id, origin.id);
      // The token rides across, so an already-paired user is not silently
      // un-paired by the swap.
      expect(retrieveTokenFor(origin.id), 'paired-token');
      // The stale id is reported so the caller can clean its per-server state,
      // but its old token copy is kept until the caller durably saves the swap.
      expect(staleServerId, stale.id);
      expect(retrieveTokenFor(stale.id), 'paired-token');
    });

    test('trims a whitespace-padded token when carrying it across', () {
      persistTokenFor(stale.id, '  paired-token  ');
      final (reconciled, _) = reconcileWebOriginSelection(
        const ServerConfig(servers: [stale], selectedId: 'web-127.0.0.1-7777'),
        origin,
      );
      expect(reconciled.selectedId, origin.id);
      expect(retrieveTokenFor(origin.id), 'paired-token');
    });

    test('is a no-op when the selection already names the current origin', () {
      const config = ServerConfig(
        servers: [origin],
        selectedId: 'web-proxy.example.com-443',
      );
      final (reconciled, staleServerId) = reconcileWebOriginSelection(
        config,
        origin,
      );
      expect(identical(reconciled, config), isTrue);
      expect(staleServerId, isNull);
    });

    test('is a no-op when a web selection is not among the known servers', () {
      // _resolveSelected keeps a persisted selection from dangling, but guard
      // against a corrupt store all the same: a selected id with no matching
      // entry must not be repointed (there is nothing to migrate a token from).
      const other = DaemonServer(
        id: 'web-proxy.example.com-443',
        label: 'proxy.example.com',
        address: 'wss://proxy.example.com:443/ws',
      );
      const config = ServerConfig(
        servers: [other],
        selectedId: 'web-127.0.0.1-7777',
      );
      final (reconciled, staleServerId) = reconcileWebOriginSelection(
        config,
        origin,
      );
      expect(identical(reconciled, config), isTrue);
      expect(staleServerId, isNull);
    });

    test(
      'leaves a manually added server selected, even for the same daemon',
      () {
        // A user-added server owns a stable id it controls; the origin default
        // must never rewrite it, even when it points at the same daemon.
        const manual = DaemonServer(
          id: 'server-abc',
          label: 'proxy',
          address: 'wss://proxy.example.com/ws',
        );
        persistTokenFor('server-abc', 'manual-token');
        final (reconciled, staleServerId) = reconcileWebOriginSelection(
          const ServerConfig(servers: [manual], selectedId: 'server-abc'),
          origin,
        );

        expect(reconciled.servers.single.id, 'server-abc');
        expect(reconciled.selectedId, 'server-abc');
        // Nothing carried onto the origin id, and nothing to retire.
        expect(retrieveTokenFor(origin.id), isNull);
        expect(staleServerId, isNull);
      },
    );

    test('drops only the stale entry, preserving other known servers', () {
      const manual = DaemonServer(
        id: 'server-abc',
        label: 'lan',
        address: 'lan-host:7777',
      );
      persistTokenFor(stale.id, 't');
      final (reconciled, _) = reconcileWebOriginSelection(
        const ServerConfig(
          servers: [manual, stale],
          selectedId: 'web-127.0.0.1-7777',
        ),
        origin,
      );

      final ids = reconciled.servers.map((s) => s.id).toSet();
      expect(ids, {'server-abc', origin.id});
      expect(ids.contains(stale.id), isFalse);
      expect(reconciled.selectedId, origin.id);
    });

    test('does not duplicate a pre-existing origin entry when repointing', () {
      // Defensive: were an earlier reconcile to have left a `web-` entry already
      // using origin.id, repointing the stale selection must not yield two
      // entries sharing that id.
      final (reconciled, staleServerId) = reconcileWebOriginSelection(
        const ServerConfig(
          servers: [stale, origin],
          selectedId: 'web-127.0.0.1-7777',
        ),
        origin,
      );
      expect(reconciled.servers.map((s) => s.id).toList(), [origin.id]);
      expect(reconciled.selectedId, origin.id);
      expect(staleServerId, stale.id);
    });

    test(
      'repoints even an unpaired stale entry, still reporting the stale id',
      () {
        final (reconciled, staleServerId) = reconcileWebOriginSelection(
          const ServerConfig(
            servers: [stale],
            selectedId: 'web-127.0.0.1-7777',
          ),
          origin,
        );
        // The wrong origin is corrected regardless of pairing state, and the
        // stale id is still reported so its (empty) per-server state is cleaned...
        expect(reconciled.selectedId, origin.id);
        expect(staleServerId, stale.id);
        // ...but nothing was carried, since there was no token.
        expect(retrieveTokenFor(origin.id), isNull);
      },
    );

    test('is a no-op when nothing is selected', () {
      const config = ServerConfig(servers: [], selectedId: null);
      final (reconciled, staleServerId) = reconcileWebOriginSelection(
        config,
        origin,
      );
      expect(identical(reconciled, config), isTrue);
      expect(staleServerId, isNull);
    });
  });

  group('migrateSessionOrder', () {
    test(
      'moves the rail order onto the new id and deletes the old key',
      () async {
        SharedPreferences.setMockInitialValues({
          sessionOrderPrefKeyFor('web-127.0.0.1-7777'): ['c', 'a', 'b'],
        });

        await migrateSessionOrder(
          'web-127.0.0.1-7777',
          'web-proxy.example.com-443',
        );

        final prefs = await SharedPreferences.getInstance();
        expect(
          prefs.getStringList(
            sessionOrderPrefKeyFor('web-proxy.example.com-443'),
          ),
          ['c', 'a', 'b'],
        );
        // The stale key does not linger once its order has moved.
        expect(
          prefs.getStringList(sessionOrderPrefKeyFor('web-127.0.0.1-7777')),
          isNull,
        );
      },
    );

    test('does nothing when the source has no saved order', () async {
      await migrateSessionOrder('web-a-1', 'web-b-2');
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getStringList(sessionOrderPrefKeyFor('web-b-2')), isNull);
    });

    test('is a no-op when the ids are the same', () async {
      SharedPreferences.setMockInitialValues({
        sessionOrderPrefKeyFor('web-a-1'): ['x'],
      });
      await migrateSessionOrder('web-a-1', 'web-a-1');
      final prefs = await SharedPreferences.getInstance();
      // Order preserved, not deleted by a self-move.
      expect(prefs.getStringList(sessionOrderPrefKeyFor('web-a-1')), ['x']);
    });
  });
}
