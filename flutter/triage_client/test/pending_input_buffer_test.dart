import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:triage_client/main.dart';

void main() {
  group('PendingInputBuffer', () {
    test('buffers while lease-less and snapshots without draining', () {
      final buffer = PendingInputBuffer();
      expect(buffer.add('s1', [1, 2, 3]), 0);
      expect(buffer.hasPending('s1'), isTrue);
      expect(buffer.snapshot('s1'), [1, 2, 3]);
      // A snapshot is for a send attempt; the bytes stay buffered until
      // the send is confirmed, so a failed write loses nothing.
      expect(buffer.snapshot('s1'), [1, 2, 3]);
      expect(buffer.hasPending('unknown'), isFalse);
      expect(buffer.snapshot('unknown'), isNull);
    });

    test('confirmSent drops only the sent prefix', () {
      final buffer = PendingInputBuffer();
      buffer.add('s1', [1, 2, 3]);
      buffer.confirmSent('s1', 2);
      expect(buffer.snapshot('s1'), [3]);
      buffer.confirmSent('s1', 1);
      expect(buffer.hasPending('s1'), isFalse);
      expect(buffer.snapshot('s1'), isNull);
    });

    test('bytes typed during a send stay queued behind it', () {
      final buffer = PendingInputBuffer();
      buffer.add('s1', [1, 2]);
      final inFlight = buffer.snapshot('s1')!;
      buffer.add('s1', [3]);
      buffer.confirmSent('s1', inFlight.length);
      expect(buffer.snapshot('s1'), [3]);
    });

    test('the cap keeps the fitting prefix and drops only the excess', () {
      final buffer = PendingInputBuffer();
      final dropped = buffer.add(
        's1',
        List<int>.filled(PendingInputBuffer.capacity - 6, 0),
      );
      expect(dropped, 0);
      // 100 more bytes arrive with only 6 bytes of room: the daemon twin
      // truncates to the cap, so the client must too, not drop all 100.
      expect(buffer.add('s1', List<int>.filled(100, 1)), 94);
      expect(buffer.snapshot('s1')!.length, PendingInputBuffer.capacity);
      // And past the cap everything drops.
      expect(buffer.add('s1', [9]), 1);
    });

    test(
      'cap truncation preserves UTF-8 boundaries and bracketed paste close',
      () {
        final buffer = PendingInputBuffer();
        buffer.add(
          's1',
          List<int>.filled(PendingInputBuffer.capacity - 16, 0x61),
        );
        // '\x1b[200~' (6 bytes) + '世' (3 bytes: E4 B8 96) + '界' (3 bytes) + '\x1b[201~' (6 bytes)
        final paste = <int>[
          0x1b, 0x5b, 0x32, 0x30, 0x30, 0x7e, // \x1b[200~
          0xe4, 0xb8, 0x96, // 世
          0xe7, 0x95, 0x8c, // 界
          0x1b, 0x5b, 0x32, 0x30, 0x31, 0x7e, // \x1b[201~
        ];
        final dropped = buffer.add('s1', paste);
        expect(dropped, greaterThan(0));
        final snap = buffer.snapshot('s1')!;
        // The closing '\x1b[201~' must still be present at the tail so the
        // remote application does not stay wedged in bracketed-paste mode,
        // and no partial UTF-8 sequence may remain before it.
        expect(snap.sublist(snap.length - 15), [
          0x1b, 0x5b, 0x32, 0x30, 0x30, 0x7e, // \x1b[200~
          0xe4, 0xb8, 0x96, // 世
          0x1b, 0x5b, 0x32, 0x30, 0x31, 0x7e, // \x1b[201~
        ]);
      },
    );

    test(
      'cap truncation drops bracketed paste when room < 12 instead of leaving mode 2004 open',
      () {
        final paste = <int>[
          0x1b, 0x5b, 0x32, 0x30, 0x30, 0x7e, // \x1b[200~
          0x61, // a
          0x1b, 0x5b, 0x32, 0x30, 0x31, 0x7e, // \x1b[201~
        ];
        for (final room in <int>[6, 11]) {
          final buffer = PendingInputBuffer();
          final prefixLen = PendingInputBuffer.capacity - room;
          buffer.add('s1', List<int>.filled(prefixLen, 0x78));
          final dropped = buffer.add('s1', paste);
          expect(dropped, paste.length);
          expect(buffer.snapshot('s1')!.length, prefixLen);
        }
      },
    );

    test(
      'cap truncation rewinds 4-byte UTF-8 codepoint split at +1, +2, and +3',
      () {
        // 'a' + 🦀 (F0 9F A6 80) + 'b'
        final payload = <int>[0x61, 0xf0, 0x9f, 0xa6, 0x80, 0x62];
        for (final room in <int>[2, 3, 4]) {
          final buffer = PendingInputBuffer();
          final prefixLen = PendingInputBuffer.capacity - room;
          buffer.add('s1', List<int>.filled(prefixLen, 0x78));
          final dropped = buffer.add('s1', payload);
          expect(dropped, payload.length - 1);
          final snap = buffer.snapshot('s1')!;
          expect(snap.sublist(prefixLen), <int>[0x61]);
        }
      },
    );

    test('sessions are independent and forget/clear are scoped', () {
      final buffer = PendingInputBuffer();
      buffer.add('s1', [1]);
      buffer.add('s2', [2]);
      buffer.forget('s1');
      expect(buffer.hasPending('s1'), isFalse);
      expect(buffer.snapshot('s2'), [2]);
      buffer.clear();
      expect(buffer.hasPending('s2'), isFalse);
    });
  });

  group('heartbeatShouldTeardown', () {
    const tolerance = Duration(seconds: 75);

    test('recent inbound traffic keeps the socket', () {
      expect(
        heartbeatShouldTeardown(
          millisSinceLastInbound: 0,
          tolerance: tolerance,
        ),
        isFalse,
      );
      expect(
        heartbeatShouldTeardown(
          millisSinceLastInbound: tolerance.inMilliseconds - 1,
          tolerance: tolerance,
        ),
        isFalse,
      );
    });

    test('silence at or past the tolerance tears down', () {
      expect(
        heartbeatShouldTeardown(
          millisSinceLastInbound: tolerance.inMilliseconds,
          tolerance: tolerance,
        ),
        isTrue,
      );
      expect(
        heartbeatShouldTeardown(
          millisSinceLastInbound: tolerance.inMilliseconds * 3,
          tolerance: tolerance,
        ),
        isTrue,
      );
    });

    test('a never-connected socket reads as fresh traffic', () {
      // The client's getter returns 0 before connect; the predicate
      // contract is "connected and silent for this long", so callers
      // pre-check connectedness (heartbeatFailureAction does).
      expect(
        heartbeatShouldTeardown(
          millisSinceLastInbound: 0,
          tolerance: tolerance,
        ),
        isFalse,
      );
    });
  });

  group('heartbeatFailureAction', () {
    const tolerance = Duration(seconds: 75);
    HeartbeatFailureAction decide({
      bool disposedOrStale = false,
      bool needsPairing = false,
      bool clientForeground = true,
      bool connected = true,
      int millisSinceLastInbound = 0,
    }) {
      return heartbeatFailureAction(
        disposedOrStale: disposedOrStale,
        needsPairing: needsPairing,
        clientForeground: clientForeground,
        connected: connected,
        millisSinceLastInbound: millisSinceLastInbound,
        tolerance: tolerance,
      );
    }

    test('each guard ignores the failure on its own', () {
      const silent = 10 * 60 * 1000;
      expect(
        decide(disposedOrStale: true, millisSinceLastInbound: silent),
        HeartbeatFailureAction.ignore,
      );
      expect(
        decide(needsPairing: true, millisSinceLastInbound: silent),
        HeartbeatFailureAction.ignore,
      );
      // The backgrounded case: the beat started in the foreground and
      // failed after the app backgrounded, so no teardown.
      expect(
        decide(clientForeground: false, millisSinceLastInbound: silent),
        HeartbeatFailureAction.ignore,
      );
      expect(
        decide(connected: false, millisSinceLastInbound: silent),
        HeartbeatFailureAction.ignore,
      );
    });

    test('unguarded outcomes follow the silence predicate', () {
      expect(
        decide(millisSinceLastInbound: 0),
        HeartbeatFailureAction.keepSocket,
      );
      expect(
        decide(millisSinceLastInbound: tolerance.inMilliseconds),
        HeartbeatFailureAction.teardown,
      );
    });
  });

  group('PendingInputSender', () {
    test('a successful flush sends the snapshot and drains it', () async {
      final buffer = PendingInputBuffer()..add('s1', [1, 2, 3]);
      final sender = PendingInputSender(buffer);
      final sent = <List<int>>[];
      final outcome = await sender.flush(
        's1',
        send: (bytes) async => sent.add(bytes),
        isLeaseDenial: (_) => false,
      );
      expect(outcome, PendingFlushOutcome.sent);
      expect(sent, [
        [1, 2, 3],
      ]);
      expect(buffer.hasPending('s1'), isFalse);
    });

    test('nothing pending sends nothing', () async {
      final sender = PendingInputSender(PendingInputBuffer());
      var sends = 0;
      final outcome = await sender.flush(
        's1',
        send: (_) async => sends++,
        isLeaseDenial: (_) => false,
      );
      expect(outcome, PendingFlushOutcome.nothingPending);
      expect(sends, 0);
    });

    test('a transport failure keeps the bytes for the next attempt', () async {
      final buffer = PendingInputBuffer()..add('s1', [1, 2]);
      final sender = PendingInputSender(buffer);
      final outcome = await sender.flush(
        's1',
        send: (_) async => throw StateError('socket gone'),
        isLeaseDenial: (_) => false,
      );
      expect(outcome, PendingFlushOutcome.failed);
      expect(buffer.snapshot('s1'), [1, 2]);
    });

    test('a lease denial drops the client copy the daemon parked', () async {
      final buffer = PendingInputBuffer()..add('s1', [1, 2]);
      final sender = PendingInputSender(buffer);
      final outcome = await sender.flush(
        's1',
        send: (_) async => throw StateError('does not hold input lease'),
        isLeaseDenial: (e) => '$e'.contains('does not hold input lease'),
      );
      // The daemon owns delivery of these bytes now (it parked them and
      // flushes on re-acquire); keeping the copy would deliver twice.
      expect(outcome, PendingFlushOutcome.deniedByDaemon);
      expect(buffer.hasPending('s1'), isFalse);
    });

    test(
      'overlapping flushes send once and drain mid-send bytes in order',
      () async {
        final buffer = PendingInputBuffer()..add('s1', [1, 2]);
        final sender = PendingInputSender(buffer);
        final gate = Completer<void>();
        final sent = <List<int>>[];
        final first = sender.flush(
          's1',
          send: (bytes) {
            sent.add(bytes);
            return sent.length == 1 ? gate.future : Future<void>.value();
          },
          isLeaseDenial: (_) => false,
        );
        // A LeaseChanged-driven second flush while the first is in flight.
        final second = await sender.flush(
          's1',
          send: (bytes) async => sent.add(bytes),
          isLeaseDenial: (_) => false,
        );
        expect(second, PendingFlushOutcome.alreadyInFlight);
        buffer.add('s1', [3]);
        gate.complete();
        expect(await first, PendingFlushOutcome.sent);
        expect(sent, [
          [1, 2],
          [3],
        ]);
        expect(buffer.hasPending('s1'), isFalse);
      },
    );
  });

  group('leaseErrorSessionId', () {
    test('extracts session id from daemon input-lease rejections', () {
      expect(
        leaseErrorSessionId(
          'client c1 does not hold input lease for session s-1',
        ),
        's-1',
      );
      expect(
        leaseErrorSessionId('session s_2 has no input lease holder'),
        's_2',
      );
    });

    test('ignores non-lease errors that mention a session id', () {
      expect(leaseErrorSessionId('session s-1 is being restored'), isNull);
      expect(leaseErrorSessionId('session s-1 not found'), isNull);
      expect(leaseErrorSessionId('socket closed'), isNull);
    });
  });

  group('attachGrantsInputLease', () {
    test(
      'grants lease only when holder matches and snapshot is not exited',
      () {
        expect(
          attachGrantsInputLease({
            'response': {
              'snapshot': {'exited': false},
              'lease': {
                'holder': {'client_id': 'c1'},
              },
            },
          }, 'c1'),
          isTrue,
        );
        expect(
          attachGrantsInputLease({
            'response': {
              'snapshot': {'exited': true},
              'lease': {
                'holder': {'client_id': 'c1'},
              },
            },
          }, 'c1'),
          isFalse,
        );
        expect(
          attachGrantsInputLease({
            'response': {
              'snapshot': {'exited': false},
              'lease': {
                'holder': {'client_id': 'c2'},
              },
            },
          }, 'c1'),
          isFalse,
        );
        expect(
          attachGrantsInputLease({
            'response': {
              'snapshot': {'exited': false},
              'lease': {'holder': null},
            },
          }, 'c1'),
          isFalse,
        );
        expect(attachGrantsInputLease(null, 'c1'), isFalse);
      },
    );
  });
}
