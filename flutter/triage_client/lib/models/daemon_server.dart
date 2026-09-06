import 'dart:convert';

/// A daemon this device can connect to.
///
/// Users run more than one (e.g. a laptop at home and one at work), so each is
/// labeled and remembered. Each daemon pairs this device separately and issues
/// its own token, which is why tokens are stored keyed by [id] (see
/// `services/storage.dart`) rather than as a single global credential.
class DaemonServer {
  const DaemonServer({
    required this.id,
    required this.label,
    required this.address,
  });

  /// Stable identifier, also the key this server's pairing token is stored under.
  final String id;

  /// User-facing name, e.g. "Work laptop".
  final String label;

  /// The address exactly as the user typed it — a host, `host:port`, or a full
  /// `ws://` / `wss://` URL. Normalization happens at connect time.
  final String address;

  DaemonServer copyWith({String? label, String? address}) => DaemonServer(
    id: id,
    label: label ?? this.label,
    address: address ?? this.address,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'label': label,
    'address': address,
  };

  /// Null when the entry is unusable (no id or no address), so a corrupt record
  /// is dropped rather than crashing the rail.
  static DaemonServer? fromJson(Map<String, dynamic> json) {
    final id = (json['id'] as String?)?.trim();
    final address = (json['address'] as String?)?.trim();
    if (id == null || id.isEmpty || address == null || address.isEmpty) {
      return null;
    }
    final label = (json['label'] as String?)?.trim();
    return DaemonServer(
      id: id,
      label: (label == null || label.isEmpty)
          ? defaultLabelFor(address)
          : label,
      address: address,
    );
  }

  /// A sensible name for a server the user hasn't named: the host, with any
  /// scheme, port, and path stripped ("wss://my-mac.tailnet:7777" -> "my-mac.tailnet").
  static String defaultLabelFor(String address) {
    var host = address.trim();
    final scheme = host.indexOf('://');
    if (scheme != -1) host = host.substring(scheme + 3);
    // Strip path / query / fragment.
    for (final sep in ['/', '?', '#']) {
      final i = host.indexOf(sep);
      if (i != -1) host = host.substring(0, i);
    }
    // Strip the port, but keep a bracketed IPv6 literal intact.
    if (host.startsWith('[')) {
      final close = host.indexOf(']');
      if (close != -1) host = host.substring(0, close + 1);
    } else {
      final colon = host.lastIndexOf(':');
      if (colon > 0) host = host.substring(0, colon);
    }
    host = host.trim();
    return host.isEmpty ? address.trim() : host;
  }

  static String encodeList(List<DaemonServer> servers) =>
      jsonEncode([for (final s in servers) s.toJson()]);

  /// Tolerant of anything unparseable — a corrupt value yields an empty list
  /// rather than bricking startup.
  static List<DaemonServer> decodeList(String? raw) {
    if (raw == null || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return [
        for (final entry in decoded)
          if (entry is Map<String, dynamic>)
            if (fromJson(entry) case final server?) server,
      ];
    } catch (_) {
      return const [];
    }
  }
}
