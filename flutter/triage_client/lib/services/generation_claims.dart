import 'package:flutter/foundation.dart';

/// Tracks in-flight per-session work with generational eviction.
///
/// A claim records the connect generation that took it. A same-generation
/// claimant performs identical work, so it skips; a newer generation evicts
/// a stale holder outright, since the holder always bails on staleness and
/// would otherwise veto work it will never perform. Attempt tokens make
/// release safe against eviction and purge races: only the owning attempt
/// clears its own claim.
class GenerationClaims {
  final Map<String, ({int attempt, int generation})> _holders = {};
  int _attemptCounter = 0;

  /// Claims [key] for [generation], returning the owning attempt token, or
  /// null when a same-or-newer generation already holds it.
  int? claim(String key, int generation) {
    final holder = _holders[key];
    if (holder != null && holder.generation >= generation) return null;
    if (holder != null) {
      debugPrint(
        'GenerationClaims: generation $generation evicted a generation '
        '${holder.generation} holder for $key',
      );
    }
    final attempt = ++_attemptCounter;
    _holders[key] = (attempt: attempt, generation: generation);
    return attempt;
  }

  /// Releases [key], but only when [attempt] still owns it: a purge clears
  /// the map mid-flight, and a stale attempt must not delete a newer
  /// attempt's claim.
  void release(String key, int attempt) {
    if (_holders[key]?.attempt == attempt) {
      _holders.remove(key);
    }
  }

  /// Drops all claims, e.g. when daemon-local state is purged.
  void clear() => _holders.clear();
}
