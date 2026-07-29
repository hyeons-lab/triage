// dart2js compiles Dart's `int` to a JavaScript number, and the `ByteData`
// implementation it ships has no `getUint64`/`setUint64` at all — both throw
// `Unsupported operation: Uint64 accessor not supported by dart2js`. flatc's
// generated bindings use exactly those accessors for every `ulong` field, so
// on Flutter web the binary transport dies the moment a message carries one:
// attach snapshots (`output_seq`, `bytes_logged`), event envelopes
// (`event_seq`), pairing challenges (`expires_at`), and so on.
//
// That matters more than a stray platform gap, because the daemon serves the
// web build as its own embedded UI (`crates/triaged/build.rs` runs
// `flutter build web --release`, which is dart2js with no `--wasm`).
//
// These helpers move the same eight bytes using only 32-bit accessors, which
// dart2js does implement. `scripts/generate-dart-flatbuffers.sh` rewrites every
// generated uint64 call site to route through them, and CI's `--check` mode
// applies the same rewrite before diffing, so a plain regeneration can no
// longer silently drop the fix — which is how it was lost once already, in
// 949fd6f undoing ad72b56.
//
// The wire format is untouched: these read and write the identical little-endian
// byte layout flatc would have, so a patched client and an unpatched one are
// interchangeable on both ends.
library;

import 'dart:typed_data';

import 'package:flat_buffers/flat_buffers.dart' as fb;

/// The largest integer JavaScript can hold exactly, and therefore the largest
/// a `ulong` field can round-trip through dart2js: 2^53 - 1.
const int maxSafeUint64 = 0x1fffffffffffff;

/// Scratch buffer for reinterpreting a uint64's bytes as a float64.
///
/// Reused across calls — every helper here writes all eight bytes before
/// reading them back, and Dart's single-threaded isolates mean no other call
/// can interleave between the two.
final ByteData _scratch = ByteData(8);

/// Reads the `ulong` whose vtable entry sits [field] bytes into the vtable, or
/// [defaultValue] when the field is absent.
///
/// [field] is a byte offset, not a slot index — generated call sites pass 4, 6,
/// 28 — matching `fb.Reader.vTableGet`, which this mirrors. Same vtable walk,
/// but the value is assembled from two `getUint32` reads instead of one
/// unsupported `getUint64`.
int readUint64(fb.BufferContext bc, int offset, int field, int defaultValue) {
  final buffer = bc.buffer;
  final vTableOffset = offset - buffer.getInt32(offset, Endian.little);
  final vTableSize = buffer.getUint16(vTableOffset, Endian.little);
  if (field >= vTableSize) return defaultValue;

  final fieldOffset = buffer.getUint16(vTableOffset + field, Endian.little);
  if (fieldOffset == 0) return defaultValue;

  final valueOffset = offset + fieldOffset;
  final low = buffer.getUint32(valueOffset, Endian.little);
  final high = buffer.getUint32(valueOffset + 4, Endian.little);
  if (high > maxSafeUint64 ~/ 0x100000000) {
    throw UnsupportedError(
      'uint64 field at vtable byte offset $field is $high:$low, which exceeds '
      'the '
      'JavaScript safe integer range and cannot be represented exactly',
    );
  }
  return high * 0x100000000 + low;
}

/// Writes [value] as the `ulong` in vtable slot [field], writing nothing when
/// [value] is null — the same contract as [fb.Builder.addUint64], which the
/// generated bindings rely on for optional fields.
///
/// Note [field] here is a slot *index* (0, 1, 12 at the generated call sites),
/// not the byte offset [readUint64] takes. That asymmetry comes from
/// flat_buffers itself — writers index slots, readers offset into the vtable —
/// and is preserved so these drop into the generated code unchanged.
///
/// Goes through [fb.Builder.addFloat64] rather than `addUint64`: both reserve
/// eight bytes with eight-byte alignment and occupy one vtable slot, so the
/// resulting buffer is byte-identical — but `setFloat64` is supported by
/// dart2js and `setUint64` is not. [value] is reinterpreted bit-for-bit, not
/// converted, so no precision is lost on the way through.
void addUint64(fb.Builder fbBuilder, int field, int? value) {
  if (value == null) return;
  fbBuilder.addFloat64(field, _uint64Bits(value));
}

/// Reinterprets [value]'s little-endian bytes as the float64 with the same bit
/// pattern.
double _uint64Bits(int value) {
  if (value < 0 || value > maxSafeUint64) {
    throw ArgumentError.value(
      value,
      'value',
      'uint64 fields must be between 0 and $maxSafeUint64 to survive dart2js',
    );
  }
  // Division rather than `>>`/`&`: dart2js narrows bitwise operands to 32 bits,
  // which would silently discard the high half.
  _scratch.setUint32(0, value % 0x100000000, Endian.little);
  _scratch.setUint32(4, value ~/ 0x100000000, Endian.little);
  // Capped at 2^53, the high half is at most 0x1fffff, so the bit pattern is
  // always a subnormal double — never a NaN, whose payload a JS engine is free
  // to canonicalize.
  return _scratch.getFloat64(0, Endian.little);
}
