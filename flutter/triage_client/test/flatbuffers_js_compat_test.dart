import 'package:flat_buffers/flat_buffers.dart' as fb;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_test/flutter_test.dart';
import 'package:triage_client/services/flatbuffers_js_compat.dart' as fbjs;

/// Builds a single-field table holding [value] at vtable slot 4, written
/// through the compat layer, and returns a context positioned at its root.
fb.BufferContext _compatTable(int? value) {
  final builder = fb.Builder(initialSize: 64);
  builder.startTable(1);
  fbjs.addUint64(builder, 0, value);
  builder.finish(builder.endTable());
  return fb.BufferContext.fromBytes(builder.buffer);
}

/// The 2^32 boundary is where a carry bug between the two 32-bit halves would
/// show up, so the cases cluster around it.
const _representativeValues = <int>[
  0,
  1,
  0xffffffff, // low half saturated, high half empty
  0x100000000, // smallest value needing the high half
  0x100000001,
  1782616328232, // a realistic unix-millis timestamp
  fbjs.maxSafeUint64,
];

void main() {
  group('readUint64', () {
    test('round-trips values across the representable range', () {
      for (final value in _representativeValues) {
        final bc = _compatTable(value);
        expect(
          fbjs.readUint64(bc, bc.derefObject(0), 4, -1),
          value,
          reason: 'failed to round-trip $value',
        );
      }
    });

    test('returns the default when the field was never written', () {
      final bc = _compatTable(null);
      expect(fbjs.readUint64(bc, bc.derefObject(0), 4, 99), 99);
    });

    test('returns the default when the vtable is shorter than the slot', () {
      final bc = _compatTable(7);
      // Slot 6 is past the end of a single-field vtable.
      expect(fbjs.readUint64(bc, bc.derefObject(0), 6, 42), 42);
    });
  });

  group('addUint64', () {
    test('rejects values that cannot survive a JavaScript number', () {
      final builder = fb.Builder(initialSize: 32);
      builder.startTable(1);
      expect(
        () => fbjs.addUint64(builder, 0, fbjs.maxSafeUint64 + 1),
        throwsArgumentError,
      );
      expect(() => fbjs.addUint64(builder, 0, -1), throwsArgumentError);
    });

    test('writes nothing for a null value', () {
      expect(
        _compatTable(null).buffer.lengthInBytes,
        lessThan(_compatTable(1).buffer.lengthInBytes),
      );
    });
  });

  // The point of the compat layer is that the daemon cannot tell the
  // difference, so pin the bytes against flatc's own writer. Only the VM can
  // run this: `fb.Builder.addUint64` is the accessor dart2js lacks, which is
  // the entire reason the compat layer exists.
  group(
    'wire compatibility with flat_buffers',
    () {
      test('produces byte-identical output to fb.Builder.addUint64', () {
        for (final value in _representativeValues) {
          final stock = fb.Builder(initialSize: 64);
          stock.startTable(1);
          stock.addUint64(0, value);
          stock.finish(stock.endTable());

          final patched = fb.Builder(initialSize: 64);
          patched.startTable(1);
          fbjs.addUint64(patched, 0, value);
          patched.finish(patched.endTable());

          expect(
            patched.buffer,
            orderedEquals(stock.buffer),
            reason: 'byte layout diverged for $value',
          );
        }
      });

      test('reads back what fb.Builder.addUint64 wrote', () {
        final builder = fb.Builder(initialSize: 64);
        builder.startTable(1);
        builder.addUint64(0, 1782616328232);
        builder.finish(builder.endTable());

        final bc = fb.BufferContext.fromBytes(builder.buffer);
        expect(fbjs.readUint64(bc, bc.derefObject(0), 4, -1), 1782616328232);
      });
    },
    skip: kIsWeb
        ? 'fb.Builder.addUint64 is unsupported on dart2js — the reason this '
              'compat layer exists'
        : null,
  );
}
