import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:triage_client/models/daemon_server.dart';
import 'package:triage_client/services/storage.dart';

/// shared_preferences key holding the JSON-encoded list of known daemons.
const String serversPrefKey = 'daemon_servers_v1';

/// shared_preferences key holding the id of the daemon to connect to on launch.
const String selectedServerPrefKey = 'daemon_selected_server_v1';

/// The single daemon address written before multi-server support. Read once to
/// migrate it into the server list, then deleted.
const String legacyDaemonAddressPrefKey = 'daemon_address_v1';

/// The single unkeyed side-rail order written before multi-server support.
const String legacySessionOrderPrefKey = 'session_order_v1';

/// shared_preferences key holding one server's side-rail order (an ordered list
/// of its session ids).
///
/// Keyed by server because session ids are daemon-local: with one global list,
/// switching to another daemon would overwrite the previous server's order with
/// ids it has never seen.
String sessionOrderPrefKeyFor(String serverId) => 'session_order_v1_$serverId';

/// The known daemons plus which one to connect to.
class ServerConfig {
  const ServerConfig({required this.servers, required this.selectedId});

  static const empty = ServerConfig(
    servers: <DaemonServer>[],
    selectedId: null,
  );

  final List<DaemonServer> servers;
  final String? selectedId;
}

/// A fresh, stable server id.
///
/// Deliberately random rather than derived from the address: a server's token is
/// stored under its id, so deriving the id from the address would orphan the
/// token whenever the address is edited (a host moving to a new IP, or a switch
/// from LAN to Tailscale) and force a needless re-pair.
String newServerId() {
  final random = Random.secure();
  final suffix = List.generate(
    8,
    (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
  return 'server-$suffix';
}

/// Loads the known daemons, migrating the pre-multi-server single address and
/// its unkeyed token on first launch after the upgrade.
///
/// Call after [loadCredentials], which the migration reads the legacy token
/// from. Returns [ServerConfig.empty] on any failure, which surfaces as the
/// first-run connection screen rather than a crash.
Future<ServerConfig> loadServers() async {
  final SharedPreferences prefs;
  try {
    prefs = await SharedPreferences.getInstance();
  } catch (_) {
    return ServerConfig.empty;
  }

  final servers = DaemonServer.decodeList(prefs.getString(serversPrefKey));
  if (servers.isNotEmpty) {
    return ServerConfig(
      servers: servers,
      selectedId: _resolveSelected(
        prefs.getString(selectedServerPrefKey),
        servers,
      ),
    );
  }

  return _migrateLegacyServer(prefs);
}

/// Picks the server to connect to: the persisted selection when it still names a
/// known server, otherwise the first one — so a selection left dangling by a
/// removal (or by another device) resolves to something connectable instead of
/// stranding the user on a blank screen.
String? _resolveSelected(String? selectedId, List<DaemonServer> servers) {
  if (servers.isEmpty) return null;
  final stillExists = servers.any((s) => s.id == selectedId);
  return stillExists ? selectedId : servers.first.id;
}

/// Moves the single pre-multi-server daemon address, and the unkeyed token
/// belonging to it, onto one server entry.
///
/// Both legacy keys are deleted once consumed, so this runs exactly once. That
/// matters: if the legacy address survived, a user who later removed every
/// server would find the old one silently resurrected on the next launch.
Future<ServerConfig> _migrateLegacyServer(SharedPreferences prefs) async {
  final legacyAddress = prefs.getString(legacyDaemonAddressPrefKey)?.trim();
  if (legacyAddress == null || legacyAddress.isEmpty) return ServerConfig.empty;

  final server = DaemonServer(
    id: newServerId(),
    label: DaemonServer.defaultLabelFor(legacyAddress),
    address: legacyAddress,
  );

  // Copy the token onto the new (random) id now so this session can connect,
  // but keep the legacy copy until the id is durably bound below.
  final copiedToken = copyLegacyTokenTo(server.id);

  final saved = await saveServers([server], selectedId: server.id);
  // Retire the legacy keys only once the server that binds this id is safely
  // stored. Dropping them after a failed save would leave nothing recoverable —
  // no server list, an orphaned token under a random id nothing references, and
  // no legacy address or token to retry from — forgetting the user's only
  // daemon and forcing a re-pair on the next launch. Adopting the rail order
  // (which deletes the legacy order key) belongs inside this guard for the same
  // reason: a failed save would otherwise strand the order under an id that
  // never reached disk, with the legacy key already gone.
  if (saved) {
    await adoptLegacySessionOrder(server.id);
    if (copiedToken) clearLegacyToken();
    try {
      await prefs.remove(legacyDaemonAddressPrefKey);
    } catch (_) {}
  }

  return ServerConfig(servers: [server], selectedId: server.id);
}

/// Copies the pre-multi-server unkeyed token onto [serverId] if one exists,
/// returning whether it copied anything.
///
/// This is what makes the upgrade a migration rather than a reset: carrying the
/// token over is what keeps an already-paired user from having to pair again.
///
/// Synchronous, because the credential cache is in memory — a caller can copy
/// the token and connect within the same frame.
///
/// It deliberately does NOT delete the legacy token. The caller must call
/// [clearLegacyToken] only once [serverId] is durably bound (its server entry
/// persisted): clearing earlier would, on a failed persist, orphan the copy
/// under an id nothing references — a random migration id that never reached
/// disk — and strand the user unpaired with no legacy token to retry from. And
/// because a false return also covers a *failed* read ([loadCredentials]
/// swallows a locked-Keychain read and leaves the cache empty, indistinguishable
/// here from "never paired"), a caller that only clears when this returned true
/// can never destroy a live credential it merely failed to read.
bool copyLegacyTokenTo(String serverId) {
  final legacyToken = retrieveLegacyToken()?.trim();
  if (legacyToken == null || legacyToken.isEmpty) return false;
  persistTokenFor(serverId, legacyToken);
  return true;
}

/// Repoints a stale web-origin selection at the current page [origin], carrying
/// its token across.
///
/// The web client derives its daemon from the page origin, persisting a
/// `web-<host>-<port>` entry (`webOriginServer`) that is selected on first load.
/// If the origin later changes — most often a client moving behind a TLS reverse
/// proxy on a new port (the case #107 addressed) — that entry still names the
/// old origin and, because it is selected, short-circuits server selection so
/// the client keeps dialing the dead address; the same-origin default is never
/// re-consulted. This migrates the selected `web-` entry onto [origin]'s id.
///
/// Returns the reconciled config plus the *stale* id whose per-server state (its
/// token and rail order) the caller must clean up once the config is durably
/// saved — null when nothing was reconciled. The token is copied onto [origin]'s
/// id here synchronously so the caller can connect this frame, but — exactly as
/// the legacy migration does — the stale copy is retired only after the swap
/// persists, so a failed save leaves it for the next launch to retry rather than
/// orphaning the credential.
///
/// A no-op unless the selection is a `web-`-prefixed entry that differs from
/// [origin]. Manually added servers (a stable, user-owned id) and an already
/// current origin are left untouched; the stale entry is dropped rather than
/// kept, so origins do not accumulate one dead entry each.
(ServerConfig, String?) reconcileWebOriginSelection(
  ServerConfig config,
  DaemonServer origin,
) {
  final selectedId = config.selectedId;
  if (selectedId == null ||
      !selectedId.startsWith('web-') ||
      selectedId == origin.id ||
      !config.servers.any((s) => s.id == selectedId)) {
    return (config, null);
  }

  // Carry the token onto the new id now so the caller connects this frame
  // without a re-pair; the caller clears the stale copy only after the swap
  // persists. Trimmed to match copyLegacyTokenTo — a whitespace-only value is
  // no credential. Never overwrite an existing origin credential: if the origin
  // is already paired (e.g. a prior sync), that token is the live one for this
  // frame, so the stale entry's copy would only downgrade it.
  final existing = retrieveTokenFor(origin.id)?.trim();
  if (existing == null || existing.isEmpty) {
    final token = retrieveTokenFor(selectedId)?.trim();
    if (token != null && token.isNotEmpty) persistTokenFor(origin.id, token);
  }

  // Drop the stale entry and any pre-existing origin entry before appending the
  // fresh one, so the list can never end up with two entries sharing origin.id
  // even if an earlier reconcile left one behind.
  final servers = <DaemonServer>[
    for (final server in config.servers)
      if (server.id != selectedId && server.id != origin.id) server,
    origin,
  ];
  return (ServerConfig(servers: servers, selectedId: origin.id), selectedId);
}

/// Moves one server's saved rail order from [fromId] onto [toId], deleting the
/// old key. Used when [reconcileWebOriginSelection] repoints a web-origin entry
/// so the user's session order follows the daemon rather than resetting, and the
/// stale key does not linger. Best-effort: ordering is a convenience, unlike the
/// token, so a failure just leaves the order to rebuild.
Future<void> migrateSessionOrder(String fromId, String toId) async {
  if (fromId == toId) return;
  try {
    final prefs = await SharedPreferences.getInstance();
    final order = prefs.getStringList(sessionOrderPrefKeyFor(fromId));
    if (order == null) return;
    await prefs.setStringList(sessionOrderPrefKeyFor(toId), order);
    await prefs.remove(sessionOrderPrefKeyFor(fromId));
  } catch (_) {}
}

/// Moves the pre-multi-server unkeyed rail order onto [serverId]. Best-effort:
/// ordering is a convenience, unlike the token.
Future<void> adoptLegacySessionOrder(String serverId) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    final legacyOrder = prefs.getStringList(legacySessionOrderPrefKey);
    if (legacyOrder == null) return;
    await prefs.setStringList(sessionOrderPrefKeyFor(serverId), legacyOrder);
    await prefs.remove(legacySessionOrderPrefKey);
  } catch (_) {}
}

/// Persists the server list and the selected id together — they are read as a
/// pair, so writing them as one keeps a selection from ever naming a server the
/// list doesn't have.
///
/// Returns whether the write landed. Callers that then *delete* what this
/// replaces — the migration retiring the legacy address — must not take a silent
/// failure for success, or they destroy both copies.
Future<bool> saveServers(
  List<DaemonServer> servers, {
  required String? selectedId,
}) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(serversPrefKey, DaemonServer.encodeList(servers));
    if (selectedId == null) {
      await prefs.remove(selectedServerPrefKey);
    } else {
      await prefs.setString(selectedServerPrefKey, selectedId);
    }
    return true;
  } catch (_) {
    return false;
  }
}
