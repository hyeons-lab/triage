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

  adoptLegacyToken(server.id);

  final saved = await saveServers([server], selectedId: server.id);
  await adoptLegacySessionOrder(server.id);
  // Retire the legacy address only once the server that replaces it is safely
  // stored. Dropping it after a failed save would leave nothing on either side —
  // no server list and no legacy address — and the user's only daemon would be
  // forgotten outright on the next launch.
  if (saved) {
    try {
      await prefs.remove(legacyDaemonAddressPrefKey);
    } catch (_) {}
  }

  return ServerConfig(servers: [server], selectedId: server.id);
}

/// Moves the pre-multi-server unkeyed token onto [serverId].
///
/// This is what makes the upgrade a migration rather than a reset: carrying the
/// token over is what keeps an already-paired user from having to pair again.
///
/// Synchronous, because the credential cache is in memory — a caller can adopt
/// the token and connect within the same frame.
///
/// The token is deleted only once it is safely copied. [loadCredentials]
/// swallows a failed Keychain read (locked before first unlock, plugin missing)
/// and leaves the cache empty, which is indistinguishable here from "never
/// paired" — so an unconditional delete would destroy a live credential we
/// merely failed to read. Leaving it costs a re-pair at worst; deleting it
/// guarantees one.
void adoptLegacyToken(String serverId) {
  final legacyToken = retrieveLegacyToken()?.trim();
  if (legacyToken == null || legacyToken.isEmpty) return;
  persistTokenFor(serverId, legacyToken);
  clearLegacyToken();
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
