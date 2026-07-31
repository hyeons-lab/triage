import 'package:triage_client/session_grouping.dart';

/// A session for the ordering tests, with the two fields that decide where it
/// lands and defaults for everything else.
///
/// Shared by `session_grouping_test.dart` and `session_rail_layout_test.dart`
/// rather than written out in both: they drive the same functions with the same
/// shape of input, and two copies drift.
SessionOrderingInput session(String id, {String? repo, int activity = 0}) =>
    SessionOrderingInput(
      sessionId: id,
      repoRoot: repo,
      lastActivityMs: activity,
    );
