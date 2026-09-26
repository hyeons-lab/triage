import 'package:flutter_test/flutter_test.dart';

import 'package:triage_client/services/generation_claims.dart';

void main() {
  test('first claim grants an attempt token', () {
    final claims = GenerationClaims();
    expect(claims.claim('s1', 1), isNotNull);
  });

  test('same-generation second claim is denied', () {
    final claims = GenerationClaims();
    expect(claims.claim('s1', 1), isNotNull);
    expect(claims.claim('s1', 1), isNull);
  });

  test('newer generation evicts a stale holder', () {
    final claims = GenerationClaims();
    final staleAttempt = claims.claim('s1', 1)!;
    final freshAttempt = claims.claim('s1', 2);
    expect(freshAttempt, isNotNull);
    expect(freshAttempt, isNot(staleAttempt));
    // The evicted attempt's release must not disturb the new claim.
    claims.release('s1', staleAttempt);
    expect(claims.claim('s1', 2), isNull);
  });

  test('older generation cannot evict a newer holder', () {
    final claims = GenerationClaims();
    expect(claims.claim('s1', 7), isNotNull);
    expect(claims.claim('s1', 5), isNull);
  });

  test('release clears only its own attempt', () {
    final claims = GenerationClaims();
    final attempt = claims.claim('s1', 1)!;
    claims.release('s1', attempt + 1);
    expect(claims.claim('s1', 1), isNull);
    claims.release('s1', attempt);
    expect(claims.claim('s1', 1), isNotNull);
  });

  test('release of an unknown key is a no-op', () {
    final claims = GenerationClaims();
    claims.release('missing', 1);
    expect(claims.claim('missing', 1), isNotNull);
  });

  test('clear drops all claims', () {
    final claims = GenerationClaims();
    claims.claim('s1', 1);
    claims.claim('s2', 1);
    claims.clear();
    expect(claims.claim('s1', 1), isNotNull);
    expect(claims.claim('s2', 1), isNotNull);
  });

  test('stale release after purge does not disturb the live claim', () {
    final claims = GenerationClaims();
    final staleAttempt = claims.claim('s1', 1)!;
    claims.clear();
    expect(claims.claim('s1', 2), isNotNull);
    claims.release('s1', staleAttempt);
    expect(claims.claim('s1', 2), isNull);
  });
}
