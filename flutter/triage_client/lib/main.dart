import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart'
    show
        TargetPlatform,
        defaultTargetPlatform,
        kIsWeb,
        listEquals,
        visibleForTesting;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:triage_client/services/external_navigation.dart';
import 'package:triage_client/services/triage_websocket_client.dart';
import 'package:xterm/xterm.dart' as xt;
import 'package:triage_client/models/terminal_models.dart';
import 'package:triage_client/models/daemon_server.dart';
import 'package:triage_client/widgets/terminal_pane.dart';
import 'package:triage_client/services/server_store.dart';
import 'package:triage_client/services/storage.dart';
import 'package:triage_client/session_grouping.dart';
import 'package:triage_client/session_rail_layout.dart';
import 'package:triage_client/terminal/emulator_query_response.dart';
import 'package:triage_client/terminal/terminal_intent.dart';
import 'package:triage_client/terminal/terminal_store.dart';
import 'package:triage_client/terminal/terminal_controller_sink.dart';
// Process-env access (home dir, marquee gating) behind a conditional import so
// the web client — which has no `dart:io` — compiles against web stubs.
import 'package:triage_client/platform_env_io.dart'
    if (dart.library.js_util) 'package:triage_client/platform_env_web.dart';

// Retain icons for Flutter's font tree-shaker in release web builds.
const List<IconData> _kRequiredIcons = <IconData>[
  Icons.auto_awesome,
  Icons.person_outline,
  Icons.dns_outlined,
  Icons.tune,
  Icons.content_copy,
  Icons.check,
  Icons.info_outline,
  Icons.shield_outlined,
  Icons.radio_button_checked,
  Icons.radio_button_unchecked,
  Icons.edit_outlined,
  Icons.delete_outline,
  Icons.add,
  Icons.settings,
  Icons.terminal,
  Icons.close,
  Icons.bolt,
  Icons.lock_outline,
  Icons.integration_instructions_outlined,
  Icons.warning_amber_rounded,
  Icons.check_circle_outline,
  Icons.label_outline,
  Icons.label_off_outlined,
];

void main() async {
  assert(_kRequiredIcons.isNotEmpty);
  WidgetsFlutterBinding.ensureInitialized();
  // Restore the persisted client id / per-server pairing tokens from secure
  // storage before the first frame so the app can reconnect without re-pairing
  // on each launch. Must precede loadServers, whose migration reads the legacy
  // token from the same cache.
  await loadCredentials();
  // Restore the known daemons so we auto-connect to the selected one (or, on
  // first run, show the connection screen).
  final servers = await loadServers();
  runApp(TriageClientApp(initialServers: servers));
}

const int _defaultDaemonPort = 7777;

/// Parses a user-entered daemon address into a WebSocket [Uri], or null if it
/// can't be normalized. Accepts a bare host/IP (`host` → `ws://host:7777/ws`),
/// `host:port`, a bracketed IPv6 literal (`[::1]:7777`), or a full
/// `ws://`/`wss://`/`http://`/`https://` URL (http→ws, https→wss; path defaults
/// to `/ws`, port to 7777).
@visibleForTesting
Uri? parseDaemonAddress(String input) {
  final raw = input.trim();
  if (raw.isEmpty) return null;

  final hasScheme = RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*://').hasMatch(raw);
  if (hasScheme) {
    final parsed = Uri.tryParse(raw);
    if (parsed == null || parsed.host.isEmpty) return null;
    final scheme = switch (parsed.scheme.toLowerCase()) {
      'ws' || 'http' => 'ws',
      'wss' || 'https' => 'wss',
      _ => null,
    };
    if (scheme == null) return null;
    final port = parsed.hasPort ? parsed.port : _defaultDaemonPort;
    final path = (parsed.path.isEmpty || parsed.path == '/')
        ? '/ws'
        : parsed.path;
    return Uri(
      scheme: scheme,
      host: parsed.host,
      port: port,
      path: path,
      query: parsed.hasQuery ? parsed.query : null,
      fragment: parsed.hasFragment ? parsed.fragment : null,
    );
  }

  String host;
  var port = _defaultDaemonPort;
  final bracketedV6 = RegExp(r'^\[([^\]]+)\](?::(\d+))?$').firstMatch(raw);
  if (bracketedV6 != null) {
    host = bracketedV6.group(1)!;
    final portStr = bracketedV6.group(2);
    if (portStr != null) {
      final p = int.tryParse(portStr);
      if (p == null || p < 1 || p > 65535) return null;
      port = p;
    }
  } else {
    final colons = ':'.allMatches(raw).length;
    if (colons == 1) {
      final idx = raw.indexOf(':');
      host = raw.substring(0, idx);
      final p = int.tryParse(raw.substring(idx + 1));
      if (p == null || p < 1 || p > 65535) return null;
      port = p;
    } else {
      // 0 colons → host/IPv4; 2+ colons → bare IPv6 literal (default port).
      host = raw;
    }
  }
  if (host.isEmpty) return null;
  return Uri(scheme: 'ws', host: host, port: port, path: '/ws');
}

/// The per-server storage key used when no server is configured. Only the
/// injected-client test path, which never goes through server configuration,
/// reaches it.
@visibleForTesting
const String unconfiguredServerId = 'default';

/// The web client is served *by* a daemon, so its daemon is implied by the page
/// origin rather than configured. Synthesizing a server entry for it keeps the
/// invariant that a live connection always has an active server, so token
/// keying, session order, and the switcher need no web special case.
///
/// The id is derived from the origin — unlike a user-added server, whose address
/// is editable and whose id must therefore stay stable across an edit. Here the
/// origin *is* the identity, and deriving it keeps two daemons that both serve a
/// web client from colliding on one token.
DaemonServer webOriginServer(Uri wsUri) {
  return DaemonServer(
    id: 'web-${wsUri.host}-${wsUri.port}',
    label: DaemonServer.defaultLabelFor(wsUri.toString()),
    address: wsUri.toString(),
  );
}

const double _sessionRailCollapsedWidth = 72;
const double _sessionRailExpandedWidth = 320;
const Duration _sessionRailAnimationDuration = Duration(milliseconds: 220);

/// Matches an octet as plain decimal digits only.
///
/// `int.tryParse` is too permissive to use on its own here: it accepts `0x7f`
/// (hex, no radix needed), a leading `+`/`-`, and surrounding whitespace, so
/// `0x7f.0.0.1` and `+127.0.0.1` would parse as loopback.
final RegExp _decimalOctet = RegExp(r'^[0-9]{1,3}$');

/// Whether `host` is a dotted-quad IPv4 address in `127.0.0.0/8`.
///
/// Parsed rather than prefix-matched: `127.example.com` and
/// `127.0.0.1.evil.com` are perfectly legal DNS names (only the final label is
/// barred from being all-numeric), and a `startsWith('127.')` test treats both
/// as loopback.
bool _isIpv4LoopbackLiteral(String host) {
  final parts = host.split('.');
  if (parts.length != 4) return false;
  for (final part in parts) {
    if (!_decimalOctet.hasMatch(part)) return false;
    if (int.parse(part) > 255) return false;
  }
  return int.parse(parts.first) == 127;
}

/// Hosts that mean "this machine" — every loopback spelling a browser, proxy,
/// or local tool is liable to produce.
///
/// Shared by the dev-server check and pairing-URL verification so the two can't
/// drift apart. Takes a bare host as `Uri.host` reports it, which strips the
/// brackets from an IPv6 literal (`http://[::1]/` → `::1`) but does not
/// normalize between IPv6 spellings.
bool _isLoopbackHost(String host) {
  final normalized = host.toLowerCase();
  return normalized == 'localhost' ||
      normalized == '::1' ||
      normalized == '0:0:0:0:0:0:0:1' ||
      normalized == '::ffff:127.0.0.1' ||
      _isIpv4LoopbackLiteral(normalized);
}

/// The websocket target implied by the page that served the web client.
///
/// The web client is served *by* a daemon, so the page origin is normally the
/// daemon — including when a reverse proxy fronts it on 443, where the origin
/// is the only way to find the daemon at all. Deriving scheme from the origin
/// also keeps an `https` page on `wss`, which a browser requires (a `ws://`
/// target from an `https://` page is blocked as mixed content).
///
/// The exception is the Flutter dev server: `flutter run -d chrome` serves the
/// app from loopback on its own port while the daemon listens separately on
/// [_defaultDaemonPort], so a loopback origin on any other port means "dev
/// server" and falls back to the local daemon. A non-loopback origin is always
/// treated as the daemon, whatever its port.
@visibleForTesting
Uri defaultWebSocketUriForBase(Uri base) {
  final isHttp = base.scheme == 'http' || base.scheme == 'https';
  final isDevServer =
      _isLoopbackHost(base.host) && base.port != _defaultDaemonPort;

  if (isHttp && base.host.isNotEmpty && !isDevServer) {
    return Uri(
      scheme: base.scheme == 'https' ? 'wss' : 'ws',
      host: base.host,
      port: base.port,
      path: '/ws',
    );
  }

  return Uri.parse('ws://127.0.0.1:$_defaultDaemonPort/ws');
}

class TriageClientApp extends StatelessWidget {
  const TriageClientApp({
    super.key,
    this.client,
    this.initialServers = ServerConfig.empty,
  });

  final TriageWebSocketClient? client;
  // The daemons this device knows about, restored at startup, and which one to
  // connect to. Empty on first run → the connection screen is shown instead of
  // auto-connecting.
  final ServerConfig initialServers;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Triage',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xff2b6f6f),
          brightness: Brightness.dark,
        ),
        fontFamily: 'Segoe UI',
        scaffoldBackgroundColor: const Color(0xff101416),
      ),
      home: TriageHome(client: client, initialServers: initialServers),
    );
  }
}

enum NewSessionShell {
  cmd('cmd.exe', 'Cmd'),
  bash('bash', 'Bash'),
  defaultPosix('/bin/sh', 'Default', ['-lc', 'exec "\${SHELL:-/bin/sh}"']);

  const NewSessionShell(this.command, this.label, [this.args = const []]);

  final String command;
  final String label;
  final List<String> args;
}

@visibleForTesting
List<NewSessionShell> newSessionShellMenuOrderForPlatform(
  TargetPlatform platform,
) {
  return platform == TargetPlatform.windows
      ? const [NewSessionShell.cmd, NewSessionShell.bash]
      : const [NewSessionShell.defaultPosix];
}

@visibleForTesting
bool showNewSessionShellMenuForPlatform(TargetPlatform platform) {
  return platform == TargetPlatform.windows;
}

/// True on touch platforms — where the terminal takes IME input, so requesting
/// focus raises the soft keyboard and insets the viewport.
///
/// False under the widget tests: their default platform is android, but they
/// assert the desktop side-by-side layout.
bool isMobilePlatform() =>
    !runningUnderFlutterTest() &&
    (defaultTargetPlatform == TargetPlatform.iOS ||
        defaultTargetPlatform == TargetPlatform.android);

/// Whether a client in [state] should be asserting its terminal size on the
/// shared PTY.
///
/// Only [AppLifecycleState.resumed] counts. `inactive` in particular does not:
/// Flutter's web engine maps a window `blur` to it and only a tab-hide to
/// `hidden`, and a desktop window sitting behind another reports it too. Those
/// are exactly the moments the user is looking at a different device, which is
/// when this client should stop competing for the size.
bool foregroundForLifecycle(AppLifecycleState state) =>
    state == AppLifecycleState.resumed;

/// The shells to attempt, in order, when creating a session.
///
/// The daemon spawns the shell, but the menu order above is derived from
/// `defaultTargetPlatform` — the device the *client* runs on, which says
/// nothing about the machine running `triaged`. A phone or Mac driving a
/// Windows daemon would otherwise only ever ask for `/bin/sh`, which cannot
/// spawn there ("spawning PTY child"), and the new-session button would fail
/// every time with no menu to pick a working shell from.
///
/// Every shell is tried rather than one hard-coded partner so the chain stays
/// correct as variants are added, and the preferred one still goes first — on a
/// daemon that matches the client's platform the first attempt succeeds and
/// nothing else is tried.
@visibleForTesting
List<NewSessionShell> newSessionShellFallbackChain(NewSessionShell preferred) {
  return [
    preferred,
    for (final shell in NewSessionShell.values)
      if (shell != preferred) shell,
  ];
}

class SessionVm {
  SessionVm({
    required this.title,
    required this.status,
    required this.statusColor,
    required this.icon,
    required this.rows,
    this.sessionId,
    this.customLabel,
    this.branch,
    this.repoRoot,
    this.worktreeRoot,
    this.cwd,
    this.isRemote = false,
    this.isExited = false,
  }) : terminalController = TerminalController() {
    terminal = xt.Terminal(
      maxLines: 50000,
      // Re-wrap the whole buffer on resize, like a real terminal — otherwise
      // scrollback keeps its old wrap points and a full-screen TUI's in-place
      // redraw after SIGWINCH collides with mis-sized cells. The scroll anchor
      // tolerates reflow replacing line objects: it drops a detached anchor
      // line (`BufferLine.attached`) and falls back to following the bottom.
      reflowEnabled: true,
      onResize: (w, h, pw, ph) => onTerminalResize?.call(w, h, pw, ph),
    );
    terminalController.addWriteListener((data) {
      terminal.write(data);
    });
    terminalController.addClearListener(() {
      try {
        terminal.useMainBuffer();
        terminal.mainBuffer.clear();
        terminal.altBuffer.clear();
        terminal.write('\x1b[H\x1b[2J\x1b[3J');
      } catch (_) {}
    });
    terminalController.addResizeListener((cols, rows) {
      terminal.resize(cols, rows);
    });
    store = TerminalStore(TerminalControllerSink(terminalController));
    // Seed the inferred worktree from the constructor's own context so an attach
    // straight into a worktree is remembered from the first frame.
    _recordInferredWorktree();
  }

  final String title;
  /// Optional user-assigned label that overrides the automatic workstream title.
  String? customLabel;
  // Git context for this session, from the snapshot context and refreshed live
  // via `session_context_updated` pushes. All null when the session isn't in a
  // git repo (or the host is too old to report context).
  String? branch;
  // Absolute git repository root and worktree root for this session.
  String? repoRoot;
  String? worktreeRoot;
  // Milliseconds since the Unix epoch of this session's most recent output, as
  // last reported by the daemon; 0 when unknown. Held here so the rail can
  // re-group after a drag without another round-trip: the grouping needs
  // per-session activity, and a `SessionGroup` only carries the group's max.
  //
  // Deliberately *not* refreshed from live output events: the rail re-sorts only
  // when something structural happens (see [_sessionGroups]), not continuously,
  // so that rows do not slide out from under the pointer while a background
  // build is producing output. The cost is that this is a snapshot of recency
  // rather than a live ranking.
  int lastActivityMs = 0;
  // The last distinct linked worktree this session was seen driving, kept so the
  // rail can lead a root/`main` row with it (see [railTitleAt]). A `git -C
  // worktrees/x …` run from the primary checkout chdirs git into the worktree,
  // so the daemon reports that worktree only for the instant the command runs;
  // this remembers it across the gaps. `_inferredRepoRoot` pins it to the repo
  // it belonged to, so a session that moves to a *different* repo does not
  // inherit this one's workstream. `_inferredWorktreeAt` stamps the last
  // observation for the [stickyWorktreeTtl] expiry.
  String? _inferredRepoRoot;
  String? _inferredWorktreeRoot;
  String? _inferredBranch;
  DateTime? _inferredWorktreeAt;
  // Absolute current working directory, shown in the rail in place of the git
  // line when the session isn't inside a repo. Mutable so live context pushes
  // can update it without recreating the view-model.
  String? cwd;
  String status;
  Color statusColor;
  // Local-LLM one-line description of what the session is doing, shown in the
  // side rail. Null until the daemon generates one (or summarization is off).
  String? snippet;
  // Local-LLM longer-form summary for the hover popover / future search. Null
  // until the daemon generates one (or summarization is off).
  String? snippetDetail;
  // When a `session_snippet_updated` push last brought a non-empty snippet for
  // this session — the closest thing to "last did something" the client can
  // observe for a session it isn't attached to.
  //
  // Deliberately *not* seeded from the bulk snippet fetch on connect: that says
  // when we asked, not when the session moved. There is no activity history on
  // the wire to backfill from (`SessionSnapshot` carries `output_seq` and
  // `bytes_logged`, no timestamp), so a freshly connected row stays null until
  // it next moves, and the rail renders nothing rather than inventing a time.
  DateTime? snippetUpdatedAt;

  /// Explicit user override for tool-call auto-approval judging (null = inherit daemon default).
  bool? judgePolicyExplicit;
  /// Effective auto-approval judge policy (true = auto-approval enabled, false = manual approval).
  bool judgePolicyEffective = true;

  /// Whether DEC Mode 2004 (bracketed paste) is enabled by the active shell/application.
  bool bracketedPasteEnabled = false;

  void setBracketedPasteEnabled(bool enabled) {
    bracketedPasteEnabled = enabled;
    try {
      terminal.setBracketedPasteMode(enabled);
    } catch (_) {}
    TerminalPane.setBracketedPasteMode(title, enabled);
  }

  void applyJudgePolicy({
    required bool? explicit,
    required bool effective,
  }) {
    judgePolicyExplicit = explicit;
    judgePolicyEffective = effective;
  }

  /// Apply a freshly observed git context, updating the live fields and, when the
  /// context names a distinct linked worktree, refreshing the inferred-worktree
  /// memory the rail falls back to for a root/`main` row. The funnel for the two
  /// *live* context sources — the connect-time seed and `session_context_updated`
  /// pushes — so both feed the inference; the attach snapshot instead seeds it
  /// straight from the constructor.
  ///
  /// The seed carries no cwd, so it passes `updateCwd: false` to avoid clobbering
  /// a cwd a live push already set. `now` overrides the observation stamp for
  /// tests.
  void applyContext({
    required String? repoRoot,
    required String? worktreeRoot,
    required String? branch,
    String? cwd,
    bool updateCwd = true,
    DateTime? now,
  }) {
    this.repoRoot = repoRoot;
    this.worktreeRoot = worktreeRoot;
    this.branch = branch;
    if (updateCwd) this.cwd = cwd;
    _recordInferredWorktree(now: now);
  }

  /// Remember the current context as the session's inferred workstream when it
  /// names a distinct linked worktree — the same distinctness test the rail uses
  /// via [worktreeName]. A context with no distinct worktree — a root/`main`
  /// observation — leaves the memory untouched rather than clearing it, which is
  /// what lets the label survive the quiet gaps between `git -C worktrees/x`
  /// commands. The repo is pinned too, so [railTitleAt] can refuse to lend this
  /// workstream to a different repo's checkout.
  void _recordInferredWorktree({DateTime? now}) {
    if (worktreeName == null) return;
    _inferredRepoRoot = repoRoot;
    _inferredWorktreeRoot = worktreeRoot;
    final trimmed = branch?.trim();
    _inferredBranch = (trimmed != null && trimmed.isNotEmpty) ? trimmed : null;
    _inferredWorktreeAt = now ?? DateTime.now();
  }

  /// Last path segment of [repoRoot], for compact display (e.g. "triage").
  String? get repoName => leafOf(repoRoot);

  /// Last path segment of [worktreeRoot], for compact display. Null when it is
  /// the repo root itself (not a separate worktree) so the rail can hide it.
  String? get worktreeName {
    final wt = worktreeRoot;
    if (wt == null || wt.isEmpty || wt == repoRoot) return null;
    return leafOf(wt);
  }

  /// Returns [customLabel] trimmed if non-empty, or null.
  String? get trimmedCustomLabel {
    final trimmed = customLabel?.trim();
    return (trimmed != null && trimmed.isNotEmpty) ? trimmed : null;
  }

  /// Human-facing name for the rail/header, so sessions are identifiable at a
  /// glance instead of all reading "triage / session-NN". Prefers
  /// [customLabel] when assigned, then "repo · worktree", falls back to "repo · branch"
  /// when there is no distinct worktree, then the working-directory leaf, then the stable
  /// [title] (`triage / <id>`). Distinct from [title], which stays an identity key.
  String get displayTitle {
    final custom = trimmedCustomLabel;
    if (custom != null) return custom;
    final repo = repoName;
    if (repo != null) {
      final wt = worktreeName;
      if (wt != null) return '$repo · $wt';
      final b = branch;
      if (b != null && b.trim().isNotEmpty) return '$repo · ${b.trim()}';
      return repo;
    }
    final cwdLeaf = leafOf(cwd);
    if (cwdLeaf != null) return cwdLeaf;
    // No git context and no cwd: fall back to the stable title ("triage /
    // <id>") rather than a bare id, so a context-less session still reads
    // sensibly.
    return title;
  }

  /// How long the rail keeps leading a root/`main` row with the last worktree it
  /// was seen driving before reverting to the repo. Sessions drive a worktree
  /// from the primary checkout with `git -C worktrees/x …`, which the daemon only
  /// observes for the instant the command runs (see [railTitleAt]); this window
  /// makes that transient observation stick across the quiet gaps between
  /// commands, and expires it once the session genuinely stops touching the
  /// worktree. Long because these are long-lived agent sessions that revisit a
  /// worktree every few minutes while active. Not self-enforcing: the revert
  /// surfaces on the next rail rebuild (any output, selection, or activity tick),
  /// not via a dedicated timer.
  static const Duration stickyWorktreeTtl = Duration(minutes: 30);

  /// Rail-specific title, leading with the *workstream* rather than the repo.
  ///
  /// The rail's job is telling sibling sessions apart, and siblings share the
  /// repo — so leading with it, as [displayTitle] does, makes every row on one
  /// repo open with the same words and buries the part that differs mid-string.
  /// The repo moves to the meta line beneath (see `_SessionListTileState`).
  ///
  /// [displayTitle] keeps its repo-first form for the workspace header, where
  /// there is no sibling to disambiguate against and naming the repo is the
  /// point.
  String get railTitle => railTitleAt(DateTime.now());

  /// [railTitle] resolved against an explicit clock, so the [stickyWorktreeTtl]
  /// expiry of the inferred worktree is testable.
  ///
  /// Prefers an explicit [customLabel] if assigned.
  /// Otherwise, a row whose *live* context already names a workstream: a distinct current
  /// worktree, or any branch that isn't the default: uses it directly. Only a
  /// row that is inside a repo but reads as its root (no distinct worktree, and
  /// no branch or just `main`) would otherwise show the same uninformative word
  /// as every other root session, so it defers to the last worktree this session
  /// was seen driving in *this same repo*. The inference never overrides ground
  /// truth, and reverts once it goes stale.
  String railTitleAt(DateTime now) {
    final custom = trimmedCustomLabel;
    if (custom != null) return custom;
    final inferred = _activeInferredLead(now);
    if (inferred != null) return inferred;
    final b = branch?.trim();
    if (b != null && b.isNotEmpty) return b;
    // No branch: a detached HEAD, or a host too old to report one. The worktree
    // directory is the next most specific thing that still names the workstream.
    // Past this point there is no branch to promote, so displayTitle's own
    // fallbacks (repo, else cwd leaf, else the stable title) are already right
    // and are not worth restating.
    return worktreeName ?? displayTitle;
  }

  /// Repo-first name for the hover card and screen-reader label, following the
  /// same lead the rail shows: when an inferred worktree is leading the row it
  /// reads `repo · <worktree>`, so the visible line, the card heading, and the
  /// screen reader never disagree and two inferred rows stay distinguishable to
  /// assistive tech. Otherwise it is the plain [displayTitle]. The workspace
  /// header keeps its own [displayTitle]: only the rail's card/label follow the
  /// inference.
  String glanceTitleAt(DateTime now) {
    final custom = trimmedCustomLabel;
    if (custom != null) return custom;
    final inferred = _activeInferredLead(now);
    if (inferred != null) {
      final repo = repoName;
      // Match the rail line even in the degenerate case where the repo has no
      // displayable leaf, so the two never disagree within a frame.
      return repo != null ? '$repo · $inferred' : inferred;
    }
    return displayTitle;
  }

  /// The inferred worktree currently leading the row, or null when the live
  /// context names its own workstream — a distinct current worktree or a branch
  /// that isn't the default — so the inference stays out of the way, or when
  /// nothing fresh and in-repo applies. Shared by [railTitleAt] and
  /// [glanceTitleAt] so a row's title, card, and label move together.
  String? _activeInferredLead(DateTime now) {
    final b = branch?.trim();
    final liveIsUninformative =
        worktreeName == null &&
        repoRoot != null &&
        (b == null || b.isEmpty || _isDefaultBranch(b));
    if (!liveIsUninformative) return null;
    return _freshInferredWorktreeLabel(now);
  }

  /// The default branch of a primary checkout, which the user treats as
  /// synonymous with "the repo root" — leading a rail row with it says nothing
  /// the repo line doesn't. Matched by name because the client has no cheap way
  /// to ask git which branch is default.
  static bool _isDefaultBranch(String branch) {
    final b = branch.trim().toLowerCase();
    return b == 'main' || b == 'master';
  }

  /// Whether an inferred worktree observation is fresh and within the active repo.
  bool _isFreshInference(DateTime now) {
    final at = _inferredWorktreeAt;
    final root = _inferredWorktreeRoot;
    if (at == null || root == null) return false;
    if (_inferredRepoRoot != repoRoot) return false;
    if (now.difference(at) >= stickyWorktreeTtl) return false;
    return true;
  }

  /// The inferred-worktree lead — its branch (unless that is itself a default
  /// name, which says no more than the repo), else its directory leaf — but only
  /// while it is both fresh and still relevant. Null once [stickyWorktreeTtl] has
  /// elapsed with no new observation, or once the session has moved to a
  /// different repo than the worktree belonged to, so the row reverts to its live
  /// identity instead of advertising a stale or foreign workstream.
  String? _freshInferredWorktreeLabel(DateTime now) {
    if (!_isFreshInference(now)) return null;
    final root = _inferredWorktreeRoot;
    if (root == null) return null;
    final inferredBranch = _inferredBranch;
    if (inferredBranch != null && !_isDefaultBranch(inferredBranch)) {
      return inferredBranch;
    }
    return leafOf(root);
  }

  SessionSearchInput toSearchInput([DateTime? now]) {
    final targetTime = now ?? DateTime.now();
    final fresh = _isFreshInference(targetTime);
    return SessionSearchInput(
      title: title,
      displayTitle: displayTitle,
      railTitle: railTitleAt(targetTime),
      customLabel: customLabel,
      sessionId: remoteSessionId ?? sessionId,
      repoRoot: repoRoot,
      repoName: repoName,
      worktreeRoot: worktreeRoot,
      worktreeName: worktreeName,
      inferredWorktreeRoot: fresh ? _inferredWorktreeRoot : null,
      inferredBranch: fresh ? _inferredBranch : null,
      branch: branch,
      cwd: cwd,
      snippet: snippet,
      snippetDetail: snippetDetail,
    );
  }

  bool matchesSearch(
    String query, [
    DateTime? now,
    bool queryIsNormalized = false,
  ]) => toSearchInput(now).matchesQuery(
    query,
    queryIsNormalized: queryIsNormalized,
  );

  final String? sessionId;
  final IconData icon;
  // Plain visible rows kept for the test fallback view and demo seeding only;
  // real rendering goes through [store]/[terminal] from raw bytes.
  final List<StyledRow> rows;
  final TerminalController terminalController;
  final bool isRemote;
  bool isExited;
  // True once this remote session has been subscribed/attached (lazy-loaded).
  // Non-selected sessions stay unloaded until the user opens them.
  bool loaded = false;
  int focusCursorRevision = 0;
  int? lastFittedCols;
  int? lastFittedRows;
  // The size *this* device last fitted to, as distinct from `lastFittedCols`,
  // which also records sizes broadcast by the host after another device
  // resized. Keeping them apart is what lets a client regaining focus tell
  // "the PTY is already my size" from "another device has resized it since",
  // and so reclaim only when reclaiming would actually change something.
  int? ownFittedCols;
  int? ownFittedRows;
  // The PTY's actual size, as opposed to any size we would like it to be.
  // Written from the host's resize broadcast, from an attach snapshot that
  // reports one, and from a resize performed on the attach path (where the
  // response is not otherwise read back). Never from a fit alone, which is the
  // other half of the drift comparison: a local fit writing here would erase
  // the evidence that another device holds the size.
  //
  // The ordinary resize-out and the refit jiggle deliberately do not write
  // here; they are healed by the broadcast the daemon sends back, so this can
  // lag them by a round trip.
  int? hostSizeCols;
  int? hostSizeRows;

  /// Whether the shared PTY has drifted from the size this device last fitted
  /// to, meaning another client resized it while we were not asserting ours.
  ///
  /// False when either size is unknown: with nothing to compare, the quiet
  /// option is to leave the PTY alone.
  bool get hostSizeDriftedFromOwnFit {
    final ownCols = ownFittedCols;
    final ownRows = ownFittedRows;
    if (ownCols == null || ownRows == null) return false;
    final hostCols = hostSizeCols;
    final hostRows = hostSizeRows;
    if (hostCols == null || hostRows == null) return false;
    return hostCols != ownCols || hostRows != ownRows;
  }

  // Set once the view first reports its real fitted size after a fresh attach.
  // Gates the one-shot host re-sync to that size (see `_onSessionViewFit`).
  bool hasFitted = false;
  int? inFlightCols;
  int? inFlightRows;
  int resizeRequestSeq = 0;

  late final xt.Terminal terminal;
  // The single, ordered write path for all terminal output (live + history).
  // The sink wraps the controller, so both platform views render through their
  // existing listeners; decoding/buffering/CRLF/dedup all live in the store.
  late final TerminalStore store;
  void Function(int w, int h, int pw, int ph)? onTerminalResize;

  // Deferred history: replay must wait until the view is laid out and fitted, so
  // it re-emulates at the real terminal size. Writing before the first fit
  // renders at the default 80x24 and shows nothing until a resize refits.
  _PendingHistory? _pendingHistory;
  bool _viewReady = false;
  int _viewCols = 80;
  int _viewRows = 24;

  String? get remoteSessionId {
    if (sessionId != null && sessionId!.isNotEmpty) return sessionId;
    if (!isRemote) return null;
    final parts = title.split(' / ');
    if (parts.length > 1) return parts[1];
    if (title.startsWith('session-')) return title;
    return null;
  }

  /// Begin the attach/resync lifecycle and stage the raw output-history tail.
  /// [Attach] is dispatched now so live chunks buffer in arrival order; the
  /// actual [HistoryBytes] replay is deferred until the view reports its fitted
  /// size (see [noteViewFit]) and replays at that size — the host capture size
  /// is intentionally not used. Live chunks at or below [throughOutputSeq] are
  /// dropped by the store as duplicates.
  void applyHistory(List<int> rawOutput, {int? throughOutputSeq}) {
    _pendingHistory = _PendingHistory(rawOutput, throughOutputSeq);
    store.dispatch(const Attach());
    if (_viewReady) {
      _flushPendingHistory();
    }
  }

  /// The view fitted to a real grid size. Records it and replays any staged
  /// history at that size. Idempotent on subsequent fits (no staged history).
  void noteViewFit(int cols, int rows) {
    _viewCols = cols;
    _viewRows = rows;
    _viewReady = true;
    _flushPendingHistory();
  }

  void _flushPendingHistory() {
    final pending = _pendingHistory;
    if (pending == null) return;
    _pendingHistory = null;
    store.dispatch(
      HistoryBytes(
        pending.rawOutput,
        cols: _viewCols,
        rows: _viewRows,
        throughOutputSeq: pending.throughOutputSeq,
      ),
    );
  }

  /// Apply a live raw output chunk (remote PTY bytes) through the write path.
  void applyLiveBytes(List<int> bytes, {int? outputSeq}) {
    store.dispatch(LiveBytes(bytes, outputSeq: outputSeq));
  }

  /// Echo locally produced bytes for local/demo sessions (no remote PTY).
  void echoLocalBytes(List<int> bytes) {
    store.dispatch(LiveBytes(bytes));
  }

  void markExited() => store.dispatch(const Exited());

  void focusCursorOnNextDisplay() {
    focusCursorRevision += 1;
  }

  void dispose() {
    store.dispose();
    terminalController.dispose();
  }
}

/// Staged attach/resync history awaiting the view's first fit.
class _PendingHistory {
  const _PendingHistory(this.rawOutput, this.throughOutputSeq);

  final List<int> rawOutput;
  final int? throughOutputSeq;
}

class TriageHome extends StatefulWidget {
  const TriageHome({
    super.key,
    this.client,
    this.initialServers = ServerConfig.empty,
  });

  final TriageWebSocketClient? client;
  final ServerConfig initialServers;

  @override
  State<TriageHome> createState() => _TriageHomeState();
}

class _TriageHomeState extends State<TriageHome> with WidgetsBindingObserver {
  late TriageWebSocketClient _client;
  // Remote session ids currently being attached (lazy-load), so a repeated
  // select can't open a second subscription for the same session.
  final Set<String> _loadingSessionIds = {};
  // Marks the selected session's rail tile so reopening the rail can scroll it
  // to the top — the session you're in should be the first thing you see.
  final GlobalKey _selectedTileKey = GlobalKey();
  bool _clientInitialized = false;
  bool _isConnecting = false;
  bool _disposed = false;
  int _connectGeneration = 0;
  int _reconnectAttempt = 0;
  Timer? _reconnectTimer;
  // A connect was asked for while one was already in flight; replayed as soon
  // as that attempt settles. See `_connectWebSocket`.
  bool _reconnectRequested = false;
  Timer? _credentialStorageTimer;
  StreamSubscription<Map<String, dynamic>>? _websocketSubscription;
  String? _bearerToken;
  bool _storageBackedClientId = false;
  bool _needsPairing = false;
  bool _pairingChallengeLoading = false;
  String? _pairingDeviceCode;
  Uri? _pairingVerificationUri;
  // The `127.0.0.1:<port>/pair` URL to open on the daemon host, shown for a
  // remote daemon where `_pairingVerificationUri` (the clickable, loopback-only
  // one) is null.
  Uri? _pairingDaemonHostUri;
  DateTime? _pairingExpiresAt;
  String? _pairingChallengeError;
  bool _sidebarCollapsed = false;
  // The daemons this device knows about, and which one we are connected to.
  // Empty until a saved/entered server resolves (then the connection screen is
  // shown).
  List<DaemonServer> _servers = const [];
  String? _selectedServerId;
  // True when there is no daemon configured yet (first run, native) — render the
  // connection screen instead of auto-connecting.
  bool _needsConnectionConfig = false;
  String _connectionStatus = 'Offline (Local Mock)';
  Color _connectionStatusColor = const Color(0xff7f8b8d);
  late final String _clientId;
  final Map<String, String> _subscriptionIds = {};
  // Session ids with an in-flight snapshot refresh. A refresh clears and
  // re-emulates the terminal from history, so two concurrent refreshes for the
  // same session race and the second blanks the first (e.g. the select + first
  // view-fit refreshes that both fire on a session's initial load).
  final Set<String> _refreshInFlight = {};
  final Map<String, List<Map<String, dynamic>>> _pendingEvents = {};
  final Queue<Map<String, dynamic>> _websocketEventQueue = Queue();
  bool _websocketProcessingEvent = false;

  late final List<SessionVm> _sessions;
  int _selectedIndex = 0;
  // The rail's current grouping. Recomputed on the events that can actually
  // change it: a load or reconnect, a drag, a session created or closed, and a
  // session changing repository. Held in state rather than derived per build so
  // the rail does not rearrange under the user mid-session as background output
  // arrives: a freshly active group surfaces on the next load, not while they
  // are clicking.
  List<SessionGroup> _sessionGroups = const [];
  // Groups and sessions the user placed by hand, which hold their slot instead
  // of flowing with activity. Loaded per server alongside the session list.
  SessionPins _pins = SessionPins.none;
  // User-assigned custom labels for sessions, keyed by session id. Loaded per server.
  Map<String, String> _customLabels = {};
  // Reaches the rail list's state so a re-group can cancel a drag in progress
  // before it reorders the rows out from under it. See [_regroupRail].
  final GlobalKey<ReorderableListState> _railListKey =
      GlobalKey<ReorderableListState>();
  // The group whose header is being dragged right now, or null when no header
  // drag is in flight. Drives the rail's "these rows are coming too" treatment.
  //
  // Held here rather than inside [SessionRail] because clearing it is the same
  // invariant as cancelling the drag, and [_regroupRail] is what cancels. A copy
  // living in the rail could not be reached from there, so a re-group arriving
  // mid-drag (a session created or closed, a load or reconnect, a session
  // changing repository) would leave it set over a drag the list had already
  // killed, dimming a group until the next one.
  String? _draggingRailGroup;
  // Set when the daemon could not supply session contexts, which leaves every
  // session in one repo-less group. On its own that is not enough to reject a
  // drag: see [_railGroupingIsCollapsed], which pairs it with what the rail is
  // actually showing.
  bool _railGroupingDegraded = false;
  // The daemon the sessions currently in the rail came from. Null while none are
  // loaded, or while a switch is in flight and the tiles still belong to the
  // daemon we are leaving — their ids mean nothing to the one we are joining.
  String? _sessionsServerId;
  int _createdSessionCount = 0;
  late NewSessionShell _newSessionShell;

  SessionVm get _selectedSession => _sessions[_selectedIndex];

  /// The daemon we are pointed at, or null when none is configured (first run)
  /// or when a test injects a client and bypasses server configuration.
  DaemonServer? get _activeServer {
    for (final server in _servers) {
      if (server.id == _selectedServerId) return server;
    }
    return null;
  }

  /// The id the active daemon's per-server state — its pairing token and its
  /// rail order — is stored under. Both are issued/owned per daemon, so every
  /// read/write of them goes through this rather than a single global key.
  String get _activeServerId => _activeServer?.id ?? unconfiguredServerId;

  /// The daemon to connect to. Falls back to the page origin, which is right for
  /// the injected-client test path and for a web client whose origin server has
  /// not been synthesized yet.
  Uri get _activeDaemonUri {
    final address = _activeServer?.address;
    if (address != null) {
      final uri = parseDaemonAddress(address);
      if (uri != null) return uri;
    }
    return _defaultWebSocketUri();
  }

  StyledRow _plainRow(String text) {
    return StyledRow(
      spans: [StyledSpan(text: text, style: const TerminalStyle())],
    );
  }

  /// Flattens demo/local placeholder rows into plain CRLF-terminated bytes for
  /// seeding a session's store (styling is dropped — these are placeholders).
  List<int> _seedBytesFromRows(List<StyledRow> rows) {
    final text = rows
        .map((row) => row.spans.map((span) => span.text).join())
        .join('\r\n');
    return utf8.encode(text);
  }

  StyledRow _promptRow(String command) {
    return StyledRow(
      spans: [
        const StyledSpan(
          text: r'$ ',
          style: TerminalStyle(
            foreground: TerminalColor(red: 127, green: 209, blue: 199),
            bold: true,
          ),
        ),
        StyledSpan(text: command, style: const TerminalStyle(bold: true)),
      ],
    );
  }

  // True while the app is occluded (screen sleep / hidden / backgrounded). Gates
  // the resume redraw so we only repaint after genuine occlusion, not on every
  // desktop focus change.
  bool _wasOccluded = false;
  // Whether this client is the one the user is actually looking at, and so the
  // one allowed to size the shared PTY. Starts true: a client that never sees a
  // lifecycle event (tests, and any platform that does not report one) must
  // behave exactly as it did before this existed.
  bool _clientForeground = true;

  // Wall-clock watchdog for system sleep. macOS does not background a running app
  // on display/system sleep, so the lifecycle hook may never fire — but the
  // process IS frozen during system sleep, which stalls this periodic timer. A
  // tick that arrives far later than its interval means we just woke; redraw then.
  Timer? _wakeWatchdogTimer;
  DateTime _lastWatchdogTick = DateTime.now();
  static const Duration _wakeWatchdogInterval = Duration(seconds: 4);
  static const Duration _wakeWatchdogGap = Duration(seconds: 30);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Resolve the active server before anything that keys off it — the rail
    // order below is stored per server.
    _servers = List.of(widget.initialServers.servers);
    _selectedServerId = widget.initialServers.selectedId;
    // Prime this server's pins and custom labels in the background; the load path
    // reads the cache synchronously rather than awaiting prefs.
    unawaited(_restorePins());
    unawaited(_restoreCustomLabels());
    _lastWatchdogTick = DateTime.now();
    _wakeWatchdogTimer = Timer.periodic(_wakeWatchdogInterval, (_) {
      final now = DateTime.now();
      final gap = now.difference(_lastWatchdogTick);
      _lastWatchdogTick = now;
      if (gap > _wakeWatchdogGap) {
        // Same as the resume path: don't wait out the accrued backoff after a
        // sleep/wake that never delivered a lifecycle event.
        _reconnectNowOnResume();
        _refitActiveSession();
        _refocusActiveSession();
      }
    });
    _clientId = _loadOrCreateClientId();
    _startCredentialStorageWatcher();
    _newSessionShell = newSessionShellMenuOrderForPlatform(
      defaultTargetPlatform,
    ).first;
    _sessions = [
      SessionVm(
        title: 'triage / flutter-spike',
        branch: 'experiment/flutter-spike',
        status: 'awaiting input',
        statusColor: const Color(0xffffc857),
        icon: Icons.terminal,
        rows: [
          _promptRow('cargo run -p triaged'),
          _plainRow('daemon listening on local session transport'),
          _plainRow(''),
          _promptRow('flutter run -d web-server --no-web-resources-cdn'),
          _plainRow('lib/main.dart is being served at http://127.0.0.1:8080'),
          _plainRow(''),
          _plainRow('awaiting input: define TerminalPane bridge boundary'),
        ],
      ),
      SessionVm(
        title: 'triage / websocket-session-api',
        branch: 'feat/websocket-session-api',
        status: 'running cargo test',
        statusColor: const Color(0xff7fd1c7),
        icon: Icons.sync,
        rows: [
          _promptRow('cargo test -p triage-transport-ws'),
          _plainRow('test protocol::tests::subscribe_streams_events ... ok'),
          _plainRow('test protocol::tests::invalid_json_returns_error ... ok'),
          _plainRow(''),
          _plainRow('running: websocket integration notes'),
        ],
      ),
      SessionVm(
        title: 'triage / main',
        branch: 'main',
        status: 'idle',
        statusColor: const Color(0xff7f8b8d),
        icon: Icons.pause_circle_outline,
        rows: [
          _promptRow('git status --short --branch'),
          _plainRow('## main...origin/main'),
          _plainRow(''),
          _plainRow('idle'),
        ],
      ),
    ];
    for (final s in _sessions) {
      _setupSessionInputListener(s);
      // Seed the demo/local sessions into the store's live phase so their
      // placeholder content renders and local echo works through one pipeline.
      s.applyHistory(_seedBytesFromRows(s.rows));
    }
    final isMockMode = Uri.base.queryParameters['mock'] == 'true';
    if (!isMockMode && widget.client == null && kIsWeb) {
      // A server entry adopted from an earlier page origin (before this client
      // moved behind a reverse proxy, say) is still selected and would
      // short-circuit the checks below, dialing the dead origin forever. Repoint
      // it at the current origin — carrying its token — so the same-origin
      // default reaches already-loaded users, not just clean installs.
      final (reconciled, staleServerId) = reconcileWebOriginSelection(
        ServerConfig(servers: _servers, selectedId: _selectedServerId),
        webOriginServer(_defaultWebSocketUri()),
      );
      if (staleServerId != null) {
        final originId = reconciled.selectedId!;
        _servers = reconciled.servers;
        _selectedServerId = originId;
        unawaited(
          saveServers(_servers, selectedId: originId).then((saved) {
            // Retire the stale entry's per-server state only once the swap is
            // durably stored; a failed save leaves it for the next launch to
            // re-reconcile. The pins follow the daemon (best-effort) and are
            // then re-read, so this session keeps the layout it had.
            if (!saved) return;
            clearTokenFor(staleServerId);
            // Re-read after the move: `_restorePins` has already run for this
            // launch and found nothing under the new id, so without this the
            // session carries empty pins and the first drag persists a
            // one-entry list over everything just migrated.
            unawaited(
              migrateRailPins(staleServerId, originId).then((_) async {
                if (_disposed || _activeServerId != originId) return;
                await _restorePins();
                await _restoreCustomLabels();
              }),
            );
          }),
        );
      }
    }
    if (isMockMode) {
      _connectionStatus = 'Offline (Local Mock)';
      _connectionStatusColor = const Color(0xff7f8b8d);
    } else if (widget.client != null) {
      // Injected client (tests) connects directly, bypassing address config.
      _connectWebSocket();
    } else if (_activeServer != null) {
      _connectWebSocket();
    } else if (kIsWeb) {
      // The web client is served by a daemon, so adopt the page origin as a
      // server rather than asking which host to connect to.
      final origin = webOriginServer(_defaultWebSocketUri());
      // A web user upgrading from the single-server build is already paired with
      // this very daemon, but never had a daemon address stored — the page
      // origin was it — so loadServers' migration, which keys off that address,
      // never sees them. Copy their credential here instead, or every existing
      // web user is silently un-paired by this change. Synchronous, so the
      // connect below already sees the token.
      final copiedToken = copyLegacyTokenTo(origin.id);
      _servers = [..._servers, origin];
      _selectedServerId = origin.id;
      unawaited(
        saveServers(_servers, selectedId: _selectedServerId).then((saved) {
          // Retire the legacy token only once the origin entry is persisted; a
          // failed save leaves it so the next load re-adopts it. The copy already
          // lives under the stable origin id, so connect isn't blocked meanwhile.
          if (saved && copiedToken) clearLegacyToken();
        }),
      );
      unawaited(purgeRetiredSessionOrder(origin.id));
      // Re-read the pins under the id just adopted. `initState`'s
      // `_restorePins` captured the pre-adopt id and bails on its own re-check,
      // so without this the session runs with empty pins and the first drag
      // persists a one-entry list over the stored layout, the same hazard the
      // stale-origin reconcile path above guards against. Reachable whenever a
      // previous launch's `saveServers` did not land, which is exactly when
      // there are already pins stored under this id.
      unawaited(_restorePins());
      unawaited(_restoreCustomLabels());
      _connectWebSocket();
    } else {
      // First run on native: no daemon yet, so ask for one instead of dialing a
      // host we're only guessing at.
      _needsConnectionConfig = true;
      _connectionStatus = 'Not connected';
    }
  }

  /// Adds a daemon and connects to it. Called from the first-run connection
  /// screen and from "Add server".
  Future<void> _addServer(String rawAddress, {String? label}) async {
    final trimmed = rawAddress.trim();
    if (parseDaemonAddress(trimmed) == null) return;
    final named = label?.trim();
    final server = DaemonServer(
      id: newServerId(),
      label: (named == null || named.isEmpty)
          ? DaemonServer.defaultLabelFor(trimmed)
          : named,
      address: trimmed,
    );
    // Apply to state before any await. Computing the new list, awaiting, and
    // only then assigning would let a removal land in the gap and be silently
    // undone by this stale snapshot.
    setState(() => _servers = [..._servers, server]);
    await _selectServer(server.id);
  }

  /// Switches to another daemon.
  ///
  /// This is the same teardown-and-reconnect an address change already did, so
  /// it routes through [_connectWebSocket] rather than growing a parallel path:
  /// that bumps the connect generation, disconnects the old client, and — via
  /// the replay flag — handles a switch requested while a connect is in flight.
  Future<void> _selectServer(String serverId) async {
    if (_disposed) return;
    if (!_servers.any((server) => server.id == serverId)) return;

    await saveServers(_servers, selectedId: serverId);
    if (!mounted) return;

    // Drop the outgoing daemon's socket *before* touching any of its state. While
    // it is still subscribed it keeps delivering events, and those would
    // re-populate the very buffers the purge below exists to clear. Tearing down
    // also bumps the connect generation, which retires any in-flight attempt and
    // any in-flight session load belonging to that daemon.
    await _teardownConnection();
    if (_disposed) return;

    setState(() {
      _selectedServerId = serverId;
      _needsConnectionConfig = false;
      _needsPairing = false;
      _reconnectAttempt = 0;
    });

    _purgeDaemonLocalState();
    // The purge cleared the in-memory pins; reload this server's before
    // connecting, or the first load after a switch would come up unpinned and a
    // later drag would then overwrite the good stored pins.
    await _restorePins();
    await _restoreCustomLabels();
    if (_disposed) return;
    unawaited(_connectWebSocket());
  }

  /// Drops everything keyed by a daemon-local identifier.
  ///
  /// Session ids — and the titles built from them — are only unique *within* one
  /// daemon: two of them routinely both have a session called `main`. So every
  /// cache keyed by one is meaningless, and actively dangerous, once we point at
  /// a different daemon. Carrying the pending-event buffers across would replay
  /// one machine's output into the other's terminal; carrying the cached panes
  /// would show the outgoing daemon's scrollback under the incoming daemon's
  /// session of the same name.
  void _purgeDaemonLocalState() {
    setState(() {
      // Retire the outgoing daemon's tiles outright rather than leaving them on
      // screen until the new list lands. They are still marked `attached` and
      // still wired to `_client`, which is about to point at a different daemon —
      // so a keystroke or a resize in that window would be delivered to the *new*
      // daemon under an *old* daemon's session id. The ids collide by
      // construction (both machines have a `main`), so it would land on a real,
      // unrelated session. None of this is salvageable; the new list rebuilds it.
      for (final session in _sessions) {
        session.terminalController.dispose();
        TerminalPane.destroySession(session.title);
      }
      _sessions.clear();
      _selectedIndex = 0;
    });
    _pendingEvents.clear();
    _websocketEventQueue.clear();
    _subscriptionIds.clear();
    _refreshInFlight.clear();
    _loadingSessionIds.clear();
    _sessionsServerId = null;
    _sessionGroups = const [];
    // Pins are per server and reload with the next session list; keeping the
    // outgoing daemon's would briefly pin the incoming daemon's rail by paths
    // and ids that mean nothing on that machine.
    _pins = SessionPins.none;
    _customLabels = {};
  }

  /// Renames a daemon or re-points it at a new address.
  ///
  /// The token is deliberately kept: it is stored under the server's id, not its
  /// address, so a host that merely moved (a new DHCP lease, LAN → Tailscale)
  /// reconnects without a re-pair. Re-pointing the entry at a genuinely
  /// different daemon instead yields a rejected token, which already routes to
  /// pairing on its own.
  Future<void> _updateServer(DaemonServer updated) async {
    final index = _servers.indexWhere((server) => server.id == updated.id);
    if (index == -1) return;
    final previous = _servers[index];
    final servers = [..._servers]..[index] = updated;
    // Apply to state before the await, for the same reason as _addServer: a
    // removal landing during the save would otherwise be undone by this stale
    // snapshot, resurrecting a daemon whose token has already been cleared.
    setState(() => _servers = servers);
    await saveServers(servers, selectedId: _selectedServerId);
    if (!mounted) return;

    final isActive = updated.id == _selectedServerId;
    if (isActive && updated.address != previous.address) {
      // A new address may well be a different machine. The id is unchanged, so
      // nothing downstream would notice on its own — `_sessionsServerId` still
      // matches and the old daemon's panes, buffers and rail order would all be
      // reused for the new host. Tear down and purge exactly as a switch does.
      await _teardownConnection();
      if (_disposed) return;
      setState(() {
        _reconnectAttempt = 0;
        // A pairing challenge belongs to the daemon that issued it, and we are
        // now dialing a different address. Drop it rather than leave a dead PIN
        // prompt in front of the reconnect.
        _needsPairing = false;
      });
      _purgeDaemonLocalState();
      // Same reason as _selectServer: the purge cleared the in-memory pins and
      // this server's id is unchanged, so reload them before reconnecting.
      await _restorePins();
      await _restoreCustomLabels();
      if (_disposed) return;
      unawaited(_connectWebSocket());
    }
  }

  /// Forgets a daemon, including its pairing token and rail order — the entry is
  /// the only thing that names them, so leaving them behind would strand a live
  /// bearer token in the keychain under an id nothing can reach.
  Future<void> _removeServer(String serverId) async {
    if (!_servers.any((server) => server.id == serverId)) return;
    final servers = _servers.where((server) => server.id != serverId).toList();
    final wasActive = serverId == _selectedServerId;
    final nextId = wasActive
        ? (servers.isEmpty ? null : servers.first.id)
        : _selectedServerId;

    // Apply to state before the awaits, as _addServer and _updateServer do: an
    // add landing during the save would otherwise be dropped by this stale
    // snapshot when it is assigned afterwards.
    setState(() => _servers = servers);
    clearTokenFor(serverId);
    await purgeRetiredSessionOrder(serverId);
    await _clearPinsFor(serverId);
    await saveServers(servers, selectedId: nextId);
    if (!mounted) return;

    if (!wasActive) return;
    if (nextId != null) {
      await _selectServer(nextId);
      return;
    }
    // Nothing left to connect to — fall back to the first-run screen rather than
    // leaving the user on a rail attached to a daemon they just forgot.
    await _teardownConnection();
    if (!mounted) return;
    // Drop the forgotten daemon's tiles, buffers, and _sessionsServerId, as
    // every other teardown path does. Skipping it here leaks the undisposed
    // terminal controllers and leaves stale daemon-local state behind the
    // connection screen until the next switch happens to purge it.
    _purgeDaemonLocalState();
    setState(() {
      _selectedServerId = null;
      _needsPairing = false;
      _needsConnectionConfig = true;
      _connectionStatus = 'Not connected';
      _connectionStatusColor = const Color(0xff7f8b8d);
    });
  }

  /// Drops the live connection without scheduling a reconnect. Bumping the
  /// generation is what stops one: an in-flight attempt sees it and bails.
  Future<void> _teardownConnection() async {
    _connectGeneration++;
    _isConnecting = false;
    _reconnectRequested = false;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    final subscription = _websocketSubscription;
    _websocketSubscription = null;
    try {
      // Bounded, like the connect path's cancel: a cancel that never completes
      // would strand this teardown, and everything waiting on it — including the
      // fall back to the connection screen — never runs.
      await subscription?.cancel().timeout(const Duration(milliseconds: 250));
    } catch (_) {}
    if (_clientInitialized) {
      try {
        await _client.disconnect();
      } catch (_) {}
    }
    // Retire the client too. The resume and wake paths reconnect on the strength
    // of `_clientInitialized` alone, so leaving it set after forgetting the last
    // daemon would have them dial the page-origin fallback — a localhost daemon
    // the user never configured — from behind the connection screen.
    _clientInitialized = false;
    _bearerToken = null;
  }

  /// Opens the server manager (gear icon / connect-failure action).
  Future<void> _openConnectionSettings({SettingsTab initialTab = SettingsTab.daemons}) async {
    final selected = (_selectedIndex >= 0 && _selectedIndex < _sessions.length)
        ? _sessions[_selectedIndex]
        : null;
    final workspacePath = selected?.repoRoot ?? selected?.worktreeRoot ?? selected?.cwd;
    await showDialog<void>(
      context: context,
      builder: (context) => SettingsDialog(
        client: _client,
        workspacePath: workspacePath,
        servers: _servers,
        selectedId: _selectedServerId,
        clientId: _clientId,
        initialTab: initialTab,
        onSelect: _selectServer,
        onAdd: (address, label) => _addServer(address, label: label),
        onUpdate: _updateServer,
        onRemove: _removeServer,
      ),
    );
  }

  // After waking from sleep / un-hiding, the active terminal's buffer is wrapped
  // for a host PTY width that drifted from our view width, so the frame fragments
  // (words split mid-token, lines re-wrapped narrow). A manual resize fixes it
  // because it forces the host program to repaint over the live byte stream at
  // our width. Reproduce that on resume. Gated on prior occlusion so we don't
  // do it on every desktop focus change.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    final wasForeground = _clientForeground;
    _clientForeground = foregroundForLifecycle(state);
    switch (state) {
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
        _wasOccluded = true;
        break;
      case AppLifecycleState.resumed:
        final regainedFocus = !wasForeground;
        if (_wasOccluded) {
          _wasOccluded = false;
          // The lifecycle event handles this wake; reset the watchdog baseline so
          // its next tick doesn't also see the sleep gap and heal a second time.
          _lastWatchdogTick = DateTime.now();
          // Reattach at once instead of waiting out the reconnect backoff that
          // accrued while we were backgrounded.
          _reconnectNowOnResume();
          _refitActiveSession();
          _refocusActiveSession();
        } else if (regainedFocus) {
          // Focused again without having been occluded: a desktop window that
          // was merely behind another, or a browser tab that lost focus. The
          // occlusion path above always refits; this one only does so when the
          // PTY has actually drifted from this device's size, since the refit
          // deliberately jiggles the host to force a repaint and doing that on
          // every alt-tab would be its own kind of churn.
          _reclaimTerminalSizeIfDrifted();
        }
        break;
      case AppLifecycleState.inactive:
      case AppLifecycleState.detached:
        // `foregroundForLifecycle` has already stopped us asserting a size.
        // Neither counts as occluded, so the reconnect/refocus work above stays
        // tied to real backgrounding.
        break;
    }
  }

  /// Re-assert this device's terminal size when another device has resized the
  /// shared PTY since we last fitted. No-op when the PTY already matches, so
  /// regaining focus is free in the common single-device case.
  void _reclaimTerminalSizeIfDrifted() {
    if (_disposed || _sessions.isEmpty) return;
    if (_selectedIndex < 0 || _selectedIndex >= _sessions.length) return;
    if (!_selectedSession.hostSizeDriftedFromOwnFit) return;
    // Refit and refocus together, through the shared helper so this keeps its
    // carve-out: on mobile the refocus raises the soft keyboard, which insets
    // the Scaffold, shrinks the viewport and fires another fit at the smaller
    // size, which on this path would push that shrunken size onto the shared
    // PTY. Desktop needs the refocus, since a refit alone leaves the terminal
    // ignoring input until the session is switched away from and back.
    _refitAndFocusActiveSession();
  }

  // Re-fit this device's terminal to its real size and re-assert it on the
  // shared PTY, forcing a repaint. Called on resume-from-occlusion and from the
  // header "refit" button, so a user switching between devices (each with its
  // own width) can reclaim the PTY for the device they are now on.
  //
  // The re-fit is delegated to the pane via `controller.refit()` because only
  // the pane knows the true render grid. On web that is the xterm.js FitAddon
  // size; `session.terminal` is a Dart-side shadow that does not track it, so
  // reading its `viewWidth` here (as this used to) re-asserted a stale, often
  // too-narrow width on resume. The web pane re-fits from real pixels and
  // force-sends the result to the host itself, so we stop here on web.
  //
  // On native `TerminalView` auto-fits `session.terminal`, so its `viewWidth`
  // *is* authoritative; the pane registers no refit listener and this jiggles
  // the host to it. `lastFittedCols` is deliberately not used — it is polluted
  // by host-size broadcasts from other devices on a shared PTY. A same-size
  // resize sends no SIGWINCH, so the jiggle (one row shorter, then back)
  // guarantees a repaint over the live stream. History is deliberately not
  // replayed: re-emulating the raw-output tail re-introduces the
  // width-mismatched frame.
  void _refitActiveSession() {
    // `_client` is `late` and only assigned by _connectWebSocket; in mock mode it
    // is never set, so guard on _clientInitialized before touching it.
    if (_disposed || !_clientInitialized || _sessions.isEmpty) return;
    if (!_client.isConnected) return;
    if (_selectedIndex < 0 || _selectedIndex >= _sessions.length) return;
    final session = _selectedSession;
    if (!session.isRemote || session.status != 'attached') return;
    final sessionId = _sessionIdFor(session);
    if (sessionId == null) return;

    // The pane owns the re-fit. On web this is the whole operation; running the
    // native jiggle below afterward would nudge the host straight back to the
    // stale shadow width.
    session.terminalController.refit();
    if (kIsWeb) return;

    final cols = session.terminal.viewWidth;
    final rows = session.terminal.viewHeight;
    if (cols < 2 || rows < 2) return;
    unawaited(() async {
      try {
        await _client.resizeSession(
          sessionId: sessionId,
          cols: cols,
          rows: rows - 1,
        );
        if (_disposed) return;
        await _client.resizeSession(
          sessionId: sessionId,
          cols: cols,
          rows: rows,
        );
      } catch (_) {}
    }());
  }

  // Refit and reclaim focus together — what the header "refit" button runs.
  //
  // The button is pressed precisely when a session is misbehaving, and a refit
  // alone leaves the terminal correctly sized but unfocused, so the user has to
  // click into the pane before they can type.
  //
  // Not on mobile, though: there the terminal takes IME input
  // (`hardwareKeyboardOnly: false`), so requesting focus raises the soft
  // keyboard, which insets the Scaffold, shrinks the viewport and fires another
  // fit at the smaller size — undoing the resize the user just asked for. That
  // viewport jump is the same one #105 fixed for scroll swipes, and it would be
  // worst on the one control whose whole purpose is sizing.
  void _refitAndFocusActiveSession() {
    _refitActiveSession();
    if (!isMobilePlatform()) _refocusActiveSession();
  }

  // Resuming from sleep/occlusion drops the terminal's keyboard focus, so the
  // active session silently ignores input until the user switches sessions and
  // back. Re-request focus here through the same channel that the session
  // switch uses: bumping the session's focus revision makes the pane refocus on
  // its next rebuild (honored by both the native and web panes). Kept separate
  // from the resize-heal so it also covers local / not-yet-attached sessions,
  // which that path intentionally skips. Also used by the refit button, via
  // _refitAndFocusActiveSession.
  void _refocusActiveSession() {
    if (_disposed || !mounted || _sessions.isEmpty) return;
    if (_selectedIndex < 0 || _selectedIndex >= _sessions.length) return;
    setState(() {
      _selectedSession.focusCursorOnNextDisplay();
    });
  }

  String _loadOrCreateClientId() {
    final storedClientId = retrieveClientId();
    if (storedClientId != null && storedClientId.trim().isNotEmpty) {
      _storageBackedClientId = true;
      return storedClientId;
    }

    final random = Random.secure();
    final suffix = List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    final clientId = 'triage-flutter-client-$suffix';
    persistClientId(clientId);
    _storageBackedClientId = retrieveClientId() == clientId;
    return clientId;
  }

  void _refreshBearerTokenFromStorage() {
    final storedClientId = retrieveClientId();
    final storedToken = retrieveTokenFor(_activeServerId);
    if (!_storageBackedClientId) {
      if (storedClientId == _clientId) {
        _storageBackedClientId = true;
      }
      if (storedToken?.trim().isNotEmpty == true) {
        _bearerToken = storedToken;
      }
      return;
    }

    if (storedClientId == null || storedClientId.trim().isEmpty) {
      _bearerToken = null;
      persistClientId(_clientId);
      _storageBackedClientId = retrieveClientId() == _clientId;
      return;
    }
    if (storedClientId != _clientId) {
      _bearerToken = null;
      return;
    }
    _bearerToken = storedToken?.trim().isEmpty == false ? storedToken : null;
  }

  void _startCredentialStorageWatcher() {
    _credentialStorageTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      _checkCredentialStorageStillMatches();
    });
  }

  void _checkCredentialStorageStillMatches() {
    if (_disposed ||
        !_storageBackedClientId ||
        !_clientInitialized ||
        !_client.isConnected ||
        _needsPairing ||
        _bearerToken == null) {
      return;
    }

    if (retrieveClientId() == _clientId &&
        retrieveTokenFor(_activeServerId) == _bearerToken) {
      return;
    }

    _bearerToken = null;
    _reconnectAttempt = 0;
    unawaited(_connectWebSocket(isReconnect: true));
  }

  Uri _defaultWebSocketUri() {
    return defaultWebSocketUriForBase(Uri.base);
  }

  Uri? _verificationUriForClient(
    TriageWebSocketClient client, {
    String? deviceCode,
  }) {
    final wsUri = client.uri;
    if (!_isLoopbackHost(wsUri.host)) {
      return null;
    }

    final scheme = wsUri.scheme == 'wss' ? 'https' : 'http';
    final verificationUri = wsUri.replace(
      scheme: scheme,
      path: '/pair',
      query: '',
      fragment: '',
    );
    if (deviceCode == null || deviceCode.trim().isEmpty) {
      return verificationUri;
    }
    return verificationUri.replace(
      queryParameters: {'device_code': deviceCode},
    );
  }

  /// The URL to open *on the machine running triaged* to approve pairing, shown
  /// even for a remote daemon (where [_verificationUriForClient] is null because
  /// clicking it here would hit this client's own loopback).
  ///
  /// Always the fixed loopback literal `127.0.0.1:<port>` — never the daemon's
  /// claimed host. `/pair` only authorizes a same-host request, so loopback *is*
  /// the address to use on the daemon box; and echoing the claimed host would
  /// render an attacker-influenced name (e.g. `127.0.0.1.evil.com`) as a
  /// pairing URL carrying the device code. The device code is the daemon-issued
  /// challenge already on screen.
  ///
  /// Returns null when the connection carries no explicit port (e.g. a
  /// `wss://host/ws` reverse proxy on the default 443): the daemon's real
  /// loopback listen port is unknowable from here, so any port we printed would
  /// be the proxy's public port, not the daemon's. Callers fall back to generic
  /// guidance rather than show a URL that won't resolve on the daemon box. Only
  /// the port the user actually typed to connect is trustworthy enough to render.
  Uri? _daemonHostPairingUri(
    TriageWebSocketClient client, {
    String? deviceCode,
  }) {
    final wsUri = client.uri;
    if (!wsUri.hasPort) {
      return null;
    }
    final scheme = wsUri.scheme == 'wss' ? 'https' : 'http';
    final base = Uri(
      scheme: scheme,
      host: '127.0.0.1',
      port: wsUri.port,
      path: '/pair',
    );
    if (deviceCode == null || deviceCode.trim().isEmpty) {
      return base;
    }
    return base.replace(queryParameters: {'device_code': deviceCode});
  }

  bool _isRemoteSession(SessionVm session) {
    return session.isRemote;
  }

  void _markRemoteSessionDisconnected(SessionVm session) {
    if (session.status == 'disconnected') return;
    setState(() {
      session.status = 'disconnected';
      session.statusColor = const Color(0xffff6b6b);
      _connectionStatus = 'Connection Closed';
      _connectionStatusColor = const Color(0xff7f8b8d);
    });
  }

  void _markAttachedSessionsDisconnected() {
    for (final session in _sessions) {
      if (session.status == 'attached') {
        session.status = 'disconnected';
        session.statusColor = const Color(0xffff6b6b);
      }
    }
  }

  void _setupSessionInputListener(SessionVm session) {
    session.terminalController.addInputListener((keys) {
      // While the store replays history or when the emulator auto-answers terminal
      // queries (DSR, DA, Kitty queries), those answers surface here as emulator
      // output; they must not be forwarded to the host as fake user input.
      if (session.store.isSuppressingHostInput ||
          session.store.isWritingSink ||
          isEmulatorQueryResponse(keys)) {
        return;
      }
      if (_isRemoteSession(session)) {
        if (session.status != 'attached') {
          return;
        }

        if (!_client.isConnected) {
          _markRemoteSessionDisconnected(session);
          return;
        }

        final sessionId = session.remoteSessionId;
        if (sessionId != null) {
          _client
              .writeInput(
                sessionId: sessionId,
                clientId: _clientId,
                bytes: utf8.encode(keys),
              )
              .catchError((_) {
                _markRemoteSessionDisconnected(session);
              });
        }
      } else {
        // Local/demo session: echo keystrokes through the same single write
        // path the remote stream uses, so there is one rendering pipeline.
        if (keys == '\r') {
          session.echoLocalBytes(const [0x0d, 0x0a]); // CR LF
        } else if (keys == '\x7f' || keys == '\x08') {
          session.echoLocalBytes(const [0x08, 0x20, 0x08]); // backspace-erase
        } else {
          session.echoLocalBytes(utf8.encode(keys));
        }
      }
    });

    session.terminalController.addResizeOutListener((cols, rows) {
      // This device's own fit, recorded whether or not it is forwarded below,
      // so the reclaim on regaining focus knows what size to compare against.
      session.ownFittedCols = cols;
      session.ownFittedRows = rows;
      // A backgrounded client does not get to resize the PTY. Several clients
      // of different widths each asserting their own turns the shared PTY into
      // a tug of war: every change makes a full-screen program repaint, and
      // because the previous frame occupied a different number of rows the new
      // one lands beside it rather than over it, so the scrollback fills with
      // the same text at several widths. The foreground client owns the size;
      // the rest go quiet and reclaim when focused (see the lifecycle handler).
      // Bookkeeping first: this is the only maintainer of `lastFitted*` for an
      // ordinary grid resize on web, and it feeds the replay size. Skipping it
      // with the send would leave a stale size to replay history at.
      session.lastFittedCols = cols;
      session.lastFittedRows = rows;
      if (!_clientForeground) {
        return;
      }
      // `_client` is `late`: on the first-run and mock paths nothing has
      // connected yet, and xterm fires this on its very first layout.
      if (_clientInitialized &&
          _client.isConnected &&
          session.status == 'attached') {
        final sessionId = session.remoteSessionId;
        if (sessionId != null) {
          ++session.resizeRequestSeq;
          // Tell the host its new PTY size; the program repaints and the live
          // byte stream self-heals the view. No history replay on resize.
          unawaited(() async {
            try {
              await _client.resizeSession(
                sessionId: sessionId,
                cols: cols,
                rows: rows,
              );
            } catch (_) {}
          }());
        }
      }
    });
  }

  Duration _nextReconnectDelay() {
    final seconds = 1 << _reconnectAttempt.clamp(0, 4);
    _reconnectAttempt += 1;
    return Duration(seconds: seconds);
  }

  /// Reconnect immediately when the app comes back to the foreground.
  ///
  /// Backgrounding drops the socket, and `_scheduleReconnect` then sits on an
  /// exponential backoff (1, 2, 4, 8, 16s). Without this, returning to the app
  /// waits out whatever delay had accrued while we were away — which is what
  /// made re-attaching take seconds even on a fast network. A user-initiated
  /// resume is a fresh start, not a failed retry, so the attempt counter resets.
  void _reconnectNowOnResume() {
    if (_disposed || !_clientInitialized || _client.isConnected) return;
    if (_isConnecting) {
      // A connect is already racing; let it finish rather than tearing it down.
      // Still clear the accrued backoff, so that if it fails we retry at once
      // instead of waiting out a delay that piled up while the app was away —
      // dropping the resume outright is what left it stalling for seconds.
      _reconnectAttempt = 0;
      return;
    }
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _reconnectAttempt = 0;
    unawaited(_connectWebSocket(isReconnect: true));
  }

  /// [afterFailedAttempt] when the caller has just *seen* a connect fail. The
  /// pairing guard below assumes `_needsPairing` implies a working socket the
  /// user is pairing over — true only while `hello` is succeeding. If `hello`
  /// itself failed, the socket is open but useless, and honouring that guard
  /// would leave the app with no connection, no pending timer, and nothing to
  /// retry: a dead end on the pairing screen.
  void _scheduleReconnect({bool afterFailedAttempt = false}) {
    if (_disposed ||
        (!afterFailedAttempt && _needsPairing && _client.isConnected) ||
        _reconnectTimer?.isActive == true) {
      return;
    }

    final delay = _nextReconnectDelay();
    setState(() {
      _connectionStatus = 'Reconnecting...';
      _connectionStatusColor = const Color(0xffffc857);
      _markAttachedSessionsDisconnected();
    });
    _reconnectTimer = Timer(delay, () {
      _reconnectTimer = null;
      if (_disposed) return;
      // A retry only wants *a* connection, and an attempt already in flight is
      // one — so let it finish instead of queueing a replay that would tear it
      // back down on success. Dropping this is safe because that attempt is
      // bounded (connect/request/close all have deadlines) and its own failure
      // path schedules the next retry.
      if (_isConnecting) return;
      _connectWebSocket(isReconnect: true);
    });
  }

  Future<void> _connectWebSocket({bool isReconnect = false}) async {
    if (_disposed) return;
    // Nothing to dial. Without this, a connect raised while the connection
    // screen is up — the resume/wake path, a retry timer — would fall back to
    // the page-origin URI and pair against a localhost daemon the user never
    // added. Web has no such screen: its daemon is the page origin.
    if (widget.client == null && !kIsWeb && _activeServer == null) return;
    if (_isConnecting) {
      // A connect is already in flight, and it cannot serve this caller: the
      // ones that reach here want a *different* connection (a new daemon
      // address, a token that just rotated), not merely any connection — the
      // retry timer, which does want merely any, returns before calling us.
      // So record the request and replay it once the attempt settles, rather
      // than dropping it and silently staying on the old daemon.
      _reconnectRequested = true;
      return;
    }
    _isConnecting = true;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    final generation = ++_connectGeneration;
    if (_clientInitialized) {
      final subscription = _websocketSubscription;
      _websocketSubscription = null;
      try {
        await subscription?.cancel().timeout(const Duration(milliseconds: 250));
      } catch (_) {}
      try {
        await _client.disconnect();
      } catch (_) {}
    }

    // Disposed, or superseded by a newer generation — which then owns
    // `_isConnecting` (and the replay hook in its own `finally`). Clearing the
    // flag here would let a third connect start alongside the live one.
    if (_disposed || generation != _connectGeneration) {
      return;
    }

    // The attempt commits to an address and a token here. Anything requested
    // before this point is already served by it — it re-reads both — so only a
    // request arriving from now on needs a connection of its own. Clearing the
    // flag exactly here is what makes "requested" mean "not yet served", with no
    // need to compare what changed afterwards.
    _reconnectRequested = false;

    // Read the server, its token, and its address together, with no await in
    // between, so an attempt can never pair one daemon's token with another's
    // address. Reading the token earlier — before the disconnect above — let a
    // switch land in the gap and leave the attempt with a mixed identity.
    final serverId = _activeServerId;
    _refreshBearerTokenFromStorage();
    final client = widget.client ?? TriageWebSocketClient(_activeDaemonUri);
    _client = client;
    _clientInitialized = true;

    setState(() {
      _connectionStatus = 'Connecting...';
      _connectionStatusColor = const Color(0xffffc857);
    });

    try {
      await _client.connect();

      // A switch that landed mid-attempt retires it: this socket is open to the
      // daemon we just left. Bailing is safe — the switch set
      // `_reconnectRequested`, so the `finally` replays against the new server.
      if (_disposed ||
          generation != _connectGeneration ||
          serverId != _activeServerId) {
        // Disconnect the client *this* generation opened, not `_client` — a
        // newer generation may already have replaced the field, and tearing
        // down its fresh connection would kill the live one.
        await client.disconnect();
        return;
      }

      _websocketSubscription = _client.events.listen(
        _onWebSocketEvent,
        onError: (error) => _onWebSocketError(error, generation),
        onDone: () => _onWebSocketClosed(generation),
      );

      final helloRes = await _client.hello(
        clientId: _clientId,
        token: _bearerToken,
      );
      final authenticated = helloRes['authenticated'] as bool? ?? false;

      if (_disposed ||
          generation != _connectGeneration ||
          serverId != _activeServerId) {
        return;
      }

      if (!authenticated) {
        await _showPairingChallenge(generation, serverId);
        return;
      }

      setState(() {
        _needsPairing = false;
        _pairingChallengeLoading = false;
        _pairingChallengeError = null;
        _connectionStatus = 'Connected to Daemon';
        _connectionStatusColor = const Color(0xff7fd1c7);
      });

      await _loadDaemonSessions();
      _reconnectAttempt = 0;
    } catch (e) {
      if (_disposed ||
          generation != _connectGeneration ||
          serverId != _activeServerId) {
        return;
      }
      // A rejected token never recovers by retrying, so re-pair instead of
      // falling into the reconnect backoff.
      if (e is TriageAuthException) {
        await _showPairingChallenge(generation, serverId);
      } else {
        setState(() {
          _connectionStatus = isReconnect
              ? 'Reconnect Failed'
              : 'Offline (Local Mock)';
          _connectionStatusColor = const Color(0xff7f8b8d);
          _markAttachedSessionsDisconnected();
        });
        // A queued request is replayed immediately by the `finally`, so don't
        // also burn a backoff step on a delay that would just be cancelled.
        if (!_reconnectRequested) _scheduleReconnect(afterFailedAttempt: true);
      }
    } finally {
      if (generation == _connectGeneration) {
        _isConnecting = false;
        if (_reconnectRequested && !_disposed) {
          _reconnectRequested = false;
          unawaited(_connectWebSocket(isReconnect: true));
        }
      }
    }
  }

  /// Drops the token [serverId] rejected and asks that daemon for a fresh
  /// pairing challenge.
  ///
  /// The token cleared is the one the *attempt* used, not whichever server is
  /// active by the time this runs — clearing by "current" would let an attempt
  /// against the daemon we just left un-pair the one we just switched to.
  Future<void> _showPairingChallenge(int generation, String serverId) async {
    _bearerToken = null;
    clearTokenFor(serverId);
    if (_disposed ||
        generation != _connectGeneration ||
        serverId != _activeServerId) {
      return;
    }

    setState(() {
      _needsPairing = true;
      _pairingChallengeLoading = true;
      _pairingChallengeError = null;
      _connectionStatus = 'Awaiting Pairing';
      _connectionStatusColor = const Color(0xffffc857);
    });

    await _requestPairingChallenge(generation: generation);
  }

  Future<void> _requestPairingChallenge({int? generation}) async {
    if (_disposed || (generation != null && generation != _connectGeneration)) {
      return;
    }

    if (!_client.isConnected) {
      setState(() {
        _pairingChallengeLoading = false;
        _pairingChallengeError =
            'Connection closed before the pairing challenge could be requested.';
      });
      _scheduleReconnect();
      return;
    }

    setState(() {
      _pairingChallengeLoading = true;
      _pairingChallengeError = null;
      // Drop the prior challenge so a refresh renders the loading spinner
      // instead of the previous device code and pairing URL — the URL now embeds
      // the device code, so a stale one would point at a challenge that no
      // longer exists. The build shows the spinner only while the code is null.
      _pairingDeviceCode = null;
      _pairingVerificationUri = null;
      _pairingDaemonHostUri = null;
      _pairingExpiresAt = null;
    });

    try {
      final challenge = await _client.pairingChallenge(clientId: _clientId);
      if (_disposed ||
          (generation != null && generation != _connectGeneration)) {
        return;
      }

      final expiresAtSeconds = challenge['expires_at'];
      setState(() {
        _pairingDeviceCode = challenge['device_code']?.toString();
        _pairingVerificationUri = _verificationUriForClient(
          _client,
          deviceCode: _pairingDeviceCode,
        );
        _pairingDaemonHostUri = _daemonHostPairingUri(
          _client,
          deviceCode: _pairingDeviceCode,
        );
        _pairingExpiresAt = expiresAtSeconds is int
            ? DateTime.fromMillisecondsSinceEpoch(
                expiresAtSeconds * 1000,
                isUtc: true,
              ).toLocal()
            : null;
        _pairingChallengeLoading = false;
      });
    } catch (e) {
      if (_disposed ||
          (generation != null && generation != _connectGeneration)) {
        return;
      }
      setState(() {
        _pairingChallengeLoading = false;
        _pairingChallengeError = e.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  Future<void> _onPairRequested(String pin) async {
    // The daemon being paired with, captured before the round trip: the token it
    // returns is *its* token, and storing it under whatever server is active by
    // the time the PIN clears would file it against the wrong daemon.
    final serverId = _activeServerId;
    final String token;
    try {
      token = await _client.pair(code: pin, clientId: _clientId);
    } catch (_) {
      await _requestPairingChallenge();
      rethrow;
    }
    if (token.isEmpty) {
      throw Exception('Server returned empty pairing token');
    }
    // Store the token before the switched-away guard. It is keyed by the
    // captured serverId, so it belongs to *that* daemon no matter which one is
    // active now — and pairing with a second daemon must not overwrite the
    // first one's. Discarding it because the user switched away mid-PIN would
    // throw away a valid credential and force a needless re-pair on return, the
    // exact loss this feature removes. persistClientId is device-global.
    persistClientId(_clientId);
    persistTokenFor(serverId, token);
    if (_disposed || serverId != _activeServerId) return;

    setState(() {
      _bearerToken = token;
      _storageBackedClientId = retrieveClientId() == _clientId;
      _pairingChallengeError = null;
    });
    _reconnectAttempt = 0;
    _isConnecting = false;
    await _connectWebSocket();
  }

  Future<void> _loadDaemonSessions() async {
    if (!_client.isConnected) return;

    // Pin the connection this load belongs to. A switch landing mid-load bumps
    // the generation; every state mutation below re-checks it so a load started
    // against the outgoing daemon can't rebuild the rail or seed metadata onto
    // the incoming one — session ids are daemon-local and collide (both have a
    // `main`), so a stale continuation would file A's data under B's session.
    final generation = _connectGeneration;
    try {
      final rawSessionIds = await _client.listSessions();
      // Fetch git context + activity *before* building rows, so the rail's first
      // paint is already grouped by repository and ordered by recency. This used
      // to run after the rail was built, which meant every load painted in
      // daemon order and then visibly rearranged itself once context landed.
      // Fetched together rather than in sequence: each `await` here is a window
      // in which a reconnect can bump the generation and a second load can
      // interleave, so the load path keeps its number of suspension points down.
      final contextsFuture = _fetchSessionContexts();
      final layoutFuture = _client.getRailLayout();
      final contexts = await contextsFuture;
      final layout = await layoutFuture;
      if (_disposed || generation != _connectGeneration) return;

      if (layout != null) {
        final daemonHasPins =
            layout.groupKeys.isNotEmpty || layout.sessionIds.isNotEmpty;
        final daemonHasLabels = layout.customLabels.isNotEmpty;

        if (daemonHasPins) {
          _pins = SessionPins(
            groupKeys: layout.groupKeys,
            sessionIds: layout.sessionIds,
          );
          unawaited(_persistPins(_pins));
        } else if (!_pins.isEmpty) {
          unawaited(
            _client
                .setRailPins(
                  groupKeys: _pins.groupKeys,
                  sessionIds: _pins.sessionIds,
                )
                .catchError((_) {}),
          );
        }

        if (daemonHasLabels) {
          _customLabels = Map.of(layout.customLabels);
          unawaited(_persistCustomLabels());
        } else if (_customLabels.isNotEmpty) {
          for (final entry in _customLabels.entries) {
            var rawId = entry.key;
            if (rawId.startsWith('triage / ')) {
              rawId = rawId.substring('triage / '.length);
            }
            if (rawId.trim().isEmpty) continue;
            unawaited(
              _client
                  .setSessionCustomLabel(
                    sessionId: rawId,
                    customLabel: entry.value,
                  )
                  .catchError((_) {}),
            );
          }
        }
      }

      // Read from the cache primed when the server resolved; never await prefs
      // on this path. `SharedPreferences.getInstance()` does not complete until
      // its platform channel answers, which stalls the whole load behind it.
      final pins = _pins;
      final groups = _groupSessions(rawSessionIds, contexts, pins);
      final sessionIds = flattenGroups(groups);
      final List<String> failedSessionIds = [];
      // Re-anchor the selection on the *session*, not the slot it used to
      // occupy. The rail's order is now derived from activity, so any reconnect
      // (a network blip, an app resume, an address edit) can legitimately
      // re-sort it; carrying the old index across would attach and display
      // whichever session happened to inherit that position.
      final previouslySelected =
          (_selectedIndex >= 0 && _selectedIndex < _sessions.length)
          ? _sessions[_selectedIndex].remoteSessionId
          : null;
      final reselected = previouslySelected == null
          ? -1
          : sessionIds.indexOf(previouslySelected);
      final targetSelectedIndex = reselected != -1
          ? reselected
          : (_selectedIndex >= sessionIds.length
                ? (sessionIds.isEmpty ? 0 : sessionIds.length - 1)
                : _selectedIndex);

      if (_disposed || generation != _connectGeneration) return;
      // Keep a pane only when it is the *same* daemon's session of that name. A
      // title is `triage / <session id>`, and session ids are daemon-local, so
      // after a switch an identical title is a different machine's session — and
      // reusing its cached terminal would show the old daemon's scrollback.
      final sameServer = _sessionsServerId == _activeServerId;
      final loadingSessionTitles = sameServer
          ? {for (final sid in sessionIds) 'triage / $sid'}
          : const <String>{};
      setState(() {
        for (final s in _sessions) {
          s.terminalController.dispose();
          if (!loadingSessionTitles.contains(s.title)) {
            TerminalPane.destroySession(s.title);
          }
        }
        _sessionsServerId = _activeServerId;
        _sessions.clear();
        _sessionGroups = groups;
        // `_pins` is deliberately *not* reassigned from the local captured above:
        // a background `_restorePins` may have completed during the awaits since,
        // and writing the stale capture back would silently discard it.
        for (var i = 0; i < sessionIds.length; i++) {
          // Only the selected session loads now; the rest rest as rail rows
          // until selected (see the lazy-load note below).
          final session = _loadingDaemonSession(
            sessionIds[i],
            loading: i == targetSelectedIndex,
          );
          // Apply the context fetched above so the row renders with its final
          // "repo · worktree" title on the first frame, rather than showing a
          // session-id fallback that swaps out a moment later.
          final entry = contexts[sessionIds[i]];
          if (entry != null) {
            session.applyContext(
              repoRoot: entry.repositoryRoot,
              worktreeRoot: entry.worktreeRoot,
              branch: entry.branch,
              // The bulk response carries no cwd; live cwd arrives via push.
              updateCwd: false,
            );
            session.lastActivityMs = entry.lastActivityMs;
          }
          _setupSessionInputListener(session);
          _sessions.add(session);
        }
        // `targetSelectedIndex` already clamps for a list that shrank, so the
        // old bounds check here is not just redundant: taking its branch
        // discards the session-anchored reselection and leaves the rail
        // highlighting a different row than `_loadDaemonSessionInto` attaches.
        _selectedIndex = targetSelectedIndex;
        if (sessionIds.isEmpty) {
          _connectionStatus = 'Connected to Daemon';
          _connectionStatusColor = const Color(0xff7fd1c7);
        } else {
          _connectionStatus = 'Loading ${sessionIds.length} sessions...';
          _connectionStatusColor = const Color(0xffffc857);
        }
      });

      // Lazy-load: subscribe/attach ONLY the selected session on connect. The
      // rest stay as lightweight rail rows (title + snippet + git context from
      // the list calls) and load on demand when selected. Subscribing to every
      // session at once saturates the single WebSocket and the requests time out
      // over a network link — the "reconnect fails / load failed until I keep
      // switching sessions" storm — and only one session is ever shown at a time.
      if (sessionIds.isNotEmpty) {
        await _loadDaemonSessionInto(
          sessionIds[targetSelectedIndex],
          includeHistory: true,
          failedSessionIds: failedSessionIds,
        );
      }

      if (!_disposed && generation == _connectGeneration) {
        setState(() {
          final loadedCount = _sessions
              .where((s) => s.isRemote && s.status == 'attached')
              .length;
          if (failedSessionIds.isEmpty) {
            _connectionStatus = 'Connected to Daemon';
            _connectionStatusColor = const Color(0xff7fd1c7);
          } else {
            _connectionStatus =
                'Loaded $loadedCount; failed ${failedSessionIds.join(', ')}';
            _connectionStatusColor = const Color(0xffffc857);
          }
        });
      }

      // Git context is already applied: it was fetched before the rail was
      // built so grouping and titles land on the first frame. Only snippets
      // and judge policies remain, and they are purely additive: a row renders fine without one.
      await Future.wait([
        _seedSessionSnippets(generation),
        _seedSessionJudgePolicies(generation),
      ]);

      // The active session re-syncs to its real width on its first view fit
      // (_onSessionViewFit). Doing it here would use an estimated size, since
      // the terminal view has not laid out yet.
    } on TriageAuthException {
      // The token was rejected while loading (revoked, or bound to a client id
      // this install no longer has). Let it reach `_connectWebSocket`, which
      // routes to pairing. Swallowing it here would strand the app on
      // "Connected to Daemon" with no sessions and no way to re-pair.
      rethrow;
    } catch (_) {
      // Fallback
    }
  }

  Future<void> _seedSessionSnippets(int generation) async {
    try {
      final snippets = await _client.listSessionSnippets();
      if (_disposed || generation != _connectGeneration || snippets.isEmpty) {
        return;
      }
      setState(() {
        for (final session in _sessions) {
          final sid = session.remoteSessionId;
          final entry = sid == null ? null : snippets[sid];
          if (entry != null) {
            session.snippet = entry.snippet;
            session.snippetDetail = entry.detail;
          }
        }
      });
    } catch (_) {
      // Snippets are best-effort metadata; ignore failures.
    }
  }

  Future<void> _seedSessionJudgePolicies(int generation) async {
    try {
      final policies = await _client.listSessionJudgePolicies();
      if (_disposed || generation != _connectGeneration) {
        return;
      }
      setState(() {
        for (final session in _sessions) {
          final sid = session.remoteSessionId;
          final entry = sid == null ? null : policies[sid];
          if (entry != null) {
            session.applyJudgePolicy(
              explicit: entry.explicit,
              effective: entry.effective,
            );
          }
        }
      });
    } catch (_) {
      // Judge policies are best-effort metadata; ignore failures.
    }
  }

  /// Every session's git context and last-output time, fetched before the rail
  /// is built so grouping, ordering, and titles are all correct on first paint.
  ///
  /// Best-effort: a daemon without the request (pre-upgrade) yields an empty map,
  /// which leaves the rail ungrouped and on the daemon's own deterministic order
  /// rather than failing the load.
  ///
  /// Takes no connect generation: the caller re-checks its own on the line after
  /// this returns, which is what makes a stale load harmless. The guard that used
  /// to live here was needed by the `setState`-ing seeder this replaced.
  ///
  /// The one thing it does write is [_railGroupingDegraded], and that is
  /// deliberately left ungenerationed. It records whether this daemon answers the
  /// request at all, which is a property of the connection rather than of any one
  /// load, and it drives no rebuild.
  Future<Map<String, SessionContextRecord>> _fetchSessionContexts() async {
    try {
      final contexts = await _client.listSessionContexts();
      _railGroupingDegraded = false;
      return contexts;
    } catch (error) {
      // Logged rather than swallowed silently: this now drives grouping and
      // ordering, not just titles, and an unreported failure here degrades the
      // rail to ungrouped-and-unordered with nothing to explain why. A silent
      // catch on exactly this call is what hid the missing FlatBuffers request
      // case until someone noticed the rail had no repository context at all.
      debugPrint(
        'list_session_contexts failed; rail will be ungrouped: $error',
      );
      // Remembered, not just logged: without repository context every session
      // collapses into the repo-less group and the rail renders headerless,
      // indistinguishable from a genuine single-repository rail. A drag read in
      // that state would pin a prefix spanning sessions that really belong to
      // different repositories, and the next successful load would hoist each of
      // them to the top of its own group.
      _railGroupingDegraded = true;
      return const {};
    }
  }

  /// Primes [_pins] from this server's stored pins, in the background.
  ///
  /// Runs off the load path deliberately, which then reads [_pins] synchronously.
  /// `SharedPreferences.getInstance()` completes only once its platform channel
  /// answers, so awaiting it mid-load stalls the entire session load behind it,
  /// including the selected session's attach.
  ///
  /// Best-effort like the rest of the rail's layout state: a failed read leaves
  /// no pins, which orders everything by activity rather than failing the load.
  Future<void> _restorePins() async {
    // The server can change while the read is in flight; capture the one being
    // read for so a slow read cannot apply one daemon's pins to another's rail.
    final serverId = _activeServerId;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (_disposed || serverId != _activeServerId) return;
      final restored = SessionPins(
        groupKeys: prefs.getStringList(pinnedGroupsPrefKeyFor(serverId)) ?? [],
        sessionIds:
            prefs.getStringList(pinnedSessionsPrefKeyFor(serverId)) ?? [],
      );
      // A load that finished while this read was in flight grouped the rail with
      // no pins, so assigning the field alone would leave [_pins] describing a
      // layout [_sessionGroups] does not have. `pinPrefixTo` reads the displayed
      // order and assumes the pinned block already leads it, so the next drag
      // would compute its prefix against the wrong list and drop pins. Re-group
      // instead, without persisting, since this is what storage already says.
      if (!restored.isEmpty && _sessionsServerId == serverId) {
        _applyPins(restored, persist: false, syncToDaemon: false);
      } else if (_pins.isEmpty) {
        _pins = restored;
      }
    } catch (_) {
      // Pinning is a best-effort convenience; ignore load failures.
    }
  }

  Future<void> _persistPins(SessionPins pins) async {
    final serverId = _activeServerId;
    // The rail keeps accepting drags on the outgoing daemon's tiles until the
    // new session list lands; writing those under this server's key would
    // destroy its real pins and then apply them to sessions they don't name.
    if (_sessionsServerId != serverId) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(
        pinnedGroupsPrefKeyFor(serverId),
        pins.groupKeys,
      );
      await prefs.setStringList(
        pinnedSessionsPrefKeyFor(serverId),
        pins.sessionIds,
      );
    } catch (_) {
      // Pinning is a best-effort convenience; ignore persistence failures.
    }
  }

  Future<void> _clearPinsFor(String serverId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(pinnedGroupsPrefKeyFor(serverId));
      await prefs.remove(pinnedSessionsPrefKeyFor(serverId));
      await prefs.remove(sessionCustomLabelsPrefKeyFor(serverId));
    } catch (_) {
      // Best-effort; ignore removal failures.
    }
  }

  String _keyForSession(SessionVm session) {
    final raw = session.remoteSessionId ?? session.sessionId ?? session.title;
    return raw.startsWith('triage / ')
        ? raw.substring('triage / '.length)
        : raw;
  }

  String? _lookupCustomLabel(String id) =>
      _customLabels[id] ?? _customLabels['triage / $id'];

  /// Restores this server's custom session labels in the background and applies
  /// them to any matching sessions currently loaded.
  Future<void> _restoreCustomLabels() async {
    final serverId = _activeServerId;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (_disposed || serverId != _activeServerId) return;
      final raw = prefs.getString(sessionCustomLabelsPrefKeyFor(serverId));
      Map<String, String> labels = {};
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          labels = {
            for (final entry in decoded.entries)
              if (entry.value != null &&
                  entry.value.toString().trim().isNotEmpty)
                (entry.key.toString().startsWith('triage / ')
                    ? entry.key.toString().substring('triage / '.length)
                    : entry.key.toString()): entry.value.toString().trim(),
          };
        }
      }
      if (_customLabels.isEmpty) {
        _customLabels = labels;
        for (final session in _sessions) {
          final key = _keyForSession(session);
          session.customLabel = _lookupCustomLabel(key);
        }
        if (mounted) setState(() {});
      }
    } catch (_) {
      // Custom labels are a best-effort convenience; ignore load failures.
    }
  }

  Future<void> _persistCustomLabels() async {
    final serverId = _activeServerId;
    if (_sessionsServerId != serverId) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (_customLabels.isEmpty) {
        await prefs.remove(sessionCustomLabelsPrefKeyFor(serverId));
      } else {
        await prefs.setString(
          sessionCustomLabelsPrefKeyFor(serverId),
          jsonEncode(_customLabels),
        );
      }
    } catch (_) {
      // Custom labels are a best-effort convenience; ignore persistence failures.
    }
  }

  void _setSessionCustomLabel(SessionVm session, String? label) {
    final key = _keyForSession(session);
    final trimmed = label?.trim();
    _customLabels.remove('triage / $key');
    if (trimmed != null && trimmed.isNotEmpty) {
      session.customLabel = trimmed;
      _customLabels[key] = trimmed;
    } else {
      session.customLabel = null;
      _customLabels.remove(key);
    }
    _persistCustomLabels();
    if (session.remoteSessionId != null &&
        _clientInitialized &&
        _client.isConnected) {
      unawaited(
        _client
            .setSessionCustomLabel(
              sessionId: session.remoteSessionId!,
              customLabel:
                  trimmed != null && trimmed.isNotEmpty ? trimmed : null,
            )
            .catchError((_) {}),
      );
    }
    if (mounted) setState(() {});
  }

  /// The rail's sessions as grouping inputs, read back off the view models so a
  /// re-group after a drag needs no daemon round-trip.
  List<SessionOrderingInput> _orderingInputs() => [
    for (final session in _sessions)
      if (session.remoteSessionId != null)
        SessionOrderingInput(
          sessionId: session.remoteSessionId!,
          repoRoot: session.repoRoot,
          lastActivityMs: session.lastActivityMs,
        ),
  ];

  /// An activity stamp that ranks above every session currently on the rail.
  ///
  /// Deliberately not a wall-clock reading: these stamps come from the daemon,
  /// and a client whose clock trails the daemon's would produce a "newest" value
  /// that sorts below sessions idle for minutes.
  int _nextLocalActivityStamp() {
    var newest = 0;
    for (final session in _sessions) {
      if (session.lastActivityMs > newest) newest = session.lastActivityMs;
    }
    return newest + 1;
  }

  /// Re-derives the rail's grouping from the sessions as they stand now,
  /// leaving the pins alone.
  ///
  /// Needed wherever a session's repository can change after the rail was built:
  /// membership follows [SessionVm.repoRoot], but the groups are a snapshot, so
  /// assigning the field without this leaves the two disagreeing about which
  /// header a row sits under.
  /// Any drag in progress is cancelled first, which is what the framework asks
  /// for: reordering the rows underneath a live drag leaves it holding an index
  /// into a list that no longer describes them, and `ReorderableList` wraps each
  /// child in a `GlobalKey` that a reorder mid-drag duplicates outright, which
  /// throws. The gesture is lost, which the user can see and simply repeat.
  ///
  /// Holding the re-group until the drop instead would save the gesture, but it
  /// cannot be built on the callbacks offered: `onReorderEnd` fires at
  /// pointer-up, several frames before `onReorderItem` delivers the drop, so a
  /// re-group released there still lands mid-drag; and neither a pointer cancel
  /// nor the list's own `cancelReorder` raises either callback, so a flag cleared
  /// on drag end sticks set and freezes re-grouping for the rest of the session.
  void _regroupRail() {
    if (_disposed || !mounted) return;
    _railListKey.currentState?.cancelReorder();
    // Paired with the cancel above, and the reason [_draggingRailGroup] lives on
    // this state: `cancelReorder` raises neither `onReorderEnd` nor
    // `onReorderItem`, so the drag it just ended would otherwise never clear.
    _draggingRailGroup = null;
    _applyPins(_pins, persist: false);
  }

  /// Records that a header drag has begun, so the rail can show the group's rows
  /// travelling with it.
  ///
  /// Row drags set nothing: a row moves alone, and the treatment exists to say
  /// "the rest of this group is coming too", which is only true of a header.
  void _railDragStarted(List<RailItem> items, int index) {
    if (index < 0 || index >= items.length) return;
    final item = items[index];
    final group = item.isHeader ? item.groupKey : null;
    if (_draggingRailGroup == group) return;
    setState(() => _draggingRailGroup = group);
  }

  /// Clears the header-drag treatment. Safe to call when nothing is set, which
  /// it routinely is: every row drag ends here too.
  ///
  /// Only one of the ways a drag can end announces itself: `onReorderEnd`, on a
  /// normal drop. The list's own cancel path, the `cancelReorder` in
  /// [_regroupRail], the `cancelReorder` `didUpdateWidget` runs when the item
  /// count changes, and the rail being unmounted under a held gesture all raise
  /// nothing whatsoever.
  ///
  /// The rail covers them by watching raw pointer up and cancel, which reaches
  /// even the unmounted case: the hit-test path is recorded at pointer-down and
  /// dispatched to without checking that its targets are still in the tree, so
  /// the listener hears the pointer that outlived it. Measured, not assumed; the
  /// obvious-looking clears at the call sites that swap the rail out were
  /// written on the opposite assumption and were dead code.
  void _railDragEnded() {
    // Guarded like the rest of this state's mutators, and with more reason than
    // most: this is the one callback documented above as arriving after its
    // widget has gone.
    if (_disposed || !mounted) return;
    if (_draggingRailGroup == null) return;
    setState(() => _draggingRailGroup = null);
  }

  /// Whether the rail has collapsed into a single contextless group, which it
  /// renders headerless and so indistinguishable from a genuine single-repository
  /// rail. A drag read in that state would pin a prefix spanning sessions that
  /// really belong to different repositories, and the next successful load would
  /// hoist each of them to the top of its own group.
  ///
  /// Both halves are required. [_railGroupingDegraded] alone stays set until a
  /// context fetch succeeds, but `session_context_updated` pushes also supply
  /// repository roots, and once they have produced a second group the rail is
  /// showing real headers over real groups. Rejecting drags there left the user
  /// with a visibly grouped rail whose gestures silently did nothing, which is
  /// the opposite of what the guard is for.
  bool get _railGroupingIsCollapsed =>
      _railGroupingDegraded && _sessionGroups.length <= 1;

  /// Re-applies [pins], reordering the rail and keeping the selection on the
  /// same session rather than the same index.
  ///
  /// [persist] is false when the caller is applying pins it just read back from
  /// storage, which has nothing to write.
  void _applyPins(
    SessionPins pins, {
    bool persist = true,
    bool syncToDaemon = true,
  }) {
    final groups = groupSessionsByRepo(_orderingInputs(), pins: pins);
    final order = flattenGroups(groups);
    final byId = <String, SessionVm>{
      for (final session in _sessions)
        if (session.remoteSessionId != null) session.remoteSessionId!: session,
    };
    final selected = (_selectedIndex >= 0 && _selectedIndex < _sessions.length)
        ? _sessions[_selectedIndex]
        : null;
    final reordered = [
      for (final id in order)
        if (byId[id] != null) byId[id]!,
    ];
    // Local sessions carry no remote id and so never appear in a group; keep
    // them rather than letting a re-group silently drop them from the rail.
    final placed = reordered.toSet();
    reordered.addAll(_sessions.where((s) => !placed.contains(s)));

    setState(() {
      _pins = pins;
      _sessionGroups = groups;
      _sessions
        ..clear()
        ..addAll(reordered);
      if (selected != null) {
        final index = _sessions.indexOf(selected);
        if (index != -1) _selectedIndex = index;
      }
    });
    if (persist) unawaited(_persistPins(pins));
    if (syncToDaemon && _clientInitialized && _client.isConnected) {
      unawaited(
        _client
            .setRailPins(
              groupKeys: pins.groupKeys,
              sessionIds: pins.sessionIds,
            )
            .catchError((_) {}),
      );
    }
  }

  /// Interprets a rail drag: the moved group or row is pinned where it was put,
  /// and everything still unpinned keeps flowing by activity around it.
  ///
  /// [items] comes from the rail that produced the drag rather than being rebuilt
  /// here. The indices only mean anything against the exact list they were
  /// measured on, and reconstructing it is both redundant work and a way for the
  /// two to drift. It is trustworthy because [_regroupRail] cancels a live drag
  /// before rebuilding, so no drop can arrive measured against a list the rail
  /// has already replaced.
  ///
  /// [newIndex] is in post-removal coordinates, as `onReorderItem` reports it.
  void _reorderRail(List<RailItem> items, int oldIndex, int newIndex) {
    // The rail is showing its degraded, contextless collapse. The drop position
    // cannot be mapped onto anything durable, so let the row spring back rather
    // than persist a pin that means something different once context arrives.
    if (_railGroupingIsCollapsed) return;
    final pins = resolveRailReorder(
      items: items,
      pins: _pins,
      oldIndex: oldIndex,
      newIndex: newIndex,
    );
    // A drag that resolved to no change returns the pins it was given. Applying
    // them anyway would rebuild the rail and write prefs values identical to
    // what is already stored, on every cancelled gesture.
    if (identical(pins, _pins)) return;
    _applyPins(pins);
  }

  /// Drops every pin, returning the whole rail to activity ordering.
  void _resetRailOrder() => _applyPins(SessionPins.none);

  /// Releases one group back to activity ordering, leaving other pins alone.
  void _unpinGroup(String groupKey) =>
      _applyPins(unpin(_pins, groupKey: groupKey));

  /// Releases one session back to activity ordering within its group.
  void _unpinSession(String sessionId) =>
      _applyPins(unpin(_pins, sessionId: sessionId));

  /// Groups [sessionIds] by repository and orders them by activity.
  ///
  /// Sessions missing from [contexts] still appear (as repo-less entries with
  /// unknown activity), so a context response that omits a session can never
  /// drop it from the rail.
  List<SessionGroup> _groupSessions(
    List<String> sessionIds,
    Map<String, SessionContextRecord> contexts,
    SessionPins pins,
  ) {
    return groupSessionsByRepo([
      for (final sessionId in sessionIds)
        SessionOrderingInput(
          sessionId: sessionId,
          repoRoot: contexts[sessionId]?.repositoryRoot,
          lastActivityMs: contexts[sessionId]?.lastActivityMs ?? 0,
        ),
    ], pins: pins);
  }

  // Placeholder rail row for a daemon session. [loading] true means it is being
  // attached now (the selected session); false is the lazy resting state for
  // sessions not yet opened — a muted row that carries only rail metadata until
  // the user selects it, at which point `_loadDaemonSessionInto` attaches it.
  SessionVm _loadingDaemonSession(String sessionId, {bool loading = true}) {
    final label = _lookupCustomLabel(sessionId);
    return SessionVm(
      title: 'triage / $sessionId',
      sessionId: sessionId,
      customLabel: label,
      status: loading ? 'loading' : 'idle',
      statusColor: loading ? const Color(0xffffc857) : const Color(0xff7f8b8d),
      icon: Icons.terminal,
      rows: loading ? [_plainRow('Loading session $sessionId...')] : const [],
      isRemote: true,
    );
  }

  // Attaches one daemon session (subscribe + attach + snapshot) and swaps it into
  // the rail in place, or marks it failed. Guarded against concurrent re-entry so
  // a double-select can't open two subscriptions. Extracted so both the connect
  // path and on-demand selection load a session the same way.
  Future<void> _loadDaemonSessionInto(
    String sid, {
    required bool includeHistory,
    required List<String> failedSessionIds,
  }) async {
    if (_loadingSessionIds.contains(sid)) return;
    _loadingSessionIds.add(sid);
    // The daemon this load belongs to. `_client` is a mutable field re-read
    // across every await below, and session ids are daemon-local and collide, so
    // a load still in flight when the user switches would otherwise subscribe and
    // attach against the *new* daemon using the *old* daemon's id — and then
    // stamp its result onto the new daemon's identically-named tile.
    final generation = _connectGeneration;
    // Show the row as loading (covers the on-demand-select case, where the row
    // was resting).
    if (!_disposed) {
      setState(() {
        final i = _sessions.indexWhere((s) => s.remoteSessionId == sid);
        if (i != -1 && !_sessions[i].loaded) {
          _sessions[i].status = 'loading';
          _sessions[i].statusColor = const Color(0xffffc857);
        }
      });
    }
    try {
      final session = await _loadDaemonSession(
        sid,
        includeHistory: includeHistory,
      );
      session.loaded = true;
      // The daemon changed under us: this session belongs to the one we left, and
      // the rail is now a different machine's. Discard it rather than stamp it
      // onto whatever tile happens to share the id.
      if (_disposed || generation != _connectGeneration) {
        session.dispose();
        return;
      }
      // Set inside the `setState` below, acted on after it: the snapshot is
      // allowed to report a repository the rail has not seen (a session that
      // `cd`ed elsewhere since connect), and that moves the row to a different
      // group, which the swap alone does not recompute.
      var regrouped = false;
      setState(() {
        final existingIndex = _sessions.indexWhere(
          (s) => s.remoteSessionId == sid,
        );
        if (existingIndex == -1) return;
        final oldSession = _sessions[existingIndex];
        // The replacement is built fresh, so its activity stamp is 0,
        // "unknown". Carrying the old one forward matters because this runs for
        // every session the user actually opens: without it the next re-group
        // sinks the session, and with it its whole repository (a group is as
        // recent as its most recent member), to the bottom of a rail that is
        // supposed to surface exactly what is being used.
        session.lastActivityMs = oldSession.lastActivityMs;
        // Same reasoning for the repository, which is what decides the session's
        // *group*: the replacement takes its context from the attach snapshot,
        // and a snapshot that omits one (an older daemon, or a session outside
        // the cases the daemon fills in) would move the session out of its
        // repository and into "Other" the moment it was opened. Only filled in
        // when the snapshot said nothing, so a genuine change still wins.
        //
        // Carried as a pair, keyed off the repository. The two are only
        // meaningful together, and filling them in independently let a snapshot
        // that reported a new repository and no worktree keep the *previous*
        // repository's worktree, which the row then rendered as "beta / alpha".
        if (session.repoRoot == null) {
          session.repoRoot = oldSession.repoRoot;
          session.worktreeRoot ??= oldSession.worktreeRoot;
        }
        regrouped = session.repoRoot != oldSession.repoRoot;
        oldSession.dispose();
        if (oldSession.title != session.title) {
          TerminalPane.destroySession(oldSession.title);
        }
        _sessions[existingIndex] = session;
      });
      if (regrouped) _regroupRail();
      _drainPendingEvents(sid);
    } on TriageAuthException {
      // The daemon refused the attach: this client is no longer paired. Painting
      // the row "load failed" would be a dead end — the same token fails for
      // every session, and the user has no way back. Propagate so the caller
      // re-pairs. It must not be handled here: swallowing it would let the
      // caller finish and report a healthy "Connected to Daemon" over the top of
      // the pairing prompt.
      rethrow;
    } catch (e) {
      // A load that failed because we tore its daemon down is not a failure of
      // the session now sitting under that id on the new daemon — painting that
      // one "load failed" would be a lie about a healthy session.
      if (_disposed || generation != _connectGeneration) return;
      failedSessionIds.add(sid);
      setState(() {
        final existingIndex = _sessions.indexWhere(
          (s) => s.remoteSessionId == sid,
        );
        if (existingIndex == -1) return;
        _sessions[existingIndex].status = 'load failed';
        _sessions[existingIndex].statusColor = const Color(0xffff6b6b);
        _sessions[existingIndex].rows
          ..clear()
          ..add(_plainRow('Failed to load session $sid'));
      });
      debugPrint('Failed to load session $sid: ${e.toString()}');
    } finally {
      _loadingSessionIds.remove(sid);
    }
  }

  Future<SessionVm> _loadDaemonSession(
    String sid, {
    required bool includeHistory,
  }) async {
    String? subId;
    try {
      var preAttachSnapshot = <String, dynamic>{};
      try {
        final snapshotRes = await _client.snapshotSession(sessionId: sid);
        preAttachSnapshot =
            snapshotRes['snapshot'] as Map<String, dynamic>? ?? {};
      } catch (_) {}

      final replayTargetSize = includeHistory
          ? _estimatedTerminalRestoreSize(
              preAttachSnapshot['size'] as Map<String, dynamic>?,
            )
          : null;
      Map<String, dynamic>? preparedSnapshot;
      if (preAttachSnapshot['exited'] == true) {
        final sizeObj = preAttachSnapshot['size'] as Map<String, dynamic>?;
        final restoreSize =
            replayTargetSize ?? _savedOrEstimatedTerminalRestoreSize(sizeObj);
        try {
          preparedSnapshot = _snapshotFromResponse(
            await _client.restoreSession(
              sessionId: sid,
              rows: restoreSize.$1,
              cols: restoreSize.$2,
            ),
          );
          if (preparedSnapshot != null) {
            preAttachSnapshot = preparedSnapshot;
          }
        } catch (_) {}
      } else if (replayTargetSize != null &&
          _clientForeground &&
          !_snapshotSizeMatches(preAttachSnapshot, replayTargetSize)) {
        // Gated like the other resize-out paths. This one is the weakest claim
        // of the three: the size is `_estimatedTerminalRestoreSize`, a
        // MediaQuery guess this client has not fitted to, so a backgrounded
        // reconnect taking the shared PTY here would move it to a size nobody
        // is rendering at. What corrects it later is whichever comes first, the
        // first fit made while foreground or the reclaim on regaining focus.
        try {
          preparedSnapshot = _snapshotFromResponse(
            await _client.resizeSession(
              sessionId: sid,
              rows: replayTargetSize.$1,
              cols: replayTargetSize.$2,
            ),
          );
          if (preparedSnapshot != null) {
            preAttachSnapshot = preparedSnapshot;
          }
        } catch (_) {}
      }

      // Subscribe to events first so we don't miss anything printed during attach
      subId = await _client.subscribeSessionEvents(sessionId: sid);
      if (subId.isNotEmpty) {
        _subscriptionIds[subId] = sid;
      }

      final attachRes = await _client.attachSession(
        sessionId: sid,
        clientId: _clientId,
        mode: 'InteractiveController',
      );
      final responseObj = attachRes['response'] as Map<String, dynamic>?;
      var snapshot = responseObj?['snapshot'] as Map<String, dynamic>?;
      // Fall back to the prepared snapshot only when it carries history: the
      // restore path's snapshot does, but a resize snapshot never does, and
      // replaying its empty history would clear the terminal to a blank screen.
      if (replayTargetSize != null &&
          preparedSnapshot != null &&
          _rawOutputFromSnapshot(preparedSnapshot).isNotEmpty &&
          !_snapshotSizeMatches(snapshot, replayTargetSize)) {
        snapshot = preparedSnapshot;
      }

      final contextObj = snapshot?['context'] as Map<String, dynamic>?;
      final branch = contextObj?['branch']?.toString();
      final repoRoot = contextObj?['repository_root']?.toString();
      final worktreeRoot = contextObj?['worktree_root']?.toString();
      final cwd = snapshot?['current_working_directory']?.toString();

      final plainRows = _plainRowsFromSnapshot(snapshot);
      final exited = snapshot?['exited'] as bool? ?? false;
      final outputSeq = snapshot?['output_seq'] as int? ?? 0;

      final customLabel = _lookupCustomLabel(sid);
      final session = SessionVm(
        title: 'triage / $sid',
        sessionId: sid,
        customLabel: customLabel,
        branch: branch,
        repoRoot: repoRoot,
        worktreeRoot: worktreeRoot,
        cwd: cwd,
        status: exited ? 'exited' : 'attached',
        statusColor: exited ? const Color(0xff7f8b8d) : const Color(0xff7fd1c7),
        icon: Icons.terminal,
        rows: plainRows.isEmpty
            ? [_plainRow('Attached to session $sid')]
            : plainRows,
        isRemote: true,
        isExited: exited,
      );
      // Snapshot carries the current snippet for the attached session (the list
      // seed + push events cover the rest).
      session.snippet = snapshot?['snippet'] as String?;
      session.snippetDetail = snapshot?['snippet_detail'] as String?;
      final bracketedPaste =
          snapshot?['bracketed_paste_enabled'] as bool? ?? false;
      session.setBracketedPasteEnabled(bracketedPaste);
      // Replay the raw output-history tail through the single write path. Live
      // chunks already covered by this snapshot are dropped by output_seq.
      session.applyHistory(
        _rawOutputFromSnapshot(snapshot ?? const {}),
        throughOutputSeq: outputSeq,
      );
      _setupSessionInputListener(session);
      return session;
    } catch (e) {
      // Roll back the subscription bookkeeping and drop any events buffered
      // for a session we will never expose, so they don't accumulate forever.
      if (subId != null && subId.isNotEmpty) {
        _subscriptionIds.remove(subId);
      }
      _pendingEvents.remove(sid);
      rethrow;
    }
  }

  void _drainPendingEvents(String sid) {
    final pending = _pendingEvents.remove(sid);
    if (pending != null) {
      for (final msg in pending) {
        _onWebSocketEvent(msg);
      }
    }
  }

  (int, int) _estimatedTerminalRestoreSize(Map<String, dynamic>? fallbackSize) {
    final viewportSize = MediaQuery.maybeSizeOf(context);
    if (viewportSize == null) {
      return (
        fallbackSize?['rows'] as int? ?? 24,
        fallbackSize?['cols'] as int? ?? 80,
      );
    }

    const headerHeight = 68.0;
    const padding = 44.0; // 22.0 on each side of the terminal view
    const averageCellWidth = 9.92;
    const averageCellHeight = 18.0;
    final sidebarWidth = _sidebarCollapsed ? 72.0 : 320.0;
    final terminalWidth = viewportSize.width - sidebarWidth - 1 - padding;
    final terminalHeight = viewportSize.height - headerHeight - padding;
    final cols = (terminalWidth / averageCellWidth).floor().clamp(80, 240);
    final rows = (terminalHeight / averageCellHeight).floor().clamp(10, 80);
    return (rows, cols);
  }

  (int, int) _savedOrEstimatedTerminalRestoreSize(
    Map<String, dynamic>? fallbackSize,
  ) {
    final cols = fallbackSize?['cols'] as int?;
    final rows = fallbackSize?['rows'] as int?;
    if (cols != null && rows != null) {
      return (rows, cols);
    }
    return _estimatedTerminalRestoreSize(fallbackSize);
  }

  (int, int) _currentReplayTerminalSize(
    SessionVm session,
    Map<String, dynamic>? fallbackSize,
  ) {
    // This device's own fit first. `lastFittedCols` is also written by the
    // host's resize broadcast, so on a shared PTY it can be another device's
    // width; replaying at that would leave this client rendering at a size it
    // never fitted to, and because the snapshot would then match, nothing
    // would correct it. Falls back to `lastFitted*` for the case where no local
    // fit has happened yet, where the host's size is the better guess.
    final cols = session.ownFittedCols ?? session.lastFittedCols;
    final rows = session.ownFittedRows ?? session.lastFittedRows;
    if (cols != null && rows != null) {
      return (rows, cols);
    }
    return _estimatedTerminalRestoreSize(fallbackSize);
  }

  Map<String, dynamic>? _asMap(Object? value) {
    if (value is Map<String, dynamic>) return value;
    if (value is Map) return Map<String, dynamic>.from(value);
    return null;
  }

  Map<String, dynamic>? _snapshotFromResponse(Map<String, dynamic> response) {
    return _asMap(response['snapshot']) ??
        _asMap(_asMap(response['response'])?['snapshot']);
  }

  bool _snapshotSizeMatches(
    Map<String, dynamic>? snapshot,
    (int, int) targetSize,
  ) {
    final sizeObj = snapshot?['size'] as Map<String, dynamic>?;
    return sizeObj?['rows'] == targetSize.$1 &&
        sizeObj?['cols'] == targetSize.$2;
  }

  void _onWebSocketEvent(Map<String, dynamic> message) {
    if (_disposed) return;
    _websocketEventQueue.add(message);
    unawaited(_processWebsocketEventQueue());
  }

  Future<void> _processWebsocketEventQueue() async {
    if (_websocketProcessingEvent || _websocketEventQueue.isEmpty) return;
    _websocketProcessingEvent = true;
    try {
      while (_websocketEventQueue.isNotEmpty && !_disposed) {
        final message = _websocketEventQueue.removeFirst();
        try {
          await _processWebSocketEvent(message);
        } catch (_) {}
      }
    } finally {
      _websocketProcessingEvent = false;
    }
  }

  Future<void> _processWebSocketEvent(Map<String, dynamic> message) async {
    final type = message['type'] as String?;
    if (type == 'connection_closed') {
      _onWebSocketClosed(_connectGeneration);
      return;
    }

    if (type == 'session_snippet_updated') {
      final sessionId = message['session_id'] as String?;
      if (sessionId == null) return;
      final snippet = message['snippet'] as String?;
      final detail = message['detail'] as String?;
      final index = _sessions.indexWhere((s) => s.remoteSessionId == sessionId);
      if (index == -1) return;
      void apply() {
        _sessions[index].snippet = snippet;
        // A regeneration always reports the current detail; null means the
        // detail pass produced nothing this round, so clear the stale one.
        _sessions[index].snippetDetail = detail;
        // Stamp only on a real summary. The summarizer re-running and producing
        // nothing is not the session doing something, and dating the row from
        // it would report activity that never happened.
        if (snippet != null && snippet.isNotEmpty) {
          _sessions[index].snippetUpdatedAt = DateTime.now();
        }
      }

      if (mounted) {
        setState(apply);
      } else {
        apply();
      }
      return;
    }

    if (type == 'session_context_updated') {
      final sessionId = message['session_id'] as String?;
      if (sessionId == null) return;
      final index = _sessions.indexWhere((s) => s.remoteSessionId == sessionId);
      if (index == -1) return;
      // Each push carries the full current context, so a null field genuinely
      // means "absent" (e.g. cd'd out of a repo) — assign directly, don't merge.
      final previousRepoRoot = _sessions[index].repoRoot;
      final nextRepoRoot = message['repository_root']?.toString();
      void apply() {
        _sessions[index].applyContext(
          repoRoot: nextRepoRoot,
          worktreeRoot: message['worktree_root']?.toString(),
          branch: message['branch']?.toString(),
          cwd: message['current_working_directory']?.toString(),
        );
      }

      if (mounted) {
        setState(apply);
      } else {
        apply();
      }
      // A `cd` across repositories changes which group the row belongs to, and
      // the grouping is not recomputed by the assignment above. Leaving it stale
      // shows the row under its old repository's header, and, worse, makes a
      // drag on it incoherent: `resolveRailReorder` would resolve the drop
      // against the old group while `_applyPins` immediately re-derives the new
      // one, landing the row somewhere it was not dropped and pinning its former
      // neighbours on the way.
      if (previousRepoRoot != nextRepoRoot) {
        _regroupRail();
      }
      return;
    }

    if (type == 'session_judge_policy_updated') {
      final sessionId = message['session_id'] as String?;
      if (sessionId == null) return;
      final index = _sessions.indexWhere((s) => s.remoteSessionId == sessionId);
      if (index == -1) return;
      final policy = message['policy'] as Map<String, dynamic>?;
      final bool hasExplicit;
      final bool? explicitVal;
      final bool effective;
      if (policy != null) {
        hasExplicit = policy.containsKey('explicit') && policy['explicit'] != null;
        explicitVal = policy['explicit'] as bool?;
        effective = policy['effective'] as bool? ?? false;
      } else {
        hasExplicit = message['has_pinned'] as bool? ?? (message.containsKey('explicit') && message['explicit'] != null);
        explicitVal = message['pinned'] as bool? ?? (message['explicit'] as bool?);
        effective = message['effective'] as bool? ?? false;
      }
      void apply() {
        _sessions[index].applyJudgePolicy(
          explicit: hasExplicit ? explicitVal : null,
          effective: effective,
        );
      }

      if (mounted) {
        setState(apply);
      } else {
        apply();
      }
      return;
    }

    if (type == 'rail_pins_updated') {
      final rawGroupKeys = message['group_keys'];
      final groupKeys = (rawGroupKeys is List)
          ? rawGroupKeys.map((e) => e.toString()).toList()
          : <String>[];
      final rawSessionIds = message['session_ids'];
      final sessionIds = (rawSessionIds is List)
          ? rawSessionIds.map((e) => e.toString()).toList()
          : <String>[];
      if (listEquals(_pins.groupKeys, groupKeys) &&
          listEquals(_pins.sessionIds, sessionIds)) {
        return;
      }
      final pins = SessionPins(
        groupKeys: groupKeys,
        sessionIds: sessionIds,
      );
      _applyPins(pins, persist: true, syncToDaemon: false);
      return;
    }

    if (type == 'session_custom_label_updated') {
      final sessionId = message['session_id'] as String?;
      if (sessionId == null) return;
      final rawLabel = message['custom_label']?.toString();
      final trimmed = rawLabel?.trim();
      final key = sessionId;
      _customLabels.remove('triage / $key');
      if (trimmed != null && trimmed.isNotEmpty) {
        _customLabels[key] = trimmed;
      } else {
        _customLabels.remove(key);
      }
      for (final session in _sessions) {
        if (session.remoteSessionId == sessionId) {
          session.customLabel =
              (trimmed != null && trimmed.isNotEmpty) ? trimmed : null;
        }
      }
      unawaited(_persistCustomLabels());
      if (mounted) setState(() {});
      return;
    }

    if (type == 'event') {
      final envelope = message['envelope'] as Map<String, dynamic>?;
      final event = envelope?['event'] as Map<String, dynamic>?;
      if (event == null) return;

      String? sessionId;
      if (event.containsKey('Output')) {
        sessionId = event['Output']['session_id'] as String?;
      } else if (event.containsKey('Exited')) {
        sessionId = event['Exited']['session_id'] as String?;
      } else if (event.containsKey('Snapshot')) {
        sessionId = event['Snapshot']['session_id'] as String?;
      } else if (event.containsKey('ResyncRequired')) {
        sessionId = event['ResyncRequired']['session_id'] as String?;
      }

      if (sessionId == null) return;

      final sessionIndex = _sessions.indexWhere(
        (s) => s.title == 'triage / $sessionId',
      );

      if (sessionIndex == -1) {
        // Buffer the event for when the session is fully attached/loaded
        _pendingEvents.putIfAbsent(sessionId, () => []).add(message);
        return;
      }

      final session = _sessions[sessionIndex];
      if (session.status == 'loading') {
        _pendingEvents.putIfAbsent(sessionId, () => []).add(message);
        return;
      }

      if (event.containsKey('Output')) {
        final output = event['Output'] as Map<String, dynamic>;
        final outputSeq = output['output_seq'] as int? ?? 0;
        final bytes = (output['bytes'] as List<dynamic>).cast<int>();

        // Single write path: raw bytes flow through the store, which owns UTF-8
        // carry, CRLF normalization, buffering, and all output_seq
        // de-duplication (against both the history high-water and re-deliveries).
        session.applyLiveBytes(bytes, outputSeq: outputSeq);
      } else if (event.containsKey('Exited')) {
        session.markExited();
        if (mounted) {
          setState(() {
            session.status = 'exited';
            session.statusColor = const Color(0xff7f8b8d);
            session.isExited = true;
          });
        }
      } else if (event.containsKey('Snapshot')) {
        // Resize-driven snapshot broadcast. Raw clients re-emulate from the live
        // byte stream (the program repaints on resize), so there is no history
        // to replay here — ignore it. Track the settled size for resize bookkeeping.
        final snapshot = event['Snapshot']['snapshot'] as Map<String, dynamic>?;
        final size = snapshot?['size'] as Map<String, dynamic>?;
        final cols = size?['cols'] as int?;
        final rows = size?['rows'] as int?;
        if (cols != null && rows != null) {
          session.lastFittedCols = cols;
          session.lastFittedRows = rows;
          // The host's own account of the PTY's settled size. Recorded
          // separately because this is the only place another device's resize
          // is observable, and it is what a reclaim has to compare against.
          session.hostSizeCols = cols;
          session.hostSizeRows = rows;
        }
      } else if (event.containsKey('ResyncRequired')) {
        final snapshot =
            event['ResyncRequired']['snapshot'] as Map<String, dynamic>?;
        if (snapshot != null) {
          await _applySnapshotToSession(session, sessionId, snapshot);
        }
      }
    }
  }

  Future<void> _applySnapshotToSession(
    SessionVm session,
    String sessionId,
    Map<String, dynamic> snapshot, {
    (int, int)? renderSize,
    bool replayHistory = true,
  }) async {
    // Bail if this SessionVm was disposed/replaced (e.g. a reconnect ran
    // _loadDaemonSessions) while the refresh was in flight — applying to a
    // disposed store is a use-after-dispose, and the live same-id object is
    // refreshed by its own load path.
    if (_disposed || !_sessions.contains(session)) return;
    final sizeObj = snapshot['size'] as Map<String, dynamic>?;
    // Kept separate from the rendering fallbacks below: the FlatBuffers decoder
    // turns an absent size into an empty map rather than null, so the container
    // being present says nothing about whether the host reported a size.
    final reportedCols = sizeObj?['cols'] as int?;
    final reportedRows = sizeObj?['rows'] as int?;
    final cols = reportedCols ?? 80;
    final rowsVal = reportedRows ?? 24;
    // `renderSize` is the size the caller actually drove the host to, or null
    // when it drove nothing (the foreground gate declined, or the resize
    // failed). It serves two readers below: the grid the content is rendered
    // at, and the host's own account of its size.
    //
    // The grid the content is actually rendered at, falling back to the
    // snapshot's own size. Using the snapshot size when it carries the *host*
    // width (the resize branch keeps the host-sized attach snapshot) would
    // poison lastFittedCols and drive the next refresh to resize the host back
    // and forth.
    final fittedCols = renderSize?.$2 ?? cols;
    final fittedRows = renderSize?.$1 ?? rowsVal;
    final rawOutput = _rawOutputFromSnapshot(snapshot);
    final snapshotOutputSeq = snapshot['output_seq'] as int?;
    final exited = snapshot['exited'] as bool? ?? false;

    // Replay history through the single write path: raw PTY bytes, not the
    // lossy styled-row reconstruction. When re-selecting an already-loaded live
    // session, avoid clearing and re-emulating the buffer so scroll position and
    // existing scrollback are preserved.
    if (replayHistory || !session.loaded) {
      session.applyHistory(rawOutput, throughOutputSeq: snapshotOutputSeq);
    }
    final bracketedPaste =
        snapshot['bracketed_paste_enabled'] as bool? ?? false;
    session.setBracketedPasteEnabled(bracketedPaste);

    setState(() {
      // Plain mirror for the test fallback view only; not used for real render.
      session.rows
        ..clear()
        ..addAll(_plainRowsFromSnapshot(snapshot));
      session.isExited = exited;
      session.status = exited ? 'exited' : 'attached';
      session.statusColor = exited
          ? const Color(0xff7f8b8d)
          : const Color(0xff7fd1c7);
      // The host's account of its own size, seeded here so a client that
      // attaches while backgrounded and never sees a resize broadcast can still
      // tell on refocus that the PTY is not at its size.
      //
      // `renderSize` when the caller has one, because that is a size it
      // actually drove the host to; the snapshot it hands us is deliberately
      // the pre-resize, history-bearing one, so reading `size` from it would
      // record a value already known to be stale and manufacture drift that
      // fires a pointless refit on the next focus regain. Never `fittedCols`,
      // which prefers our render size and so is not the host's account at all.
      //
      // Left alone entirely when neither is available: `cols`/`rowsVal` fall
      // back to 80x24 for rendering, and writing that guess here would either
      // invent drift or hide it. Guarded on the reported values rather than on
      // the size container, which the resize broadcast also does, because an
      // absent size reaches us as an empty map over FlatBuffers.
      final hostSize =
          renderSize ??
          (reportedCols == null || reportedRows == null
              ? null
              : (reportedRows, reportedCols));
      if (hostSize != null) {
        session.hostSizeCols = hostSize.$2;
        session.hostSizeRows = hostSize.$1;
      }
      session.lastFittedCols = fittedCols;
      session.lastFittedRows = fittedRows;
      session.inFlightCols = null;
      session.inFlightRows = null;
    });
  }

  /// Extracts the raw output-history tail from a parsed snapshot map. Empty when
  /// the host did not carry history (old host, or a resize broadcast).
  List<int> _rawOutputFromSnapshot(Map<String, dynamic> snapshot) {
    final raw = snapshot['raw_output'];
    return raw is List ? raw.cast<int>() : const <int>[];
  }

  /// Builds a plain-row mirror of a snapshot, used only by the FLUTTER_TEST
  /// fallback view; production rendering is driven by the store from raw bytes.
  /// Prefers visible_rows, falling back to the flattened text of styled_rows.
  List<StyledRow> _plainRowsFromSnapshot(Map<String, dynamic>? snapshot) {
    if (snapshot == null) return const <StyledRow>[];
    final visible = snapshot['visible_rows'] as List<dynamic>?;
    if (visible != null && visible.isNotEmpty) {
      return visible.map((row) => _plainRow(row?.toString() ?? '')).toList();
    }
    final styled = snapshot['styled_rows'] as List<dynamic>?;
    if (styled != null && styled.isNotEmpty) {
      return styled.map((row) {
        final spans =
            (row as Map<String, dynamic>?)?['spans'] as List<dynamic>?;
        final text =
            spans
                ?.map(
                  (span) =>
                      (span as Map<String, dynamic>?)?['text']?.toString() ??
                      '',
                )
                .join() ??
            '';
        return _plainRow(text);
      }).toList();
    }
    return const <StyledRow>[];
  }

  void _onWebSocketError(dynamic error, int generation) {
    if (_disposed || generation != _connectGeneration) return;
    setState(() {
      _connectionStatus = 'Error';
      _connectionStatusColor = const Color(0xffff6b6b);
      _markAttachedSessionsDisconnected();
    });
    _scheduleReconnect();
  }

  void _onWebSocketClosed(int generation) {
    if (_disposed || generation != _connectGeneration) return;
    setState(() {
      _connectionStatus = 'Connection Closed';
      _connectionStatusColor = const Color(0xff7f8b8d);
      if (_needsPairing) {
        _pairingChallengeLoading = false;
        _pairingChallengeError =
            'Connection closed before the pairing challenge could be requested.';
      }
      _markAttachedSessionsDisconnected();
    });
    _scheduleReconnect();
  }

  @override
  void dispose() {
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    _wakeWatchdogTimer?.cancel();
    _connectGeneration++;
    _reconnectTimer?.cancel();
    _credentialStorageTimer?.cancel();
    if (_clientInitialized) {
      _client.disconnect();
      _websocketSubscription?.cancel();
    }
    for (final s in _sessions) {
      s.dispose();
      TerminalPane.destroySession(s.title);
    }
    super.dispose();
  }

  /// The terminal view reported its fitted grid size. Always replay any staged
  /// history at that size; on the *first* fit after a fresh attach, also re-sync
  /// the host to it. The attach snapshot's raw output was authored at the host
  /// PTY width, which may differ from ours — replaying it at our width
  /// wrap-fragments the frame. Resizing the host to our real width (the same
  /// thing the select path does) makes the program redraw at our width and the
  /// live stream paint a clean frame. One-shot per attach so ordinary window
  /// resizes still self-heal through the live stream, not a re-snapshot.
  void _onSessionViewFit(SessionVm session, int cols, int rows) {
    session.lastFittedCols = cols;
    session.lastFittedRows = rows;
    // This device's own view reporting its size. One half of the drift
    // comparison; the other half (`hostSizeCols`) is only ever written from the
    // host's actual size, so this assignment cannot mask another device's
    // resize.
    session.ownFittedCols = cols;
    session.ownFittedRows = rows;
    session.noteViewFit(cols, rows);
    if (!session.hasFitted) {
      session.hasFitted = true;
      if (session.isRemote && _client.isConnected) {
        unawaited(_refreshSessionSnapshot(session, includeHistory: true));
      }
    }
  }

  void _selectSession(int index) {
    if (index < 0 || index >= _sessions.length) return;
    final session = _sessions[index];
    // On a session's first load the view-fit handler issues the initial refresh
    // at the real fitted size; refreshing here too would race it (and use an
    // estimated size). Only refresh on re-select of an already-fitted session.
    final canRefresh =
        _client.isConnected &&
        session.isRemote &&
        _sessionIdFor(session) != null;
    setState(() {
      session.focusCursorOnNextDisplay();
      _selectedIndex = index;
    });
    if (!canRefresh) return;
    // Lazy-load: an unopened session has no live subscription yet (the connect
    // path only attached the initially-selected one), so attach it now instead
    // of refreshing a snapshot it never subscribed to.
    if (!session.loaded) {
      final sid = _sessionIdFor(session);
      if (sid != null) {
        // Selecting a session runs outside the connect path, so a rejected token
        // has to be routed to pairing here — nothing upstream will see it.
        unawaited(
          _loadDaemonSessionInto(
            sid,
            includeHistory: true,
            failedSessionIds: <String>[],
          ).catchError((Object e) {
            if (e is! TriageAuthException || _disposed || _needsPairing) return;
            // Outside the connect path, so the daemon that rejected the token is
            // the one we are attached to right now.
            unawaited(
              _showPairingChallenge(_connectGeneration, _activeServerId),
            );
          }),
        );
      }
      return;
    }
    if (session.hasFitted) {
      // Already fitted: refresh metadata without clearing and replaying history.
      unawaited(_refreshSessionSnapshot(session, includeHistory: false));
    } else {
      // Not yet fitted: the first view-fit issues the initial refresh at the
      // real size; refreshing here too would race it with an estimated size.
      // Guard against a pane that never reports a fit (zero-size or a reused
      // pane that skips onViewFit) by refreshing after the frame if it still
      // hasn't fitted, so the session can't be stranded on stale content.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_disposed &&
            !session.hasFitted &&
            identical(_selectedSession, session) &&
            _client.isConnected) {
          unawaited(_refreshSessionSnapshot(session, includeHistory: true));
        }
      });
    }
  }

  Future<void> _refreshSessionSnapshot(
    SessionVm session, {
    bool includeHistory = false,
  }) async {
    if (!_client.isConnected || !session.isRemote) return;
    final sessionId = _sessionIdFor(session);
    if (sessionId == null) return;
    // Coalesce concurrent refreshes for the same session: a second one would
    // clear the terminal and replay history underneath the first, blanking it.
    if (!_refreshInFlight.add(sessionId)) return;
    try {
      final attachRes = await _client.attachSession(
        sessionId: sessionId,
        clientId: _clientId,
        mode: 'InteractiveController',
      );
      final responseObj = attachRes['response'] as Map<String, dynamic>?;
      final snapshot = responseObj?['snapshot'] as Map<String, dynamic>?;
      if (snapshot != null && !_disposed) {
        var finalSnapshot = snapshot;
        final sizeObj = snapshot['size'] as Map<String, dynamic>?;
        final replayTargetSize = _currentReplayTerminalSize(session, sizeObj);
        // The size the host actually ends this call at, which is not the same
        // as `replayTargetSize`: that is only the size we would like. When the
        // foreground gate below declines to resize, nothing drove the host, and
        // passing our wanted size on as `renderSize` would record "the host is
        // at my size" immediately after deciding not to put it there, which is
        // exactly the evidence the refocus reclaim looks for. Left null in that
        // case so the snapshot's own size is used instead.
        (int, int)? drivenSize;
        if (snapshot['exited'] == true) {
          debugPrint(
            'Session $sessionId is exited/historical during snapshot refresh; calling restoreSession',
          );
          final restoreSize = replayTargetSize;
          try {
            final restoredSnapshot = _snapshotFromResponse(
              await _client.restoreSession(
                sessionId: sessionId,
                rows: restoreSize.$1,
                cols: restoreSize.$2,
              ),
            );
            // A restore re-spawns the process at this size, so the host is
            // genuinely here now whatever the snapshot says.
            drivenSize = restoreSize;
            if (restoredSnapshot != null) {
              finalSnapshot = restoredSnapshot;
            }
            // restoreSession re-spawns a brand-new daemon actor; our prior
            // subscription was bound to the old (now shut-down) actor and
            // receives no further output. Re-subscribe before the fresh attach
            // so live updates from the revived shell keep flowing.
            await _resubscribeSessionEvents(sessionId);
            final freshAttachRes = await _client.attachSession(
              sessionId: sessionId,
              clientId: _clientId,
              mode: 'InteractiveController',
            );
            final freshResponseObj =
                freshAttachRes['response'] as Map<String, dynamic>?;
            final freshSnapshot =
                freshResponseObj?['snapshot'] as Map<String, dynamic>?;
            if (freshSnapshot != null) {
              if (_snapshotSizeMatches(freshSnapshot, replayTargetSize)) {
                finalSnapshot = freshSnapshot;
              }
            }
          } catch (e) {
            debugPrint(
              'Failed to restore session $sessionId during refresh: ${e.toString()}',
            );
          }
        } else if (_clientForeground &&
            !_snapshotSizeMatches(snapshot, replayTargetSize)) {
          // Resize the host so its program repaints at our width, but keep the
          // history-bearing attach snapshot for rendering. The resize response
          // carries no raw_output (resize snapshots never do), so using it would
          // make applyHistory clear the terminal and blank it; history replays
          // at the fitted size client-side anyway.
          //
          // Gated on foreground for the same reason the resize-out listener is:
          // a reconnect on a blurred client would otherwise re-take the shared
          // PTY from whichever device the user is actually looking at. The
          // reclaim on refocus covers the size this skips, which is why
          // `drivenSize` is set only once the resize has actually landed.
          try {
            await _client.resizeSession(
              sessionId: sessionId,
              rows: replayTargetSize.$1,
              cols: replayTargetSize.$2,
            );
            drivenSize = replayTargetSize;
          } catch (_) {}
        }
        await _applySnapshotToSession(
          session,
          sessionId,
          finalSnapshot,
          renderSize: drivenSize,
          replayHistory: includeHistory || snapshot['exited'] == true,
        );
      }
    } catch (_) {
    } finally {
      _refreshInFlight.remove(sessionId);
    }
  }

  /// Re-subscribes to a session's events, dropping any stale subscription ids
  /// for it. Used after a restore, whose new daemon actor leaves the previous
  /// subscription bound to a shut-down actor that emits nothing further.
  Future<void> _resubscribeSessionEvents(String sessionId) async {
    _subscriptionIds.removeWhere((_, sid) => sid == sessionId);
    final subId = await _client.subscribeSessionEvents(sessionId: sessionId);
    if (subId.isNotEmpty) {
      _subscriptionIds[subId] = sessionId;
    }
  }

  String? _sessionIdFor(SessionVm session) {
    return session.remoteSessionId;
  }

  void _createSession(NewSessionShell preferredShell) async {
    if (_client.isConnected) {
      setState(() {
        _newSessionShell = preferredShell;
        _connectionStatus = 'Creating session...';
        _connectionStatusColor = const Color(0xffffc857);
      });
      String sessionId = '';
      String? subId;
      try {
        Object? lastSpawnError;
        var spawned = false;
        for (final shell in newSessionShellFallbackChain(preferredShell)) {
          try {
            final startedId = await _client.startSession(
              command: shell.command,
              args: shell.args,
            );
            // `startSession` degrades a response with no `session_id` to '',
            // which there is nothing to subscribe or attach to. Treat it as a
            // failed attempt so the chain keeps going instead of breaking out
            // into a create that silently does nothing and strands the rail on
            // "Creating session...".
            if (startedId.isEmpty) {
              lastSpawnError = Exception(
                'daemon returned no session id for ${shell.command}',
              );
              continue;
            }
            sessionId = startedId;
            spawned = true;
            break;
          } on TriageAuthException {
            // Credentials, not the shell: no other command will fare better,
            // and the pairing screen needs this to propagate.
            rethrow;
          } catch (e) {
            lastSpawnError = e;
          }
        }
        if (!spawned) {
          throw lastSpawnError ?? Exception('no shell could be started');
        }
        if (sessionId.isNotEmpty) {
          // Subscribe to events first so we don't miss welcome messages
          subId = await _client.subscribeSessionEvents(sessionId: sessionId);
          if (subId.isNotEmpty) {
            _subscriptionIds[subId] = sessionId;
          }

          final attachRes = await _client.attachSession(
            sessionId: sessionId,
            clientId: _clientId,
            mode: 'InteractiveController',
          );
          final responseObj = attachRes['response'] as Map<String, dynamic>?;
          final snapshot = responseObj?['snapshot'] as Map<String, dynamic>?;
          final contextObj = snapshot?['context'] as Map<String, dynamic>?;
          final branch = contextObj?['branch']?.toString();
          final repoRoot = contextObj?['repository_root']?.toString();
          final worktreeRoot = contextObj?['worktree_root']?.toString();
          final cwd = snapshot?['current_working_directory']?.toString();

          final plainRows = _plainRowsFromSnapshot(snapshot);
          final exited = snapshot?['exited'] as bool? ?? false;
          final outputSeq = snapshot?['output_seq'] as int? ?? 0;

          final session = SessionVm(
            title: 'triage / $sessionId',
            branch: branch,
            repoRoot: repoRoot,
            worktreeRoot: worktreeRoot,
            cwd: cwd,
            status: exited ? 'exited' : 'attached',
            statusColor: exited
                ? const Color(0xff7f8b8d)
                : const Color(0xff7fd1c7),
            icon: Icons.terminal,
            rows: plainRows.isEmpty
                ? [_plainRow('Attached to session $sessionId')]
                : plainRows,
            isRemote: true,
            isExited: exited,
          );
          session.snippet = snapshot?['snippet'] as String?;
          session.snippetDetail = snapshot?['snippet_detail'] as String?;
          final bracketedPaste =
              snapshot?['bracketed_paste_enabled'] as bool? ?? false;
          session.setBracketedPasteEnabled(bracketedPaste);
          _setupSessionInputListener(session);
          session.applyHistory(
            _rawOutputFromSnapshot(snapshot ?? const {}),
            throughOutputSeq: outputSeq,
          );

          // Rank it above everything already on the rail. The daemon has no
          // output for a session it just spawned, so it reports activity 0, and
          // a session left at 0 sorts as "never active", sinking the one just
          // asked for to the bottom on the next re-group. Derived from the
          // stamps already in hand rather than from `DateTime.now()`, which
          // would rank a local clock against daemon-issued ones: a client
          // running behind the daemon would bury the new session, the exact
          // outcome this is here to prevent. The real stamp arrives with the
          // next context fetch and takes over.
          session.lastActivityMs = _nextLocalActivityStamp();

          setState(() {
            _sessions.insert(0, session);
            _selectedIndex = 0;
            _connectionStatus = 'Connected to Daemon';
            _connectionStatusColor = const Color(0xff7fd1c7);
          });
          // Insertion alone leaves it outside every group (rendered under no
          // header, above the first one) until something else triggers a
          // re-group. Place it in its repository now, keeping the selection that
          // was just set on it.
          _regroupRail();

          // Drain and replay any pending events that arrived during attach
          final pending = _pendingEvents.remove(sessionId);
          if (pending != null) {
            for (final msg in pending) {
              _onWebSocketEvent(msg);
            }
          }
          // Host re-sync to our real width is deferred to the first view fit
          // (_onSessionViewFit); doing it here would use an estimated size,
          // since the terminal view has not laid out yet.
        }
      } catch (e, stackTrace) {
        // Roll back partial state so a failed create doesn't strand a subscription
        // id or accumulate buffered events for a session that will never appear.
        if (subId != null && subId.isNotEmpty) {
          _subscriptionIds.remove(subId);
        }
        if (sessionId.isNotEmpty) {
          _pendingEvents.remove(sessionId);
        }
        // The daemon's reason (e.g. "spawning PTY child") is the only clue the
        // user gets; swallowing it left the rail showing a bare failure with
        // nothing to act on. The trace distinguishes a spawn failure from a
        // later subscribe/attach one, which the message alone does not.
        debugPrint('Failed to create session: $e\n$stackTrace');
        setState(() {
          _connectionStatus = 'Error creating session';
          _connectionStatusColor = const Color(0xffff6b6b);
        });
      }
      return;
    }

    final scratchId = _createdSessionCount + 1;
    final session = SessionVm(
      title: 'triage / scratch-$scratchId',
      branch: 'experiment/flutter-spike',
      status: 'idle',
      statusColor: const Color(0xff7f8b8d),
      icon: Icons.add_circle_outline,
      rows: [
        _promptRow('triage session new'),
        _plainRow('created scratch session $scratchId'),
        _plainRow(''),
        _plainRow('ready'),
      ],
    );
    _setupSessionInputListener(session);

    setState(() {
      _createdSessionCount = scratchId;
      _sessions.insert(0, session);
      _selectedIndex = 0;
    });
  }

  Future<void> _closeSession(SessionVm session) async {
    final confirmed = await _confirmCloseSession(session);
    if (confirmed != true) return;

    final sessionId = session.remoteSessionId;

    if (_client.isConnected && sessionId != null) {
      try {
        await _client.shutdownSession(sessionId: sessionId);
      } catch (e) {
        debugPrint('Failed to shutdown session: ${e.toString()}');
      }
    }

    // The dialog and shutdown RPC both await; the State may have been disposed
    // in the meantime, so guard setState to avoid throwing on a dead widget.
    if (!mounted) return;

    setState(() {
      final index = _sessions.indexOf(session);
      if (index != -1) {
        _sessions.removeAt(index);
        session.dispose();
        TerminalPane.destroySession(session.title);
        if (_selectedIndex >= _sessions.length) {
          _selectedIndex = _sessions.isEmpty ? 0 : _sessions.length - 1;
        }
      }
    });

    // Drop the pin with the session. A pin naming a session that is merely not
    // running is deliberately kept: that is the slot being held for when it
    // comes back, but a session closed on purpose is never coming back under
    // that id, so its pin is dead weight: it would keep the reset control
    // showing with no indicator anywhere to explain it, and sit in this
    // server's preferences forever.
    if (sessionId != null) {
      if (_pins.sessionIds.contains(sessionId)) {
        _applyPins(unpin(_pins, sessionId: sessionId));
      }
      if (_customLabels.containsKey(sessionId) ||
          _customLabels.containsKey('triage / $sessionId')) {
        _customLabels.remove(sessionId);
        _customLabels.remove('triage / $sessionId');
        unawaited(_persistCustomLabels());
        if (_clientInitialized && _client.isConnected) {
          unawaited(
            _client
                .setSessionCustomLabel(
                  sessionId: sessionId,
                  customLabel: null,
                )
                .catchError((_) {}),
          );
        }
      }
    }
  }

  Future<void> _toggleSessionJudgePolicy(SessionVm session) async {
    final sessionId = session.remoteSessionId;
    if (!_client.isConnected || sessionId == null) return;
    final nextState = !session.judgePolicyEffective;
    try {
      final updated = await _client.setSessionJudgePolicy(sessionId, nextState);
      if (updated != null && mounted) {
        setState(() {
          session.applyJudgePolicy(
            explicit: updated.explicit,
            effective: updated.effective,
          );
        });
      }
    } catch (e) {
      debugPrint('Failed to set judge policy for $sessionId: $e');
    }
  }

  Future<bool?> _confirmCloseSession(SessionVm session) {
    return showDialog<bool>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.55),
      builder: (dialogContext) {
        return AlertDialog(
          backgroundColor: const Color(0xff161b1d),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: const BorderSide(color: Color(0xff2a3437)),
          ),
          title: const Text(
            'Close session?',
            style: TextStyle(
              color: Color(0xffcdd7d6),
              fontSize: 18,
              fontWeight: FontWeight.w700,
            ),
          ),
          content: Text(
            session.isRemote
                ? 'This ends the terminal session "${session.title}" and its '
                      'running processes. This cannot be undone.'
                : 'This closes the terminal session "${session.title}". This '
                      'cannot be undone.',
            style: const TextStyle(color: Color(0xff9aa6a8), height: 1.4),
          ),
          actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              style: TextButton.styleFrom(
                foregroundColor: const Color(0xff7f8b8d),
              ),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xffb3443f),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 12,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              child: const Text('Close session'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _showSessionContextMenu(
    SessionVm session,
    Offset position,
  ) async {
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (overlay == null) return;
    final rect = RelativeRect.fromRect(
      position & Size.zero,
      Offset.zero & overlay.size,
    );

    final hasLabel = session.trimmedCustomLabel != null;
    final result = await showMenu<String>(
      context: context,
      position: rect,
      color: const Color(0xff1b2327),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: const BorderSide(color: Color(0xff334044)),
      ),
      items: [
        PopupMenuItem<String>(
          value: 'edit_label',
          height: 38,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: Row(
            children: [
              Icon(
                hasLabel ? Icons.edit_outlined : Icons.label_outline,
                size: 16,
                color: const Color(0xff7fd1c7),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  hasLabel ? 'Edit custom label...' : 'Assign custom label...',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Color(0xffcdd7d6),
                    fontSize: 13,
                  ),
                ),
              ),
            ],
          ),
        ),
        if (hasLabel)
          PopupMenuItem<String>(
            value: 'clear_label',
            height: 38,
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: const Row(
              children: [
                Icon(
                  Icons.label_off_outlined,
                  size: 16,
                  color: Color(0xffe06c75),
                ),
                SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Clear custom label',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: Color(0xffcdd7d6),
                      fontSize: 13,
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );

    if (!mounted || result == null) return;

    if (result == 'edit_label') {
      await _openCustomLabelDialog(session);
    } else if (result == 'clear_label') {
      _setSessionCustomLabel(session, null);
    }
  }

  Future<void> _openCustomLabelDialog(SessionVm session) async {
    final result = await showDialog<String>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.55),
      builder: (dialogContext) => _CustomLabelDialog(
        initialLabel: session.customLabel,
      ),
    );

    if (!mounted || result == null) return;
    _setSessionCustomLabel(session, result);
  }

  bool _allowExit = false;
  bool _exitDialogInFlight = false;

  Future<void> _handlePopInvoked(bool didPop, dynamic result) async {
    if (didPop || _allowExit || _exitDialogInFlight || !mounted) return;
    _exitDialogInFlight = true;
    final bool? shouldLeave;
    try {
      shouldLeave = await _showExitConfirmationDialog();
    } finally {
      _exitDialogInFlight = false;
    }
    if (shouldLeave == true && mounted) {
      setState(() => _allowExit = true);
      allowWebExit();
      await SystemNavigator.pop();
      Future.delayed(const Duration(seconds: 1), () {
        resetWebExit();
        if (mounted) {
          setState(() => _allowExit = false);
        }
      });
    }
  }

  Future<bool?> _showExitConfirmationDialog() {
    return showDialog<bool>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.55),
      builder: (dialogContext) => AlertDialog(
        backgroundColor: const Color(0xff161b1d),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: Color(0xff2a3437)),
        ),
        title: const Text(
          'Exit Triage?',
          style: TextStyle(
            color: Color(0xffcdd7d6),
            fontSize: 18,
            fontWeight: FontWeight.w700,
          ),
        ),
        content: SizedBox(
          width: 360,
          child: Text(
            kIsWeb
                ? 'Are you sure you want to leave Triage and go back to the previous page?'
                : 'Are you sure you want to exit Triage?',
            style: const TextStyle(
              color: Color(0xff8b9799),
              fontSize: 14,
              height: 1.4,
            ),
          ),
        ),
        actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            style: TextButton.styleFrom(
              foregroundColor: const Color(0xff7f8b8d),
            ),
            child: const Text('Stay'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xffe06c75),
              foregroundColor: const Color(0xff111517),
            ),
            child: const Text('Leave'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    Widget content;
    if (_needsConnectionConfig) {
      content = Scaffold(
        body: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConnectionSettingsForm(
              submitLabel: 'Connect',
              title: 'Connect to a Triage daemon',
              subtitle:
                  'Enter the host, IP, or URL of the device running triaged. '
                  'For example 100.64.2.7, 192.168.1.5:7777, or '
                  'wss://my-mac.tailnet:7777.',
              onSubmit: (raw, label) => _addServer(raw, label: label),
            ),
          ),
        ),
      );
    } else if (_needsPairing) {
      content = Scaffold(
        body: Center(
          child: SingleChildScrollView(
            child: Container(
              width: 520,
              padding: const EdgeInsets.all(32),
              decoration: BoxDecoration(
                color: const Color(0xff161b1d),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: const Color(0xff2a3437)),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.4),
                    blurRadius: 24,
                    offset: const Offset(0, 8),
                  ),
                ],
              ),
              child: _PairingView(
                deviceCode: _pairingDeviceCode,
                verificationUri: _pairingVerificationUri,
                daemonHostUri: _pairingDaemonHostUri,
                expiresAt: _pairingExpiresAt,
                isChallengeLoading: _pairingChallengeLoading,
                challengeError: _pairingChallengeError,
                onRefreshChallenge: () => _requestPairingChallenge(),
                onPair: _onPairRequested,
                onCancel: () async {
                  try {
                    await _client.disconnect().catchError((_) {});
                    await _websocketSubscription?.cancel().catchError((_) {});
                    _reconnectTimer?.cancel();
                  } catch (_) {}
                  if (!mounted) return;
                  setState(() {
                    _needsPairing = false;
                    _connectionStatus = 'Offline (Local Mock)';
                    _connectionStatusColor = const Color(0xff7f8b8d);
                  });
                },
              ),
            ),
          ),
        ),
      );
    } else {
      final isMobile = isMobilePlatform();
      final hasSelectedSession =
          _selectedIndex >= 0 && _selectedIndex < _sessions.length;
      if (!hasSelectedSession) {
        if (_sessions.isNotEmpty) {
          _selectedIndex = 0;
        }
      }

      void collapseRail() {
        if (!_sidebarCollapsed) setState(() => _sidebarCollapsed = true);
      }

      void openRail() {
        if (!_sidebarCollapsed) return;
        setState(() => _sidebarCollapsed = false);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          final tileContext = _selectedTileKey.currentContext;
          if (tileContext == null) return;
          Scrollable.ensureVisible(
            tileContext,
            alignment: 0,
            duration: _sessionRailAnimationDuration,
            curve: Curves.easeOutCubic,
          );
        });
      }

      final rail = SessionRail(
        sessions: _sessions,
        sessionGroups: _sessionGroups,
        pins: _pins,
        onResetOrder: _resetRailOrder,
        onUnpinGroup: _unpinGroup,
        onUnpinSession: _unpinSession,
        onSessionContextMenu: _showSessionContextMenu,
        selectedIndex: _selectedIndex,
        selectedTileKey: _selectedTileKey,
        onSelectSession: (index) {
          _selectSession(index);
          if (isMobile) collapseRail();
        },
        onReorderSession: _reorderRail,
        railListKey: _railListKey,
        onRailDragStart: _railDragStarted,
        onRailDragEnd: _railDragEnded,
        draggingGroupKey: _draggingRailGroup,
        onCreateSession: (shell) {
          _createSession(shell);
          if (isMobile) collapseRail();
        },
        selectedShell: _newSessionShell,
        shellOptions: newSessionShellMenuOrderForPlatform(defaultTargetPlatform),
        showShellMenu: showNewSessionShellMenuForPlatform(defaultTargetPlatform),
        connectionStatus: _connectionStatus,
        connectionStatusColor: _connectionStatusColor,
        serverLabel: _activeServer?.label,
        onOpenSettings: _openConnectionSettings,
        onToggleJudgePolicy: _toggleSessionJudgePolicy,
        isCollapsed: isMobile ? false : _sidebarCollapsed,
        onToggleCollapse: isMobile
            ? collapseRail
            : () {
                setState(() {
                  _sidebarCollapsed = !_sidebarCollapsed;
                });
              },
      );

      const emptyWorkspace = Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.terminal, size: 64, color: Color(0xff263033)),
            SizedBox(height: 16),
            Text(
              'No active sessions',
              style: TextStyle(
                fontSize: 18,
                color: Color(0xff7f8b8d),
                fontWeight: FontWeight.w600,
              ),
            ),
            SizedBox(height: 8),
            Text(
              'Create a new session by clicking the "+" button on the sidebar.',
              style: TextStyle(fontSize: 14, color: Color(0xff7f8b8d)),
            ),
          ],
        ),
      );

      final workspace = _sessions.isEmpty
          ? emptyWorkspace
          : SessionWorkspace(
              session: _selectedSession,
              onCloseSession: () => _closeSession(_selectedSession),
              onViewFit: (cols, rows) =>
                  _onSessionViewFit(_selectedSession, cols, rows),
              onToggleJudge: () => _toggleSessionJudgePolicy(_selectedSession),
              onOpenRail: isMobile ? openRail : null,
              onRefit: _refitAndFocusActiveSession,
            );

      if (isMobile) {
        final screenWidth = MediaQuery.of(context).size.width;
        final overlayWidth = screenWidth < _sessionRailExpandedWidth
            ? screenWidth
            : _sessionRailExpandedWidth;
        content = Scaffold(
          body: SafeArea(
            child: Stack(
              children: [
                Positioned.fill(child: workspace),
                if (_sidebarCollapsed && _sessions.isEmpty)
                  Positioned(
                    top: 4,
                    left: 4,
                    child: IconButton(
                      icon: const Icon(Icons.menu, color: Color(0xffcdd7d6)),
                      tooltip: 'Sessions',
                      onPressed: openRail,
                    ),
                  ),
                Positioned.fill(
                  child: IgnorePointer(
                    ignoring: _sidebarCollapsed,
                    child: AnimatedOpacity(
                      opacity: _sidebarCollapsed ? 0.0 : 1.0,
                      duration: _sessionRailAnimationDuration,
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: collapseRail,
                        child: const ColoredBox(color: Color(0x99000000)),
                      ),
                    ),
                  ),
                ),
                AnimatedPositioned(
                  duration: _sessionRailAnimationDuration,
                  curve: Curves.easeOutCubic,
                  top: 0,
                  bottom: 0,
                  left: _sidebarCollapsed ? -overlayWidth : 0,
                  width: overlayWidth,
                  child: Material(
                    elevation: 16,
                    color: const Color(0xff0d1113),
                    child: rail,
                  ),
                ),
              ],
            ),
          ),
        );
      } else {
        content = Scaffold(
          body: SafeArea(
            child: Row(
              children: [
                rail,
                const VerticalDivider(
                  width: 1,
                  thickness: 1,
                  color: Color(0xff263033),
                ),
                Expanded(child: workspace),
              ],
            ),
          ),
        );
      }
    }

    return PopScope(
      canPop: _allowExit,
      onPopInvokedWithResult: _handlePopInvoked,
      child: content,
    );
  }
}

/// Lifts the row being dragged off the rail with a shadow.
///
/// `ReorderableListView` supplied this for free and `ReorderableList` does not,
/// so it is reproduced here rather than lost in the swap. `Colors.transparent`
/// keeps the row's own background: the rail paints its tiles itself, and an
/// opaque `Material` underneath them would flash the theme's surface colour for
/// the duration of the drag.
Widget _railDragProxyDecorator(
  Widget child,
  int index,
  Animation<double> animation,
) => AnimatedBuilder(
  animation: animation,
  builder: (context, decorated) => Material(
    color: Colors.transparent,
    shadowColor: const Color(0xff000000),
    elevation: Curves.easeInOut.transform(animation.value) * 6,
    child: decorated,
  ),
  child: child,
);

class SessionRail extends StatefulWidget {
  const SessionRail({
    super.key,
    required this.sessions,
    required this.sessionGroups,
    required this.pins,
    required this.onResetOrder,
    required this.onUnpinGroup,
    required this.onUnpinSession,
    required this.selectedIndex,
    required this.onSelectSession,
    required this.onReorderSession,
    required this.railListKey,
    required this.onRailDragStart,
    required this.onRailDragEnd,
    required this.draggingGroupKey,
    required this.onCreateSession,
    required this.selectedShell,
    required this.shellOptions,
    required this.showShellMenu,
    required this.connectionStatus,
    required this.connectionStatusColor,
    required this.onOpenSettings,
    required this.isCollapsed,
    required this.onToggleCollapse,
    this.onToggleJudgePolicy,
    this.onSessionContextMenu,
    this.serverLabel,
    this.selectedTileKey,
  });

  final List<SessionVm> sessions;
  // Repository grouping for [sessions], in the same order. Empty only before the
  // first load, or with no sessions: a daemon that reports no context at all
  // (pre-upgrade) still yields one repo-less group, and `buildRailItems` then
  // suppresses headers because there is only one, so the rail reads as a flat
  // ungrouped run without this list being empty.
  final List<SessionGroup> sessionGroups;
  // Which rows and groups the user placed by hand. Drives the pin indicators and
  // whether the reset action is offered at all.
  final SessionPins pins;
  // Drops every pin, returning the rail to activity ordering.
  final VoidCallback onResetOrder;
  // Release a single group or row, leaving the rest of the layout intact. Bound
  // to the pin indicator itself rather than a context menu: on touch, the rail's
  // long-press is already the drag trigger, so a menu would compete with it.
  final ValueChanged<String> onUnpinGroup;
  final ValueChanged<String> onUnpinSession;
  final int selectedIndex;
  // Attached to the selected session's tile so the host can scroll it to the
  // top when the rail (re)opens.
  final Key? selectedTileKey;
  final ValueChanged<int> onSelectSession;
  final ValueChanged<SessionVm>? onToggleJudgePolicy;
  final void Function(List<RailItem> items, int oldIndex, int newIndex)
  onReorderSession;

  /// Lets the host cancel a drag in progress before it re-groups the rail.
  final GlobalKey<ReorderableListState> railListKey;

  /// Drag lifecycle, reported to the host because it owns [draggingGroupKey].
  /// [onRailDragStart] is given the item list the drag was measured against, so
  /// the host can tell a header from a row without rebuilding it.
  final void Function(List<RailItem> items, int index) onRailDragStart;
  final VoidCallback onRailDragEnd;

  /// The group whose header is currently being dragged, or null. Its rows are
  /// drawn as lifted, so that dragging a header reads as moving the whole group
  /// rather than detaching a label from the rows it names.
  ///
  /// The rows are dimmed in place rather than actually moved: `ReorderableList`
  /// lifts exactly one child, and reordering the rest mid-drag is what
  /// duplicates its per-child `GlobalKey` and throws (see `_regroupRail`).
  ///
  /// The dimming is also the only feedback available. The floating proxy is
  /// built from the child captured when the drag began, so it does not rebuild
  /// as this changes: labelling the lifted header with what it carries was
  /// tried and renders nothing. Anything that has to react during a drag has to
  /// live in the list body, as this does.
  final String? draggingGroupKey;
  final ValueChanged<NewSessionShell> onCreateSession;
  final NewSessionShell selectedShell;
  final List<NewSessionShell> shellOptions;
  final bool showShellMenu;
  final String connectionStatus;
  final Color connectionStatusColor;
  // Name of the daemon these sessions belong to. Null when none is configured
  // (the injected-client test path).
  final String? serverLabel;
  final VoidCallback onOpenSettings;
  final void Function(SessionVm session, Offset position)? onSessionContextMenu;
  final bool isCollapsed;
  final VoidCallback onToggleCollapse;

  @override
  State<SessionRail> createState() => _SessionRailState();
}

class _SessionRailState extends State<SessionRail> {
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();
  String _searchQuery = '';
  bool _searchOpen = false;
  Offset _lastTapDownPosition = Offset.zero;

  @override
  void initState() {
    super.initState();
    _searchFocusNode.onKeyEvent = (node, event) {
      if (event is KeyDownEvent &&
          event.logicalKey == LogicalKeyboardKey.escape) {
        _closeSearch();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    };
  }

  @override
  void didUpdateWidget(SessionRail oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isCollapsed && !oldWidget.isCollapsed) {
      _closeSearch();
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    _searchFocusNode.dispose();
    super.dispose();
  }

  void _onSearchChanged(String value) {
    setState(() {
      _searchQuery = value;
    });
  }

  void _toggleSearch() {
    setState(() {
      _searchOpen = !_searchOpen;
      if (_searchOpen) {
        _searchFocusNode.requestFocus();
      } else {
        _searchController.clear();
        _searchQuery = '';
      }
    });
  }

  void _closeSearch() {
    setState(() {
      _searchOpen = false;
      _searchController.clear();
      _searchQuery = '';
    });
  }

  @override
  Widget build(BuildContext context) {
    final railWidth = widget.isCollapsed
        ? _sessionRailCollapsedWidth
        : _sessionRailExpandedWidth;

    return AnimatedContainer(
      duration: _sessionRailAnimationDuration,
      curve: Curves.easeOutCubic,
      width: railWidth,
      clipBehavior: Clip.hardEdge,
      decoration: const BoxDecoration(color: Color(0xff151a1d)),
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 160),
        switchInCurve: Curves.easeOut,
        switchOutCurve: Curves.easeIn,
        layoutBuilder: (currentChild, previousChildren) {
          return Stack(
            alignment: Alignment.topLeft,
            children: [
              ...previousChildren,
              if (currentChild != null) currentChild,
            ],
          );
        },
        child: OverflowBox(
          key: ValueKey<bool>(widget.isCollapsed),
          alignment: Alignment.topLeft,
          minWidth: railWidth,
          maxWidth: railWidth,
          child: SizedBox(
            width: railWidth,
            child: widget.isCollapsed ? _buildCollapsedRail() : _buildExpandedRail(),
          ),
        ),
      ),
    );
  }

  Widget _buildCollapsedRail() {
    return Column(
      children: [
        const SizedBox(height: 20),
        IconButton(
          onPressed: widget.onToggleCollapse,
          tooltip: 'Expand sidebar',
          icon: const Icon(
            Icons.chevron_right,
            color: Color(0xff7fd1c7),
            size: 26,
          ),
        ),
        const SizedBox(height: 16),
        _NewSessionMenu(
          selectedShell: widget.selectedShell,
          shellOptions: widget.shellOptions,
          showShellMenu: widget.showShellMenu,
          onCreateSession: widget.onCreateSession,
        ),
        const SizedBox(height: 16),
        Tooltip(
          message: widget.serverLabel == null
              ? widget.connectionStatus
              : '${widget.serverLabel} — ${widget.connectionStatus}',
          child: Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: widget.connectionStatusColor,
            ),
          ),
        ),
        const SizedBox(height: 8),
        IconButton(
          onPressed: widget.onOpenSettings,
          tooltip: 'Daemons',
          icon: const Icon(
            Icons.settings,
            color: Color(0xff7f8b8d),
            size: 20,
          ),
        ),
        const SizedBox(height: 12),
        const Divider(height: 1, color: Color(0xff263033)),
        const SizedBox(height: 8),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Column(
              children: [
                for (final indexed in widget.sessions.indexed)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Tooltip(
                      message: indexed.$2.displayTitle,
                      child: InkWell(
                        onTap: () => widget.onSelectSession(indexed.$1),
                        onTapDown: widget.onSessionContextMenu != null
                            ? (details) =>
                                _lastTapDownPosition = details.globalPosition
                            : null,
                        onSecondaryTapDown: widget.onSessionContextMenu != null
                            ? (details) => widget.onSessionContextMenu!(
                                  indexed.$2,
                                  details.globalPosition,
                                )
                            : null,
                        onLongPress: widget.onSessionContextMenu != null
                            ? () => widget.onSessionContextMenu!(
                                  indexed.$2,
                                  _lastTapDownPosition,
                                )
                            : null,
                        borderRadius: BorderRadius.circular(8),
                        child: Container(
                          width: 48,
                          height: 48,
                          decoration: BoxDecoration(
                            color: indexed.$1 == widget.selectedIndex
                                ? const Color(0xff233033)
                                : Colors.transparent,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                              color: indexed.$1 == widget.selectedIndex
                                  ? const Color(0xff3b5356)
                                  : Colors.transparent,
                            ),
                          ),
                          child: Icon(
                            indexed.$2.icon,
                            color: indexed.$1 == widget.selectedIndex
                                ? const Color(0xff7fd1c7)
                                : const Color(0xffcdd7d6),
                            size: 22,
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildExpandedRail() {
    // Once per build, not once per row: the item builder runs lazily and this
    // is a whole-list property. One clock for the whole frame, captured for the
    // lazy item builder below so grouping and titles resolve the inferred-worktree
    // window at the same instant.
    final now = DateTime.now();
    final indistinguishable = indistinguishableRailRows(widget.sessions, now);
    final rawQuery = _searchQuery.trim();
    final query = rawQuery.toLowerCase();
    final isSearching = query.isNotEmpty;

    final matchingEntries = <({int originalIndex, SessionVm session})>[];
    for (var i = 0; i < widget.sessions.length; i++) {
      final session = widget.sessions[i];
      if (!isSearching || session.matchesSearch(query, now, true)) {
        matchingEntries.add((originalIndex: i, session: session));
      }
    }

    // Headers and rows share one list so there is a single gesture arena;
    // `resolveRailReorder` maps a flat drop index back to the right level. Built
    // from the rail's own sessions, so a session started since the last grouping
    // still gets a row (ungrouped) rather than vanishing until the next load.
    final items = buildRailItems([
      for (final entry in matchingEntries) _rowKeyFor(entry.session),
    ], widget.sessionGroups);
    // Rows appear in `items` in the same order as `sessions`, so the nth
    // non-header item is the nth session.
    var rowIndex = 0;
    final rowIndexFor = <int, int>{};
    for (var i = 0; i < items.length; i++) {
      if (!items[i].isHeader) rowIndexFor[i] = rowIndex++;
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 10, 16),
          child: Row(
            children: [
              const Icon(Icons.terminal, size: 24, color: Color(0xff7fd1c7)),
              const SizedBox(width: 10),
              const Expanded(
                child: Text(
                  'Triage',
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
                ),
              ),
              IconButton(
                onPressed: widget.onToggleCollapse,
                tooltip: 'Minimize sidebar',
                icon: const Icon(
                  Icons.chevron_left,
                  color: Color(0xff7f8b8d),
                  size: 22,
                ),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
              ),
              const SizedBox(width: 4),
              IconButton(
                onPressed: _toggleSearch,
                tooltip: 'Search sessions',
                icon: Icon(
                  Icons.search,
                  color: _searchOpen || isSearching
                      ? const Color(0xff7fd1c7)
                      : const Color(0xff7f8b8d),
                  size: 20,
                ),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
              ),
              const SizedBox(width: 4),
              IconButton(
                onPressed: widget.onOpenSettings,
                tooltip: 'Daemons',
                icon: const Icon(
                  Icons.settings,
                  color: Color(0xff7f8b8d),
                  size: 20,
                ),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
              ),
              const SizedBox(width: 4),
              _NewSessionMenu(
                selectedShell: widget.selectedShell,
                shellOptions: widget.shellOptions,
                showShellMenu: widget.showShellMenu,
                onCreateSession: widget.onCreateSession,
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          // Tapping the status opens connection settings — the recovery path
          // when a connect attempt fails.
          child: InkWell(
            onTap: widget.onOpenSettings,
            borderRadius: BorderRadius.circular(8),
            child: _ConnectionStatus(
              status: widget.connectionStatus,
              color: widget.connectionStatusColor,
              serverLabel: widget.serverLabel,
            ),
          ),
        ),
        const SizedBox(height: 18),
        Padding(
          padding: const EdgeInsets.only(left: 20, right: 12),
          child: Row(
            children: [
              const Expanded(
                child: Text(
                  'SESSIONS',
                  style: TextStyle(
                    color: Color(0xff7f8b8d),
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0,
                  ),
                ),
              ),
              // Only offered once something is actually pinned, so it doubles as
              // the signal that the rail is holding a manual order at all.
              if (!widget.pins.isEmpty && !isSearching)
                IconButton(
                  onPressed: widget.onResetOrder,
                  icon: const Icon(Icons.restart_alt, size: 16),
                  color: const Color(0xff7f8b8d),
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(
                    minWidth: 28,
                    minHeight: 28,
                  ),
                  tooltip: 'Sort by activity (clears pinned order)',
                ),
            ],
          ),
        ),
        if (_searchOpen || isSearching) ...[
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Container(
              height: 34,
              decoration: BoxDecoration(
                color: const Color(0xff1b2327),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: isSearching
                      ? const Color(0xff4a6266)
                      : const Color(0xff2b373a),
                ),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Row(
                children: [
                  const Icon(
                    Icons.search,
                    size: 16,
                    color: Color(0xff7f8b8d),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: TextField(
                      focusNode: _searchFocusNode,
                      controller: _searchController,
                      autofocus: true,
                      onChanged: _onSearchChanged,
                      style: const TextStyle(
                        color: Color(0xffcdd7d6),
                        fontSize: 12,
                      ),
                      cursorColor: const Color(0xff7fd1c7),
                      decoration: const InputDecoration(
                        hintText: 'Search sessions...',
                        hintStyle: TextStyle(
                          color: Color(0xff607073),
                          fontSize: 12,
                        ),
                        border: InputBorder.none,
                        isDense: true,
                        contentPadding: EdgeInsets.symmetric(vertical: 6),
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: _closeSearch,
                    icon: const Icon(Icons.close, size: 14),
                    color: const Color(0xff7f8b8d),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                    tooltip: 'Close search',
                  ),
                ],
              ),
            ),
          ),
        ],
        const SizedBox(height: 8),
        Expanded(
          child: isSearching && matchingEntries.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Icons.search_off,
                          size: 32,
                          color: Color(0xff526366),
                        ),
                        const SizedBox(height: 8),
                        const Text(
                          'No matching sessions',
                          style: TextStyle(
                            color: Color(0xff8b9799),
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'No session matches "$rawQuery"',
                          textAlign: TextAlign.center,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Color(0xff607073),
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                )
              : Listener(
                  onPointerUp: (_) =>
                      isSearching ? null : widget.onRailDragEnd(),
                  onPointerCancel: (_) =>
                      isSearching ? null : widget.onRailDragEnd(),
                  child: ReorderableList(
                    key: widget.railListKey,
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
                    proxyDecorator: _railDragProxyDecorator,
                    onReorderItem: (oldIndex, newIndex) => isSearching
                        ? null
                        : widget.onReorderSession(items, oldIndex, newIndex),
                    onReorderStart: (index) => isSearching
                        ? null
                        : widget.onRailDragStart(items, index),
                    onReorderEnd: (_) =>
                        isSearching ? null : widget.onRailDragEnd(),
                    itemCount: items.length,
                    itemBuilder: (context, index) {
                      final item = items[index];
                      if (item.isHeader) {
                        return _SessionGroupHeader(
                          key: ValueKey<String>('group:${item.groupKey}'),
                          index: index,
                          label: _groupLabelFor(item.groupKey),
                          pinned: widget.pins.groupKeys.contains(item.groupKey),
                          onUnpin: () => widget.onUnpinGroup(item.groupKey),
                          isFirst: index == 0,
                          canDrag: !isSearching,
                        );
                      }
                      final matchIndex = rowIndexFor[index]!;
                      final entry = matchingEntries[matchIndex];
                      final session = entry.session;
                      final originalIndex = entry.originalIndex;
                      final key = ValueKey<String>(_rowKeyFor(session));
                      final tile = SessionListTile(
                        key: originalIndex == widget.selectedIndex
                            ? widget.selectedTileKey
                            : null,
                        selected: originalIndex == widget.selectedIndex,
                        title: session.railTitleAt(now),
                        glanceTitle: session.glanceTitleAt(now),
                        subtitle: session.status,
                        statusColor: session.statusColor,
                        icon: session.icon,
                        branch: session.branch,
                        repoName: session.repoName,
                        worktreeName: session.worktreeName,
                        cwd: session.cwd,
                        snippet: session.snippet,
                        snippetDetail: session.snippetDetail,
                        activityAt: session.snippetUpdatedAt,
                        pinned: widget.pins.sessionIds
                            .contains(session.remoteSessionId),
                        onUnpin: session.remoteSessionId == null
                            ? null
                            : () =>
                                widget.onUnpinSession(session.remoteSessionId!),
                        indistinguishable:
                            indistinguishable.contains(originalIndex),
                        judgeEffective: session.judgePolicyEffective,
                        judgeExplicit: session.judgePolicyExplicit,
                        customLabel: session.trimmedCustomLabel,
                        onToggleJudge: widget.onToggleJudgePolicy != null
                            ? () => widget.onToggleJudgePolicy!(session)
                            : null,
                        onTap: () => widget.onSelectSession(originalIndex),
                        onContextMenu: widget.onSessionContextMenu != null
                            ? (position) => widget.onSessionContextMenu!(
                                  session,
                                  position,
                                )
                            : null,
                      );
                      final lifted = item.groupKey.isNotEmpty &&
                          item.groupKey == widget.draggingGroupKey;
                      final tileForDrag = Opacity(
                        opacity: lifted ? 0.4 : 1.0,
                        child: tile,
                      );
                      if (isSearching) {
                        return KeyedSubtree(key: key, child: tileForDrag);
                      }
                      final isTouch = isMobilePlatform();
                      return isTouch
                          ? ReorderableDelayedDragStartListener(
                              key: key,
                              index: index,
                              child: tileForDrag,
                            )
                          : ReorderableDragStartListener(
                              key: key,
                              index: index,
                              child: tileForDrag,
                            );
                    },
                  ),
                ),
        ),
      ],
    );
  }

  /// A group's display name: the repository's directory name, or "Other" for the
  /// catch-all holding sessions outside any repository.
  ///
  /// Falls back to the key itself rather than to "Other", so that a repository
  /// with no directory name (`/` is the only one) reads as the path it is
  /// instead of collecting a second header identically labelled to the
  /// genuinely repo-less group.
  String _groupLabelFor(String groupKey) {
    if (groupKey == otherGroupPinKey) return 'Other';
    return leafOf(groupKey) ?? groupKey;
  }
}

/// Names the repository whose sessions follow it, and doubles as the drag handle
/// for moving that whole group.
class _SessionGroupHeader extends StatelessWidget {
  const _SessionGroupHeader({
    super.key,
    required this.index,
    required this.label,
    required this.pinned,
    required this.onUnpin,
    required this.isFirst,
    this.canDrag = true,
  });

  final int index;
  final String label;

  /// Releases this group. Reached by tapping the pin indicator.
  final VoidCallback onUnpin;

  /// Whether this group holds a fixed slot. Shown because otherwise "why isn't
  /// this moving?" has no answer on screen: the reset action alone doesn't
  /// say *which* groups are held.
  final bool pinned;

  /// Suppresses the leading gap on the first header, which already sits directly
  /// below the "SESSIONS" label.
  final bool isFirst;

  /// Whether dragging is enabled on this header (disabled during search).
  final bool canDrag;

  @override
  Widget build(BuildContext context) {
    final header = Padding(
      padding: EdgeInsets.fromLTRB(8, isFirst ? 0 : 14, 8, 6),
      child: Row(
        children: [
          const Icon(Icons.folder_outlined, size: 13, color: Color(0xff5c686b)),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              label,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Color(0xff7f8b8d),
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.4,
              ),
            ),
          ),
          if (pinned) _UnpinButton(onUnpin: onUnpin, what: label),
        ],
      ),
    );
    if (!canDrag) return header;
    // Same drag-start rule as the rows: long-press on touch so a plain drag
    // still scrolls, immediate on mouse.
    return isMobilePlatform()
        ? ReorderableDelayedDragStartListener(index: index, child: header)
        : ReorderableDragStartListener(index: index, child: header);
  }
}

/// The pin indicator, which is also the control that releases the pin.
///
/// Doing both jobs with one affordance keeps the rail out of a gesture conflict:
/// on touch, a long-press already starts a drag, so a context menu would have to
/// compete with it. A tap target this small is acceptable because it is purely
/// corrective: nothing is lost by missing it, and the row's own tap (select) is
/// the far more common action.
class _UnpinButton extends StatelessWidget {
  const _UnpinButton({required this.onUnpin, required this.what});

  final VoidCallback onUnpin;

  /// Name of the thing being unpinned, for the tooltip and screen readers.
  final String what;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 4),
      child: Tooltip(
        message: 'Unpin $what (return it to activity order)',
        child: InkWell(
          onTap: onUnpin,
          borderRadius: BorderRadius.circular(4),
          child: const Padding(
            padding: EdgeInsets.all(2),
            child: Icon(
              Icons.push_pin,
              size: 11,
              color: Color(0xff7fd1c7),
              semanticLabel: 'Pinned',
            ),
          ),
        ),
      ),
    );
  }
}

class _JudgeToggleButton extends StatelessWidget {
  const _JudgeToggleButton({
    required this.effective,
    this.explicit,
    required this.onToggle,
  });

  final bool effective;
  final bool? explicit;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final tooltip = effective
        ? (explicit == true
            ? 'Auto-Approval: ON (click to disable)'
            : 'Auto-Approval: Default ON (click to disable)')
        : (explicit == false
            ? 'Auto-Approval: OFF (click to enable)'
            : 'Auto-Approval: Default OFF (click to enable)');

    final color = effective
        ? const Color(0xff7fd1c7)
        : const Color(0xffffc857);

    return Padding(
      padding: const EdgeInsets.only(left: 6),
      child: Tooltip(
        message: tooltip,
        child: InkWell(
          onTap: onToggle,
          borderRadius: BorderRadius.circular(4),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: color.withValues(alpha: 0.3)),
            ),
            child: effective
                ? Icon(
                    Icons.auto_awesome,
                    size: 13,
                    color: color,
                    semanticLabel: 'Auto-Approval ON',
                  )
                : Icon(
                    Icons.person_outline,
                    size: 13,
                    color: color,
                    semanticLabel: 'Auto-Approval OFF',
                  ),
          ),
        ),
      ),
    );
  }
}

/// The connection pill: which daemon we are on, and how that connection is
/// doing. Doubles as the switcher's entry point, so it names the daemon even
/// when only one is configured — otherwise there is nothing to tell you *which*
/// machine the sessions below belong to.
class _ConnectionStatus extends StatelessWidget {
  const _ConnectionStatus({
    required this.status,
    required this.color,
    this.serverLabel,
  });

  final String status;
  final Color color;
  final String? serverLabel;

  @override
  Widget build(BuildContext context) {
    final label = serverLabel;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xff1d2528),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xff2f3b3f)),
      ),
      child: Row(
        children: [
          Icon(Icons.radio_button_checked, size: 16, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (label != null)
                  Text(
                    label,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                Text(
                  status,
                  overflow: TextOverflow.ellipsis,
                  style: label == null
                      ? const TextStyle(fontWeight: FontWeight.w600)
                      : const TextStyle(color: Color(0xff7f8b8d), fontSize: 12),
                ),
              ],
            ),
          ),
          if (label != null)
            const Icon(Icons.unfold_more, size: 16, color: Color(0xff7f8b8d)),
        ],
      ),
    );
  }
}

enum SettingsTab {
  daemons,
  judge,
  preferences,
}

class _CodeSnippetBox extends StatefulWidget {
  const _CodeSnippetBox({
    required this.code,
  });

  final String code;

  @override
  State<_CodeSnippetBox> createState() => _CodeSnippetBoxState();
}

class _CodeSnippetBoxState extends State<_CodeSnippetBox> {
  bool _copied = false;

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.code));
    if (!mounted) return;
    setState(() => _copied = true);
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: const Color(0xff101416),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xff263033)),
      ),
      child: Stack(
        children: [
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(12, 12, 44, 12),
            child: SelectableText(
              widget.code,
              style: const TextStyle(
                fontFamily: 'JetBrains Mono',
                fontSize: 12,
                color: Color(0xffcdd7d6),
                height: 1.45,
              ),
            ),
          ),
          Positioned(
            top: 6,
            right: 6,
            child: Tooltip(
              message: _copied ? 'Copied!' : 'Copy to clipboard',
              child: InkWell(
                onTap: _copy,
                borderRadius: BorderRadius.circular(4),
                child: Container(
                  padding: const EdgeInsets.all(4),
                  decoration: BoxDecoration(
                    color: const Color(0xff1e272a),
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(color: const Color(0xff334246)),
                  ),
                  child: Icon(
                    _copied ? Icons.check : Icons.content_copy,
                    size: 14,
                    color: _copied
                        ? const Color(0xff7fd1c7)
                        : const Color(0xff9aa6a8),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Settings and server manager dialog: daemons, approval judge guide, and client preferences.
class SettingsDialog extends StatefulWidget {
  const SettingsDialog({
    super.key,
    required this.servers,
    required this.selectedId,
    required this.onSelect,
    required this.onAdd,
    required this.onUpdate,
    required this.onRemove,
    this.client,
    this.workspacePath,
    this.clientId,
    this.initialTab = SettingsTab.daemons,
  });

  final List<DaemonServer> servers;
  final String? selectedId;
  final ValueChanged<String> onSelect;
  final void Function(String address, String? label) onAdd;
  final ValueChanged<DaemonServer> onUpdate;
  final ValueChanged<String> onRemove;
  final TriageWebSocketClient? client;
  final String? workspacePath;
  final String? clientId;
  final SettingsTab initialTab;

  @override
  State<SettingsDialog> createState() => _SettingsDialogState();
}

typedef ServerManagerDialog = SettingsDialog;

class _SettingsDialogState extends State<SettingsDialog> {
  late SettingsTab _currentTab = widget.initialTab;
  late final List<DaemonServer> _servers = List.of(widget.servers);
  late String? _selectedId = widget.selectedId;

  JudgeHookStatusRecord? _hookStatus;
  bool _loadingHookStatus = false;
  bool _savingHookStatus = false;

  JudgeRulesRecord? _judgeRules;
  List<JudgeRecordItem> _judgeHistory = [];
  bool _loadingJudgeData = false;
  bool _showBuiltinAllows = false;
  bool _showBuiltinDenies = false;

  final TextEditingController _allowRuleController = TextEditingController();
  final TextEditingController _denyRuleController = TextEditingController();
  final TextEditingController _historySearchController = TextEditingController();
  String _historyFilter = 'all';
  String _historySearchQuery = '';
  int _historyDisplayLimit = 50;

  @override
  void initState() {
    super.initState();
    _loadHookStatus();
    _loadJudgeData();
  }

  @override
  void dispose() {
    _allowRuleController.dispose();
    _denyRuleController.dispose();
    _historySearchController.dispose();
    super.dispose();
  }

  Future<void> _loadJudgeData() async {
    final client = widget.client;
    if (client == null) return;
    setState(() => _loadingJudgeData = true);
    final rules = await client.getJudgeRules();
    final history = await client.getJudgeHistory();
    if (mounted) {
      setState(() {
        _judgeRules = rules;
        _judgeHistory = history;
        _loadingJudgeData = false;
      });
    }
  }

  Future<void> _addAllowRule(String command) async {
    final client = widget.client;
    final cmd = command.trim();
    if (client == null || cmd.isEmpty) return;
    final updated = await client.addJudgeAllowCommand(cmd);
    if (mounted && updated != null) {
      setState(() {
        _judgeRules = updated;
        _allowRuleController.clear();
      });
    }
  }

  Future<void> _removeAllowRule(String command) async {
    final client = widget.client;
    if (client == null) return;
    final updated = await client.removeJudgeAllowCommand(command);
    if (mounted && updated != null) {
      setState(() => _judgeRules = updated);
    }
  }

  Future<void> _addDenyRule(String substring) async {
    final client = widget.client;
    final sub = substring.trim();
    if (client == null || sub.isEmpty) return;
    final updated = await client.addJudgeDenySubstring(sub);
    if (mounted && updated != null) {
      setState(() {
        _judgeRules = updated;
        _denyRuleController.clear();
      });
    }
  }

  Future<void> _removeDenyRule(String substring) async {
    final client = widget.client;
    if (client == null) return;
    final updated = await client.removeJudgeDenySubstring(substring);
    if (mounted && updated != null) {
      setState(() => _judgeRules = updated);
    }
  }

  Future<void> _loadHookStatus() async {
    final client = widget.client;
    if (client == null) return;
    setState(() => _loadingHookStatus = true);
    final status = await client.getJudgeHookStatus(workspacePath: widget.workspacePath);
    if (mounted) {
      setState(() {
        _hookStatus = status;
        _loadingHookStatus = false;
      });
    }
  }

  Future<void> _toggleHookConfig(bool enabled) async {
    final client = widget.client;
    if (client == null) return;
    setState(() => _savingHookStatus = true);
    final updated = await client.configureJudgeHook(
      workspacePath: widget.workspacePath,
      enabled: enabled,
    );
    if (mounted) {
      setState(() {
        if (updated != null) {
          _hookStatus = updated;
        }
        _savingHookStatus = false;
      });
    }
  }

  // The server being edited. Null with [_adding] false shows the list.
  DaemonServer? _editing;
  // With nothing to list, open straight to the form — an empty list with an
  // "add" button is a dead end you have to click through.
  late bool _adding = _servers.isEmpty;

  void _startAdd() => setState(() {
    _adding = true;
    _editing = null;
  });

  void _startEdit(DaemonServer server) => setState(() {
    _adding = false;
    _editing = server;
  });

  void _backToList() => setState(() {
    _adding = false;
    _editing = null;
  });

  void _submitForm(String address, String? label) {
    final editing = _editing;
    if (editing == null) {
      widget.onAdd(address, label);
      Navigator.of(context).pop();
      return;
    }
    final updated = editing.copyWith(
      address: address,
      label: label ?? DaemonServer.defaultLabelFor(address),
    );
    setState(() {
      final index = _servers.indexWhere((s) => s.id == updated.id);
      if (index != -1) _servers[index] = updated;
    });
    widget.onUpdate(updated);
    _backToList();
  }

  Future<void> _confirmRemove(DaemonServer server) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xff161b1d),
        title: Text('Forget ${server.label}?'),
        content: const Text(
          'This device will be un-paired from that daemon. Reconnecting to it '
          'later needs the PIN again.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xffff6b6b),
            ),
            child: const Text('Forget'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() {
      _servers.removeWhere((s) => s.id == server.id);
      if (_selectedId == server.id) {
        _selectedId = _servers.isEmpty ? null : _servers.first.id;
      }
    });
    widget.onRemove(server.id);
    if (_servers.isEmpty && mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: const Color(0xff161b1d),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640, maxHeight: 720),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Icon(Icons.settings, color: Color(0xff7fd1c7), size: 22),
                  const SizedBox(width: 10),
                  const Expanded(
                    child: Text(
                      'Settings',
                      style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    tooltip: 'Close',
                    icon: const Icon(Icons.close, color: Color(0xff7f8b8d), size: 20),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              _buildTabBar(),
              const SizedBox(height: 16),
              Flexible(
                child: switch (_currentTab) {
                  SettingsTab.daemons => _buildDaemonsTab(),
                  SettingsTab.judge => _buildJudgeTab(),
                  SettingsTab.preferences => _buildPreferencesTab(),
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTabBar() {
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: const Color(0xff121618),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xff263033)),
      ),
      child: Row(
        children: [
          Expanded(
            child: _tabButton(
              tab: SettingsTab.daemons,
              icon: Icons.dns_outlined,
              label: 'Daemons',
            ),
          ),
          Expanded(
            child: _tabButton(
              tab: SettingsTab.judge,
              icon: Icons.auto_awesome,
              label: 'Approval Judge',
            ),
          ),
          Expanded(
            child: _tabButton(
              tab: SettingsTab.preferences,
              icon: Icons.tune,
              label: 'Preferences',
            ),
          ),
        ],
      ),
    );
  }

  Widget _tabButton({
    required SettingsTab tab,
    required IconData icon,
    required String label,
  }) {
    final isSelected = _currentTab == tab;
    return InkWell(
      onTap: () => setState(() {
        _currentTab = tab;
        _editing = null;
        _adding = false;
      }),
      borderRadius: BorderRadius.circular(6),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 8),
        decoration: BoxDecoration(
          color: isSelected ? const Color(0xff233033) : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
          border: isSelected
              ? Border.all(color: const Color(0xff3b5356))
              : Border.all(color: Colors.transparent),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 15,
              color: isSelected
                  ? const Color(0xff7fd1c7)
                  : const Color(0xff7f8b8d),
            ),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                label,
                overflow: TextOverflow.ellipsis,
                maxLines: 1,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
                  color: isSelected
                      ? const Color(0xffcdd7d6)
                      : const Color(0xff7f8b8d),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDaemonsTab() {
    final editing = _editing;
    if (_adding || editing != null) {
      return ConnectionSettingsForm(
        key: ValueKey<String>(editing?.id ?? '@add'),
        initialAddress: editing?.address,
        initialLabel: editing?.label,
        submitLabel: editing == null ? 'Add' : 'Save',
        title: editing == null ? 'Add a daemon' : 'Edit daemon',
        subtitle:
            'Host, IP, or URL of the device running triaged '
            '(e.g. my-mac.tailnet:7777).',
        onCancel: _backToList,
        onSubmit: _submitForm,
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const Expanded(
              child: Text(
                'Connected & Known Daemons',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: Color(0xff9aa6a8),
                ),
              ),
            ),
            IconButton(
              onPressed: _startAdd,
              tooltip: 'Add a daemon',
              icon: const Icon(Icons.add, color: Color(0xff7fd1c7), size: 20),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Flexible(
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: _servers.length,
            itemBuilder: (context, index) {
              final server = _servers[index];
              final isSelected = server.id == _selectedId;
              return Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Material(
                  color: isSelected
                      ? const Color(0xff1b2426)
                      : const Color(0xff121618),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                    side: BorderSide(
                      color: isSelected
                          ? const Color(0xff3b5356)
                          : const Color(0xff222a2d),
                    ),
                  ),
                  child: ListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 12),
                    leading: Icon(
                      isSelected
                          ? Icons.radio_button_checked
                          : Icons.radio_button_unchecked,
                      color: isSelected
                          ? const Color(0xff7fd1c7)
                          : const Color(0xff7f8b8d),
                      size: 18,
                    ),
                    title: Text(
                      server.label,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
                      ),
                    ),
                    subtitle: Text(
                      server.address,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Color(0xff7f8b8d),
                        fontSize: 12,
                      ),
                    ),
                    onTap: () {
                      if (!isSelected) widget.onSelect(server.id);
                      Navigator.of(context).pop();
                    },
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          onPressed: () => _startEdit(server),
                          tooltip: 'Edit',
                          icon: const Icon(
                            Icons.edit_outlined,
                            size: 16,
                            color: Color(0xff7f8b8d),
                          ),
                        ),
                        IconButton(
                          onPressed: () => _confirmRemove(server),
                          tooltip: 'Forget',
                          icon: const Icon(
                            Icons.delete_outline,
                            size: 16,
                            color: Color(0xff7f8b8d),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildJudgeTab() {
    final history = _judgeHistory;
    final rules = _judgeRules;

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xff121618),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: const Color(0xff263033)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.auto_awesome, color: Color(0xff7fd1c7), size: 18),
                    const SizedBox(width: 8),
                    const Expanded(
                      child: Text(
                        'Tool-Call Approval Judge',
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: const Color(0xff7fd1c7).withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(color: const Color(0xff7fd1c7).withValues(alpha: 0.3)),
                      ),
                      child: const Text(
                        'Local AI · LFM2-2.6B',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: Color(0xff7fd1c7),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                const Text(
                  'Auto-approves routine agent commands (reads, checks, tests) while stopping dangerous ones for manual confirmation. All decisions are evaluated locally in daemon memory with zero cloud telemetry.',
                  style: TextStyle(fontSize: 13, color: Color(0xff9aa6a8), height: 1.4),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),

          // Workspace hook card
          const Text(
            'WORKSPACE HOOK INTEGRATION',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.8,
              color: Color(0xff7f8b8d),
            ),
          ),
          const SizedBox(height: 8),
          Material(
            color: const Color(0xff121618),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
              side: BorderSide(
                color: _hookStatus?.enabled == true
                    ? const Color(0xff3b5356)
                    : const Color(0xff222a2d),
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        _hookStatus?.enabled == true
                            ? Icons.check_circle_outline
                            : Icons.integration_instructions_outlined,
                        color: _hookStatus?.enabled == true
                            ? const Color(0xff7fd1c7)
                            : const Color(0xff9aa6a8),
                        size: 20,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'Agent PreToolUse Hook',
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: Color(0xffcdd7d6),
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              _hookStatus != null && _hookStatus!.path.isNotEmpty
                                  ? _hookStatus!.path
                                  : '.agents/hooks.json',
                              style: const TextStyle(
                                fontSize: 11,
                                fontFamily: 'JetBrains Mono',
                                color: Color(0xff7f8b8d),
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 12),
                      if (_loadingHookStatus || _savingHookStatus)
                        const SizedBox(
                          width: 24,
                          height: 24,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            valueColor: AlwaysStoppedAnimation(Color(0xff7fd1c7)),
                          ),
                        )
                      else
                        Switch(
                          value: _hookStatus?.enabled ?? false,
                          // ignore: deprecated_member_use
                          activeColor: const Color(0xff7fd1c7),
                          activeTrackColor: const Color(0xff233c3e),
                          inactiveThumbColor: const Color(0xff7f8b8d),
                          inactiveTrackColor: const Color(0xff1b2426),
                          onChanged: widget.client != null ? _toggleHookConfig : null,
                        ),
                    ],
                  ),
                  if (_hookStatus?.enabled == true) ...[
                    const SizedBox(height: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: const Color(0xff7fd1c7).withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: const Row(
                        children: [
                          Icon(Icons.check, size: 13, color: Color(0xff7fd1c7)),
                          SizedBox(width: 4),
                          Expanded(
                            child: Text(
                              'Hook enabled in .agents/hooks.json (auto-approved commands execute immediately).',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w500,
                                color: Color(0xff7fd1c7),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                  if (_hookStatus != null && !_hookStatus!.shimInstalled) ...[
                    const SizedBox(height: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: const Color(0xffffc857).withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: const Row(
                        children: [
                          Icon(Icons.warning_amber_rounded, size: 14, color: Color(0xffffc857)),
                          SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              'triage-hook CLI not detected on PATH. Run the installation command below.',
                              style: TextStyle(
                                fontSize: 11,
                                color: Color(0xffffc857),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),

          // Approval Traffic & Layer Analytics Dashboard
          _buildJudgeDashboard(history),
          const SizedBox(height: 16),

          // Recent Decision History / Traffic Audit
          Builder(
            builder: (context) {
              final filteredHistory = history.reversed.where((item) {
                if (_historyFilter != 'all') {
                  if (item.decision.toLowerCase() != _historyFilter) return false;
                }
                if (_historySearchQuery.isNotEmpty) {
                  final q = _historySearchQuery.toLowerCase();
                  final cmd = (item.commandLine ?? '').toLowerCase();
                  final tool = item.toolName.toLowerCase();
                  final rsn = item.reason.toLowerCase();
                  final src = item.source.toLowerCase();
                  if (!cmd.contains(q) &&
                      !tool.contains(q) &&
                      !rsn.contains(q) &&
                      !src.contains(q)) {
                    return false;
                  }
                }
                return true;
              }).toList();

              final allowTotal =
                  history.where((i) => i.decision.toLowerCase() == 'allow').length;
              final askTotal =
                  history.where((i) => i.decision.toLowerCase() == 'ask').length;
              final denyTotal =
                  history.where((i) => i.decision.toLowerCase() == 'deny').length;

              final displayedItems =
                  filteredHistory.take(_historyDisplayLimit).toList();

              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          'RECENT DECISION HISTORY',
                          style: const TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 0.8,
                            color: Color(0xff7f8b8d),
                          ),
                        ),
                      ),
                      if (_loadingJudgeData)
                        const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(
                            strokeWidth: 1.5,
                            valueColor: AlwaysStoppedAnimation(Color(0xff7fd1c7)),
                          ),
                        )
                      else
                        IconButton(
                          onPressed: _loadJudgeData,
                          icon: const Icon(Icons.refresh, size: 16, color: Color(0xff7fd1c7)),
                          tooltip: 'Refresh History & Rules',
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(),
                        ),
                    ],
                  ),
                  const SizedBox(height: 8),

                  // Filter & search toolbar
                  Row(
                    children: [
                      Expanded(
                        child: SizedBox(
                          height: 32,
                          child: TextField(
                            controller: _historySearchController,
                            onChanged: (val) =>
                                setState(() => _historySearchQuery = val.trim()),
                            style: const TextStyle(
                              fontSize: 12,
                              fontFamily: 'JetBrains Mono',
                              color: Color(0xffcdd7d6),
                            ),
                            decoration: InputDecoration(
                              hintText: 'Filter decisions by command, tool, or reason...',
                              hintStyle:
                                  const TextStyle(fontSize: 11, color: Color(0xff5a686b)),
                              prefixIcon:
                                  const Icon(Icons.search, size: 14, color: Color(0xff7f8b8d)),
                              prefixIconConstraints:
                                  const BoxConstraints(minWidth: 28, minHeight: 28),
                              suffixIcon: _historySearchQuery.isNotEmpty
                                  ? IconButton(
                                      icon: const Icon(Icons.clear,
                                          size: 14, color: Color(0xff7f8b8d)),
                                      onPressed: () {
                                        _historySearchController.clear();
                                        setState(() => _historySearchQuery = '');
                                      },
                                      padding: EdgeInsets.zero,
                                      constraints: const BoxConstraints(),
                                    )
                                  : null,
                              isDense: true,
                              contentPadding:
                                  const EdgeInsets.symmetric(horizontal: 8, vertical: 0),
                              filled: true,
                              fillColor: const Color(0xff0d1113),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(6),
                                borderSide: const BorderSide(color: Color(0xff222a2d)),
                              ),
                              enabledBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(6),
                                borderSide: const BorderSide(color: Color(0xff222a2d)),
                              ),
                              focusedBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(6),
                                borderSide: const BorderSide(color: Color(0xff7fd1c7)),
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      // Filter pills
                      _buildHistoryFilterPill('all', 'All (${history.length})'),
                      const SizedBox(width: 4),
                      _buildHistoryFilterPill('allow', 'Allow ($allowTotal)'),
                      const SizedBox(width: 4),
                      _buildHistoryFilterPill('ask', 'Ask ($askTotal)'),
                      const SizedBox(width: 4),
                      _buildHistoryFilterPill('deny', 'Deny ($denyTotal)'),
                    ],
                  ),
                  const SizedBox(height: 8),

                  // History list container
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: const Color(0xff121618),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: const Color(0xff222a2d)),
                    ),
                    child: history.isEmpty
                        ? const Padding(
                            padding: EdgeInsets.symmetric(vertical: 8),
                            child: Text(
                              'No tool calls judged yet. Live decisions evaluated while coding agents run will appear here.',
                              style: TextStyle(fontSize: 12, color: Color(0xff7f8b8d)),
                            ),
                          )
                        : filteredHistory.isEmpty
                            ? const Padding(
                                padding: EdgeInsets.symmetric(vertical: 8),
                                child: Text(
                                  'No decisions match the current filter or search query.',
                                  style: TextStyle(fontSize: 12, color: Color(0xff7f8b8d)),
                                ),
                              )
                            : Column(
                                children: [
                                  for (int i = 0; i < displayedItems.length; i++) ...[
                                    _buildHistoryRow(displayedItems[i]),
                                    if (i < displayedItems.length - 1)
                                      const Divider(color: Color(0xff1e2628), height: 16),
                                  ],
                                  if (filteredHistory.length > displayedItems.length) ...[
                                    const Divider(color: Color(0xff1e2628), height: 16),
                                    Row(
                                      mainAxisAlignment: MainAxisAlignment.center,
                                      children: [
                                        TextButton(
                                          onPressed: () {
                                            setState(() {
                                              _historyDisplayLimit += 50;
                                            });
                                          },
                                          child: Text(
                                            'Show 50 more (${filteredHistory.length - displayedItems.length} remaining)',
                                            style: const TextStyle(
                                              fontSize: 12,
                                              color: Color(0xff7fd1c7),
                                            ),
                                          ),
                                        ),
                                        const SizedBox(width: 12),
                                        TextButton(
                                          onPressed: () {
                                            setState(() {
                                              _historyDisplayLimit = filteredHistory.length;
                                            });
                                          },
                                          child: Text(
                                            'Show all (${filteredHistory.length})',
                                            style: const TextStyle(
                                              fontSize: 12,
                                              color: Color(0xff9aa6a8),
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ],
                                ],
                              ),
                  ),
                ],
              );
            },
          ),
          const SizedBox(height: 16),

          // Custom & Built-in Allow Rules
          const Text(
            'AUTO-APPROVED COMMANDS (ALLOWLIST)',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.8,
              color: Color(0xff7f8b8d),
            ),
          ),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xff121618),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: const Color(0xff222a2d)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Commands matching these prefixes execute immediately without prompting:',
                  style: TextStyle(fontSize: 12, color: Color(0xff9aa6a8)),
                ),
                const SizedBox(height: 8),

                // Custom allow rules chips
                if (rules != null && rules.customAllowCommands.isNotEmpty) ...[
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final cmd in rules.customAllowCommands)
                        Chip(
                          backgroundColor: const Color(0xff1b2b2b),
                          side: const BorderSide(color: Color(0xff3b5356)),
                          label: Text(
                            cmd,
                            style: const TextStyle(
                              fontSize: 12,
                              fontFamily: 'JetBrains Mono',
                              color: Color(0xff7fd1c7),
                            ),
                          ),
                          deleteIcon: const Icon(Icons.close, size: 14, color: Color(0xff7fd1c7)),
                          onDeleted: () => _removeAllowRule(cmd),
                        ),
                    ],
                  ),
                  const SizedBox(height: 10),
                ],

                // Add custom allow rule field
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _allowRuleController,
                        style: const TextStyle(
                          fontSize: 12,
                          fontFamily: 'JetBrains Mono',
                          color: Color(0xffcdd7d6),
                        ),
                        decoration: InputDecoration(
                          hintText: 'Add allow prefix (e.g. "pnpm test", "make check")',
                          hintStyle: const TextStyle(fontSize: 11, color: Color(0xff5a686b)),
                          isDense: true,
                          contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                          filled: true,
                          fillColor: const Color(0xff0d1113),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(6),
                            borderSide: const BorderSide(color: Color(0xff222a2d)),
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(6),
                            borderSide: const BorderSide(color: Color(0xff222a2d)),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(6),
                            borderSide: const BorderSide(color: Color(0xff7fd1c7)),
                          ),
                        ),
                        onSubmitted: _addAllowRule,
                      ),
                    ),
                    const SizedBox(width: 8),
                    FilledButton.icon(
                      onPressed: () => _addAllowRule(_allowRuleController.text),
                      icon: const Icon(Icons.add, size: 14),
                      label: const Text('Add', style: TextStyle(fontSize: 12)),
                      style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xff233c3e),
                        foregroundColor: const Color(0xff7fd1c7),
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),

                // Collapsible built-in allow rules
                InkWell(
                  onTap: () => setState(() => _showBuiltinAllows = !_showBuiltinAllows),
                  borderRadius: BorderRadius.circular(4),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      children: [
                        Icon(
                          _showBuiltinAllows ? Icons.expand_less : Icons.expand_more,
                          size: 16,
                          color: const Color(0xff7fd1c7),
                        ),
                        const SizedBox(width: 4),
                        Text(
                          '${_showBuiltinAllows ? "Hide" : "Show"} Built-in Allow Rules (${rules?.builtinAllowCommands.length ?? 0})',
                          style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: Color(0xff7fd1c7),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                if (_showBuiltinAllows && rules != null) ...[
                  const SizedBox(height: 8),
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: const Color(0xff0d1113),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: const Color(0xff1b2426)),
                    ),
                    child: Wrap(
                      spacing: 4,
                      runSpacing: 4,
                      children: [
                        for (final cmd in rules.builtinAllowCommands)
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: const Color(0xff161e20),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              cmd,
                              style: const TextStyle(
                                fontSize: 11,
                                fontFamily: 'JetBrains Mono',
                                color: Color(0xff9aa6a8),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 16),

          // Custom & Built-in Deny Rules
          const Text(
            'HARD DENY RULES (BLOCKED IMMEDIATELY)',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.8,
              color: Color(0xff7f8b8d),
            ),
          ),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xff121618),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: const Color(0xff222a2d)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Commands or target paths containing these substrings are blocked immediately:',
                  style: TextStyle(fontSize: 12, color: Color(0xff9aa6a8)),
                ),
                const SizedBox(height: 8),

                // Custom deny rules chips
                if (rules != null && rules.customDenySubstrings.isNotEmpty) ...[
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final sub in rules.customDenySubstrings)
                        Chip(
                          backgroundColor: const Color(0xff2d1717),
                          side: const BorderSide(color: Color(0xff5c2626)),
                          label: Text(
                            sub,
                            style: const TextStyle(
                              fontSize: 12,
                              fontFamily: 'JetBrains Mono',
                              color: Color(0xffff6b6b),
                            ),
                          ),
                          deleteIcon: const Icon(Icons.close, size: 14, color: Color(0xffff6b6b)),
                          onDeleted: () => _removeDenyRule(sub),
                        ),
                    ],
                  ),
                  const SizedBox(height: 10),
                ],

                // Add custom deny rule field
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _denyRuleController,
                        style: const TextStyle(
                          fontSize: 12,
                          fontFamily: 'JetBrains Mono',
                          color: Color(0xffcdd7d6),
                        ),
                        decoration: InputDecoration(
                          hintText: 'Add deny pattern (e.g. "terraform apply", "drop database")',
                          hintStyle: const TextStyle(fontSize: 11, color: Color(0xff5a686b)),
                          isDense: true,
                          contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                          filled: true,
                          fillColor: const Color(0xff0d1113),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(6),
                            borderSide: const BorderSide(color: Color(0xff222a2d)),
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(6),
                            borderSide: const BorderSide(color: Color(0xff222a2d)),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(6),
                            borderSide: const BorderSide(color: Color(0xffff6b6b)),
                          ),
                        ),
                        onSubmitted: _addDenyRule,
                      ),
                    ),
                    const SizedBox(width: 8),
                    FilledButton.icon(
                      onPressed: () => _addDenyRule(_denyRuleController.text),
                      icon: const Icon(Icons.add, size: 14),
                      label: const Text('Add', style: TextStyle(fontSize: 12)),
                      style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xff3e1b1b),
                        foregroundColor: const Color(0xffff6b6b),
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),

                // Collapsible built-in deny rules
                InkWell(
                  onTap: () => setState(() => _showBuiltinDenies = !_showBuiltinDenies),
                  borderRadius: BorderRadius.circular(4),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      children: [
                        Icon(
                          _showBuiltinDenies ? Icons.expand_less : Icons.expand_more,
                          size: 16,
                          color: const Color(0xffff6b6b),
                        ),
                        const SizedBox(width: 4),
                        Text(
                          '${_showBuiltinDenies ? "Hide" : "Show"} Built-in Deny Rules (${rules?.builtinDenySubstrings.length ?? 0})',
                          style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: Color(0xffff6b6b),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                if (_showBuiltinDenies && rules != null) ...[
                  const SizedBox(height: 8),
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: const Color(0xff0d1113),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: const Color(0xff1b2426)),
                    ),
                    child: Wrap(
                      spacing: 4,
                      runSpacing: 4,
                      children: [
                        for (final sub in rules.builtinDenySubstrings)
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: const Color(0xff1e1616),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              sub,
                              style: const TextStyle(
                                fontSize: 11,
                                fontFamily: 'JetBrains Mono',
                                color: Color(0xffd89696),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 16),

          // 3-Layer Decision Engine
          const Text(
            '3-LAYER DECISION ENGINE',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.8,
              color: Color(0xff7f8b8d),
            ),
          ),
          const SizedBox(height: 8),
          _buildLayerRow(
            icon: Icons.shield_outlined,
            iconColor: const Color(0xffff6b6b),
            title: 'Layer 1: Deterministic Deny',
            description: 'Destructive commands (rm -rf, git push --force) and credential files (.ssh, .env) are blocked instantly.',
          ),
          const SizedBox(height: 6),
          _buildLayerRow(
            icon: Icons.bolt,
            iconColor: const Color(0xff7fd1c7),
            title: 'Layer 2: Deterministic Allow',
            description: 'Safe read-only commands (git status/diff/log, cargo test, flutter test) auto-approve in <10ms.',
          ),
          const SizedBox(height: 6),
          _buildLayerRow(
            icon: Icons.auto_awesome,
            iconColor: const Color(0xffffc857),
            title: 'Layer 3: Local Model',
            description: 'Ambiguous commands are evaluated by resident model using GBNF grammar constraints (allow/ask).',
          ),
          const SizedBox(height: 16),

          // Agent setup guide
          const Text(
            'AGENT SETUP GUIDE',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.8,
              color: Color(0xff7f8b8d),
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            '1. Install the hook shim on PATH:',
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Color(0xffcdd7d6)),
          ),
          const SizedBox(height: 6),
          const _CodeSnippetBox(
            code: 'TRIAGE_SKIP_FLUTTER_BUILD=1 cargo install --path crates/triage-hook',
          ),
          const SizedBox(height: 12),
          const Text(
            '2. Generated workspace .agents/hooks.json (managed by switch above):',
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Color(0xffcdd7d6)),
          ),
          const SizedBox(height: 6),
          const _CodeSnippetBox(
            code: '{\n'
                '  "triage-approval-judge": {\n'
                '    "enabled": true,\n'
                '    "PreToolUse": [\n'
                '      {\n'
                '        "matcher": ".*",\n'
                '        "hooks": [\n'
                '          {\n'
                '            "type": "command",\n'
                '            "command": "triage-hook",\n'
                '            "timeout": 15\n'
                '          }\n'
                '        ]\n'
                '      }\n'
                '    ]\n'
                '  }\n'
                '}',
          ),
          const SizedBox(height: 12),
          const Text(
            '3. Run agent inside Triage:',
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Color(0xffcdd7d6)),
          ),
          const SizedBox(height: 4),
          const Text(
            'Start your agent (agy, claude, etc.) inside any Triage terminal session. Triage automatically injects TRIAGE_SESSION_ID so tool calls associate with your active session.',
            style: TextStyle(fontSize: 12, color: Color(0xff9aa6a8), height: 1.4),
          ),
        ],
      ),
    );
  }

  Widget _buildHistoryFilterPill(String filterKey, String label) {
    final isSelected = _historyFilter == filterKey;
    return InkWell(
      onTap: () => setState(() => _historyFilter = filterKey),
      borderRadius: BorderRadius.circular(5),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(
          color: isSelected ? const Color(0xff1b2b2b) : const Color(0xff0d1113),
          borderRadius: BorderRadius.circular(5),
          border: Border.all(
            color: isSelected ? const Color(0xff7fd1c7) : const Color(0xff222a2d),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 11,
            fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
            color: isSelected ? const Color(0xff7fd1c7) : const Color(0xff9aa6a8),
          ),
        ),
      ),
    );
  }

  Widget _buildHistoryRow(JudgeRecordItem item) {
    final (badgeBg, badgeBorder, badgeText, badgeLabel) = switch (item.decision.toLowerCase()) {
      'deny' => (
          const Color(0xffff6b6b).withValues(alpha: 0.15),
          const Color(0xffff6b6b).withValues(alpha: 0.4),
          const Color(0xffff6b6b),
          'DENY',
        ),
      'allow' => (
          const Color(0xff7fd1c7).withValues(alpha: 0.15),
          const Color(0xff7fd1c7).withValues(alpha: 0.4),
          const Color(0xff7fd1c7),
          'ALLOW',
        ),
      _ => (
          const Color(0xffffc857).withValues(alpha: 0.15),
          const Color(0xffffc857).withValues(alpha: 0.4),
          const Color(0xffffc857),
          'ASK',
        ),
    };

    final command = item.commandLine?.trim();
    String? suggestedPrefix;
    if (item.decision.toLowerCase() != 'allow') {
      if (command != null && command.isNotEmpty) {
        final tokens = command.split(' ');
        suggestedPrefix = tokens.take(2).join(' ');
      } else if (item.toolName.isNotEmpty && item.toolName != 'run_command') {
        suggestedPrefix = item.toolName;
      }
    }

    final isAlreadyAllowed = suggestedPrefix != null &&
        (_judgeRules?.customAllowCommands.contains(suggestedPrefix) ?? false);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: badgeBg,
                borderRadius: BorderRadius.circular(4),
                border: Border.all(color: badgeBorder),
              ),
              child: Text(
                badgeLabel,
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  color: badgeText,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              item.toolName,
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: Color(0xffcdd7d6),
              ),
            ),
            const Spacer(),
            Text(
              item.timestamp.contains('T')
                  ? item.timestamp.split('T').last.replaceAll('Z', '')
                  : item.timestamp,
              style: const TextStyle(fontSize: 10, color: Color(0xff5a686b)),
            ),
          ],
        ),
        if (command != null && command.isNotEmpty) ...[
          const SizedBox(height: 4),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: const Color(0xff0d1113),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              command,
              style: const TextStyle(
                fontSize: 11,
                fontFamily: 'JetBrains Mono',
                color: Color(0xffcdd7d6),
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
        const SizedBox(height: 4),
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: Text(
                item.reason.isNotEmpty ? item.reason : 'Source: ${item.source}',
                style: const TextStyle(fontSize: 11, color: Color(0xff7f8b8d)),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        if (suggestedPrefix != null && suggestedPrefix.isNotEmpty) ...[
          const SizedBox(height: 6),
          Row(
            children: [
              if (isAlreadyAllowed) ...[
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: const Color(0xff7fd1c7).withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(
                      color: const Color(0xff7fd1c7).withValues(alpha: 0.35),
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.check, size: 12, color: Color(0xff7fd1c7)),
                      const SizedBox(width: 4),
                      Text(
                        'Allowed via "$suggestedPrefix"',
                        style: const TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: Color(0xff7fd1c7),
                        ),
                      ),
                    ],
                  ),
                ),
              ] else ...[
                OutlinedButton.icon(
                  onPressed: () => _addAllowRule(suggestedPrefix!),
                  icon: const Icon(Icons.add, size: 13, color: Color(0xff7fd1c7)),
                  label: Text(
                    'Always Allow "$suggestedPrefix"',
                    style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: Color(0xff7fd1c7),
                    ),
                  ),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    minimumSize: Size.zero,
                    side: BorderSide(
                      color: const Color(0xff7fd1c7).withValues(alpha: 0.45),
                    ),
                    backgroundColor: const Color(0xff7fd1c7).withValues(alpha: 0.08),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(5),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ],
      ],
    );
  }

  Widget _buildJudgeDashboard(List<JudgeRecordItem> history) {
    final total = history.length;
    final allowCount =
        history.where((i) => i.decision.toLowerCase() == 'allow').length;
    final askCount =
        history.where((i) => i.decision.toLowerCase() == 'ask').length;
    final denyCount =
        history.where((i) => i.decision.toLowerCase() == 'deny').length;

    final allowPct = total == 0 ? 0.0 : (allowCount / total) * 100;
    final askPct = total == 0 ? 0.0 : (askCount / total) * 100;
    final denyPct = total == 0 ? 0.0 : (denyCount / total) * 100;

    int l1Count = 0; // Deterministic allowlist & safe tools
    int l2Count = 0; // Local model decisions
    int l2Allow = 0;
    int l2Ask = 0;
    int l3Count = 0; // Sensitive / guardrails / fallback
    int hardDenyCount = 0;

    for (final item in history) {
      final dec = item.decision.toLowerCase();
      final src = item.source.toLowerCase();
      final rsn = item.reason.toLowerCase();

      if (dec == 'deny' || src.contains('deny')) {
        hardDenyCount++;
      } else if (src.contains('model') || rsn.contains('model')) {
        l2Count++;
        if (dec == 'allow') l2Allow++;
        if (dec == 'ask') l2Ask++;
      } else if (src == 'fallback' ||
          src.contains('sensitive') ||
          rsn.contains('manual approval') ||
          rsn.contains('credential')) {
        l3Count++;
      } else if (src.contains('allow') ||
          rsn.contains('allow') ||
          rsn.contains('read-only') ||
          rsn.contains('edit tool')) {
        l1Count++;
      } else {
        if (dec == 'allow') {
          l1Count++;
        } else {
          l3Count++;
        }
      }
    }

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xff121618),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xff222a2d)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.analytics_outlined,
                size: 16,
                color: Color(0xff7fd1c7),
              ),
              const SizedBox(width: 6),
              const Text(
                'APPROVAL TRAFFIC DASHBOARD',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.8,
                  color: Color(0xff7f8b8d),
                ),
              ),
              const Spacer(),
              Text(
                '$total total evaluated',
                style: const TextStyle(fontSize: 11, color: Color(0xff9aa6a8)),
              ),
            ],
          ),
          const SizedBox(height: 12),

          // 3 Metric Cards Row
          LayoutBuilder(
            builder: (context, constraints) {
              final cardWidth = (constraints.maxWidth - 16) / 3;
              return Row(
                children: [
                  _buildStatCard(
                    title: 'Auto-Approved',
                    count: allowCount,
                    percentage: allowPct,
                    color: const Color(0xff7fd1c7),
                    icon: Icons.check_circle_outline,
                    subtitle: '0 prompts needed',
                    width: cardWidth,
                  ),
                  const SizedBox(width: 8),
                  _buildStatCard(
                    title: 'Prompted (Ask)',
                    count: askCount,
                    percentage: askPct,
                    color: const Color(0xffffc857),
                    icon: Icons.help_outline,
                    subtitle: 'Passed to AI / user',
                    width: cardWidth,
                  ),
                  const SizedBox(width: 8),
                  _buildStatCard(
                    title: 'Hard Denied',
                    count: denyCount,
                    percentage: denyPct,
                    color: const Color(0xffff6b6b),
                    icon: Icons.block,
                    subtitle: 'Blocked by rules',
                    width: cardWidth,
                  ),
                ],
              );
            },
          ),
          const SizedBox(height: 12),

          // Multi-color Ratio Distribution Bar
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: SizedBox(
              height: 6,
              child: Row(
                children: [
                  if (total == 0)
                    Expanded(child: Container(color: const Color(0xff222a2d)))
                  else ...[
                    if (allowCount > 0)
                      Expanded(
                        flex: allowCount,
                        child: Container(color: const Color(0xff7fd1c7)),
                      ),
                    if (askCount > 0)
                      Expanded(
                        flex: askCount,
                        child: Container(color: const Color(0xffffc857)),
                      ),
                    if (denyCount > 0)
                      Expanded(
                        flex: denyCount,
                        child: Container(color: const Color(0xffff6b6b)),
                      ),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 14),

          // Layer Breakdown Section
          const Text(
            'DECISION LAYERS BREAKDOWN',
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.6,
              color: Color(0xff5a686b),
            ),
          ),
          const SizedBox(height: 8),

          _buildLayerMetricRow(
            icon: Icons.bolt,
            iconColor: const Color(0xff7fd1c7),
            title: 'Layer 1: Deterministic Allowlist',
            description:
                'Safe reads, diffs, formatting, tests, status & custom prefixes',
            countText: '$l1Count calls approved',
            statusColor: const Color(0xff7fd1c7),
          ),
          const SizedBox(height: 6),
          _buildLayerMetricRow(
            icon: Icons.psychology,
            iconColor: const Color(0xffb39ddb),
            title: 'Layer 2: Local AI Neural Model',
            description:
                'Evaluated unclassified shell commands ($l2Allow allowed, $l2Ask escalated)',
            countText: '$l2Count calls evaluated',
            statusColor: const Color(0xffb39ddb),
          ),
          const SizedBox(height: 6),
          _buildLayerMetricRow(
            icon: Icons.shield_outlined,
            iconColor: const Color(0xffffc857),
            title: 'Layer 3: Security & Sensitivity Guardrails',
            description:
                'Credential paths, network pipes, destructive flags & remote pushes',
            countText: '$l3Count calls escalated to Ask',
            statusColor: const Color(0xffffc857),
          ),
          if (hardDenyCount > 0) ...[
            const SizedBox(height: 6),
            _buildLayerMetricRow(
              icon: Icons.block,
              iconColor: const Color(0xffff6b6b),
              title: 'Hard Deny Substrings',
              description: 'Blocked immediately via user deny rules',
              countText: '$hardDenyCount calls blocked',
              statusColor: const Color(0xffff6b6b),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildStatCard({
    required String title,
    required int count,
    required double percentage,
    required Color color,
    required IconData icon,
    required String subtitle,
    required double width,
  }) {
    return Container(
      width: width,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xff0d1113),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withValues(alpha: 0.25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 14, color: color),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: color,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                '$count',
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: Color(0xffcdd7d6),
                ),
              ),
              const SizedBox(width: 4),
              Text(
                '(${percentage.toStringAsFixed(0)}%)',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: color,
                ),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            subtitle,
            style: const TextStyle(fontSize: 10, color: Color(0xff5a686b)),
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }

  Widget _buildLayerMetricRow({
    required IconData icon,
    required Color iconColor,
    required String title,
    required String description,
    required String countText,
    required Color statusColor,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xff0d1113),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: const Color(0xff1b2426)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Icon(icon, size: 16, color: iconColor),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: Color(0xffcdd7d6),
                  ),
                ),
                Text(
                  description,
                  style: const TextStyle(fontSize: 10, color: Color(0xff7f8b8d)),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: statusColor.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: statusColor.withValues(alpha: 0.3)),
            ),
            child: Text(
              countText,
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w600,
                color: statusColor,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLayerRow({
    required IconData icon,
    required Color iconColor,
    required String title,
    required String description,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xff101416),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: const Color(0xff222a2d)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 16, color: iconColor),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: iconColor,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  description,
                  style: const TextStyle(fontSize: 11, color: Color(0xff9aa6a8), height: 1.35),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPreferencesTab() {
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: const Color(0xff121618),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: const Color(0xff263033)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Terminal Settings',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 10),
                const Row(
                  children: [
                    Icon(Icons.terminal, size: 16, color: Color(0xff7fd1c7)),
                    SizedBox(width: 8),
                    Text(
                      'Font Family: JetBrains Mono',
                      style: TextStyle(fontSize: 13, color: Color(0xffcdd7d6)),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                const Text(
                  'Customized with full unicode symbol support, italic & bold variants.',
                  style: TextStyle(fontSize: 12, color: Color(0xff7f8b8d)),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: const Color(0xff121618),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: const Color(0xff263033)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Client Identity & Pairing',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 8),
                const Text(
                  'This client authenticates against daemons using a persistent cryptographic token stored in secure storage.',
                  style: TextStyle(fontSize: 12, color: Color(0xff9aa6a8), height: 1.4),
                ),
                const SizedBox(height: 10),
                const Text(
                  'Client ID:',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Color(0xffcdd7d6)),
                ),
                const SizedBox(height: 4),
                _CodeSnippetBox(
                  code: widget.clientId ?? retrieveClientId() ?? 'Initializing...',
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Form for one daemon: its address, and the name to show it under. Validates
/// the address with [parseDaemonAddress] and calls [onSubmit] with the raw
/// (un-normalized) text, so the caller persists exactly what the user typed.
///
/// The label is optional — left blank it falls back to the host, which is what
/// an unnamed server would have been called anyway.
class ConnectionSettingsForm extends StatefulWidget {
  const ConnectionSettingsForm({
    super.key,
    required this.onSubmit,
    this.onCancel,
    this.initialAddress,
    this.initialLabel,
    this.submitLabel = 'Connect',
    this.title = 'Connect to a Triage daemon',
    this.subtitle,
  });

  /// Called with the raw address and the label — null when left blank.
  final void Function(String address, String? label) onSubmit;
  final VoidCallback? onCancel;
  final String? initialAddress;
  final String? initialLabel;
  final String submitLabel;
  final String title;
  final String? subtitle;

  @override
  State<ConnectionSettingsForm> createState() => _ConnectionSettingsFormState();
}

class _ConnectionSettingsFormState extends State<ConnectionSettingsForm> {
  late final TextEditingController _controller;
  late final TextEditingController _labelController;
  String? _error;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(
      text: widget.initialAddress ?? '127.0.0.1',
    );
    _labelController = TextEditingController(text: widget.initialLabel ?? '');
  }

  @override
  void dispose() {
    _controller.dispose();
    _labelController.dispose();
    super.dispose();
  }

  void _submit() {
    final raw = _controller.text.trim();
    final uri = parseDaemonAddress(raw);
    if (uri == null) {
      setState(
        () => _error =
            'Enter a valid host, host:port, or ws://, wss://, http://, or https:// URL.',
      );
      return;
    }
    final label = _labelController.text.trim();
    widget.onSubmit(raw, label.isEmpty ? null : label);
  }

  @override
  Widget build(BuildContext context) {
    final preview = parseDaemonAddress(_controller.text.trim());
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(Icons.dns_outlined, color: Color(0xff7fd1c7), size: 22),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                widget.title,
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
        if (widget.subtitle != null) ...[
          const SizedBox(height: 8),
          Text(
            widget.subtitle!,
            style: const TextStyle(color: Color(0xff9aa6a8), fontSize: 13),
          ),
        ],
        const SizedBox(height: 18),
        TextField(
          controller: _controller,
          autofocus: true,
          onChanged: (_) {
            // Single rebuild: clears any stale error and refreshes the preview.
            setState(() => _error = null);
          },
          onSubmitted: (_) => _submit(),
          decoration: InputDecoration(
            labelText: 'Daemon address',
            hintText: '100.64.2.7  ·  192.168.1.5:7777  ·  wss://host:7777',
            errorText: _error,
            prefixIcon: const Icon(Icons.lan_outlined, size: 20),
            border: const OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          preview == null ? 'Will connect to: —' : 'Will connect to: $preview',
          style: const TextStyle(color: Color(0xff7f8b8d), fontSize: 12),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _labelController,
          onSubmitted: (_) => _submit(),
          decoration: InputDecoration(
            labelText: 'Name (optional)',
            hintText: DaemonServer.defaultLabelFor(_controller.text.trim()),
            prefixIcon: const Icon(Icons.label_outline, size: 20),
            border: const OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 20),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            if (widget.onCancel != null) ...[
              TextButton(
                onPressed: widget.onCancel,
                child: const Text('Cancel'),
              ),
              const SizedBox(width: 8),
            ],
            FilledButton.icon(
              onPressed: _submit,
              icon: const Icon(Icons.link, size: 18),
              label: Text(widget.submitLabel),
            ),
          ],
        ),
      ],
    );
  }
}

class _NewSessionMenu extends StatelessWidget {
  const _NewSessionMenu({
    required this.selectedShell,
    required this.shellOptions,
    required this.showShellMenu,
    required this.onCreateSession,
  });

  final NewSessionShell selectedShell;
  final List<NewSessionShell> shellOptions;
  final bool showShellMenu;
  final ValueChanged<NewSessionShell> onCreateSession;

  @override
  Widget build(BuildContext context) {
    if (!showShellMenu || shellOptions.length <= 1) {
      final shell = shellOptions.isEmpty ? selectedShell : shellOptions.first;
      return IconButton(
        tooltip: 'New session',
        icon: const Icon(Icons.add, color: Color(0xffcdd7d6)),
        onPressed: () => onCreateSession(shell),
      );
    }

    return PopupMenuButton<NewSessionShell>(
      tooltip: 'New session',
      icon: const Icon(Icons.add, color: Color(0xffcdd7d6)),
      onSelected: onCreateSession,
      itemBuilder: (context) => [
        for (final shell in shellOptions)
          CheckedPopupMenuItem<NewSessionShell>(
            value: shell,
            checked: shell == selectedShell,
            child: Text('${shell.label} (${shell.command})'),
          ),
      ],
    );
  }
}

class _CustomLabelDialog extends StatefulWidget {
  const _CustomLabelDialog({this.initialLabel});

  final String? initialLabel;

  @override
  State<_CustomLabelDialog> createState() => _CustomLabelDialogState();
}

class _CustomLabelDialogState extends State<_CustomLabelDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialLabel ?? '');
    _controller.selection = TextSelection(
      baseOffset: 0,
      extentOffset: _controller.text.length,
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hasExisting =
        widget.initialLabel != null && widget.initialLabel!.trim().isNotEmpty;
    return AlertDialog(
      backgroundColor: const Color(0xff161b1d),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: Color(0xff2a3437)),
      ),
      title: Text(
        hasExisting ? 'Edit Custom Label' : 'Assign Custom Label',
        style: const TextStyle(
          color: Color(0xffcdd7d6),
          fontSize: 18,
          fontWeight: FontWeight.w700,
        ),
      ),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Set a custom label to easily differentiate this session in the side rail.',
              style: TextStyle(
                color: Color(0xff8b9799),
                fontSize: 13,
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _controller,
              autofocus: true,
              style: const TextStyle(
                color: Color(0xffcdd7d6),
                fontSize: 14,
              ),
              decoration: InputDecoration(
                hintText: 'e.g. Frontend Server, Build Agent, DB Migration',
                hintStyle: const TextStyle(color: Color(0xff607073)),
                filled: true,
                fillColor: const Color(0xff111517),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: const BorderSide(color: Color(0xff2a3437)),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: const BorderSide(color: Color(0xff2a3437)),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: const BorderSide(color: Color(0xff7fd1c7)),
                ),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
              ),
              onSubmitted: (value) => Navigator.of(context).pop(value),
            ),
          ],
        ),
      ),
      actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      actions: [
        if (hasExisting)
          TextButton(
            onPressed: () => Navigator.of(context).pop(''),
            style: TextButton.styleFrom(
              foregroundColor: const Color(0xffe06c75),
            ),
            child: const Text('Clear'),
          ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(null),
          style: TextButton.styleFrom(
            foregroundColor: const Color(0xff7f8b8d),
          ),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_controller.text),
          style: FilledButton.styleFrom(
            backgroundColor: const Color(0xff7fd1c7),
            foregroundColor: const Color(0xff111517),
          ),
          child: const Text('Save'),
        ),
      ],
    );
  }
}

class SessionListTile extends StatefulWidget {
  const SessionListTile({
    super.key,
    required this.title,
    required this.subtitle,
    required this.statusColor,
    required this.icon,
    required this.onTap,
    this.customLabel,
    this.glanceTitle,
    this.branch,
    this.repoName,
    this.worktreeName,
    this.cwd,
    this.snippet,
    this.snippetDetail,
    this.activityAt,
    this.pinned = false,
    this.onUnpin,
    this.indistinguishable = false,
    this.judgeEffective = false,
    this.judgeExplicit,
    this.onToggleJudge,
    this.onContextMenu,
    this.selected = false,
  });

  /// Leading line: the workstream (branch/worktree), not the repo — see
  /// [SessionVm.railTitle].
  final String title;

  /// Custom label assigned to this session by the user, if any.
  final String? customLabel;

  /// Repo-first name for the hover card, which describes the session rather
  /// than distinguishing it from its siblings. Falls back to [title].
  final String? glanceTitle;
  final String subtitle;
  final Color statusColor;
  final IconData icon;
  final VoidCallback onTap;
  // Git context for the glance row + hover popover; hidden when null.
  final String? branch;
  final String? repoName;
  final String? worktreeName;
  // Absolute current working directory, shown in place of the git line when the
  // session isn't inside a repo.
  final String? cwd;
  // Local-LLM one-line description of the session; hidden when null/empty.
  final String? snippet;
  // Local-LLM longer-form summary, shown in the hover popover.
  final String? snippetDetail;
  // When this session last produced a summary; renders as a compact relative
  // time. Null when unknown, which is the normal state until the session moves
  // (see [SessionVm.snippetUpdatedAt]).
  final DateTime? activityAt;
  // True when the user placed this row by hand, so it holds its slot instead of
  // flowing with activity. Marked because a row sitting still while its
  // neighbours move is otherwise unexplained.
  final bool pinned;
  // Releases this row's pin. Null for a local session, which has no daemon id
  // and so can never be pinned in the first place.
  final VoidCallback? onUnpin;
  // True when another row renders the same title and repo, so the snippet is
  // the only thing telling them apart and gets room to say it.
  final bool indistinguishable;
  final bool judgeEffective;
  final bool? judgeExplicit;
  final VoidCallback? onToggleJudge;
  final ValueChanged<Offset>? onContextMenu;
  final bool selected;

  @override
  State<SessionListTile> createState() => _SessionListTileState();
}

class _SessionListTileState extends State<SessionListTile> {
  final OverlayPortalController _popover = OverlayPortalController();
  final LayerLink _link = LayerLink();
  Offset _lastTapDownPosition = Offset.zero;

  Offset _contextMenuPosition() {
    if (_lastTapDownPosition != Offset.zero) {
      return _lastTapDownPosition;
    }
    final box = context.findRenderObject() as RenderBox?;
    if (box != null && box.hasSize) {
      return box.localToGlobal(box.size.center(Offset.zero));
    }
    return Offset.zero;
  }

  /// Context line beneath the title: the repo, plus the worktree when it says
  /// something the title has not already said.
  ///
  /// Null both when there is no git context *and* when every component was
  /// promoted into the title, so it cannot be used to tell those apart — see
  /// `inRepo` in [build], which keys the cwd fallback off `repoName` instead.
  /// Nothing is lost by omitting a component: the hover glance card states
  /// repo, branch, worktree and cwd in full.
  String? get _gitMeta {
    final hasCustom =
        widget.customLabel != null && widget.customLabel!.trim().isNotEmpty;
    final parts = <String>[
      if (widget.repoName != null && widget.repoName != widget.title)
        widget.repoName!,
      if (hasCustom &&
          widget.branch != null &&
          widget.branch != widget.title &&
          widget.branch != widget.repoName)
        widget.branch!,
      if (widget.worktreeName != null &&
          widget.worktreeName != widget.title &&
          !worktreeEchoesBranch(widget.worktreeName!, widget.branch))
        widget.worktreeName!,
    ];
    return parts.isEmpty ? null : parts.join('  ·  ');
  }

  void _showPopover() {
    if (!_popover.isShowing) _popover.show();
  }

  void _hidePopover() {
    if (_popover.isShowing) _popover.hide();
  }

  @override
  void dispose() {
    _hidePopover();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // The rail meta line is the repo, plus a worktree that says something the
    // title has not; it falls back to the working directory outside a repo.
    final gitMeta = _gitMeta;
    final cwd = widget.cwd;
    // An empty meta line is not the same as having no git context: a repo
    // session whose components were all promoted into the title has nothing
    // left to say here. Keying the folder icon and the absolute-cwd fallback
    // off `repoName` keeps them signalling "not in a repo" only when true.
    final inRepo = widget.repoName != null;
    final hasCwdFallback = !inRepo && cwd != null && cwd.isNotEmpty;
    final metaIcon = inRepo
        ? Icons.account_tree_outlined
        : Icons.folder_outlined;
    return CompositedTransformTarget(
      link: _link,
      child: MouseRegion(
        onEnter: (_) => _showPopover(),
        onExit: (_) => _hidePopover(),
        child: OverlayPortal(
          controller: _popover,
          overlayChildBuilder: (context) => Positioned(
            width: 320,
            child: CompositedTransformFollower(
              link: _link,
              showWhenUnlinked: false,
              targetAnchor: Alignment.topRight,
              followerAnchor: Alignment.topLeft,
              offset: const Offset(10, 0),
              child: IgnorePointer(
                child: _SessionGlanceCard(
                  title: widget.glanceTitle ?? widget.title,
                  customLabel: widget.customLabel,
                  status: widget.subtitle,
                  statusColor: widget.statusColor,
                  repoName: widget.repoName,
                  branch: widget.branch,
                  worktreeName: widget.worktreeName,
                  cwd: widget.cwd,
                  snippet: widget.snippet,
                  detail: widget.snippetDetail,
                ),
              ),
            ),
          ),
          child: Semantics(
            button: true,
            selected: widget.selected,
            // The full repo-first name: the visible title is a bare branch, and
            // a screen reader has no meta line beside it to supply the repo.
            label: widget.glanceTitle ?? widget.title,
            child: InkWell(
              onTap: widget.onTap,
              onTapDown: widget.onContextMenu != null
                  ? (details) => _lastTapDownPosition = details.globalPosition
                  : null,
              onSecondaryTapDown: widget.onContextMenu != null
                  ? (details) => widget.onContextMenu!(details.globalPosition)
                  : null,
              onLongPress: widget.onContextMenu != null
                  ? () => widget.onContextMenu!(_contextMenuPosition())
                  : null,
              borderRadius: BorderRadius.circular(8),
              child: Container(
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: widget.selected
                      ? const Color(0xff233033)
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: widget.selected
                        ? const Color(0xff3b5356)
                        : Colors.transparent,
                  ),
                ),
                child: Row(
                  children: [
                    Icon(widget.icon, size: 20, color: const Color(0xffcdd7d6)),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  widget.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                              if (widget.pinned && widget.onUnpin != null)
                                _UnpinButton(
                                  onUnpin: widget.onUnpin!,
                                  what: widget.title,
                                ),
                              if (widget.onToggleJudge != null)
                                _JudgeToggleButton(
                                  effective: widget.judgeEffective,
                                  explicit: widget.judgeExplicit,
                                  onToggle: widget.onToggleJudge!,
                                ),
                            ],
                          ),
                          if (gitMeta != null || hasCwdFallback) ...[
                            const SizedBox(height: 3),
                            Row(
                              children: [
                                Icon(
                                  metaIcon,
                                  size: 12,
                                  color: const Color(0xff7f8b8d),
                                ),
                                const SizedBox(width: 5),
                                Expanded(
                                  child: _MetaLineText(
                                    // Git meta is already compact (leaf names);
                                    // the cwd fallback shows the absolute path,
                                    // collapsing to ~/… or scrolling when long.
                                    full: gitMeta ?? cwd!,
                                    abbreviated: gitMeta == null
                                        ? _homeAbbreviatedPath(cwd!)
                                        : null,
                                    // Marquee only the selected row, to keep the
                                    // rail quiet (per design).
                                    animate: widget.selected,
                                    style: const TextStyle(
                                      color: Color(0xff8b9799),
                                      fontSize: 11,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ],
                          // Outranks the status line: for two sessions on one
                          // branch this is the only field that differs, where
                          // every row shares a status.
                          if (widget.snippet != null &&
                              widget.snippet!.isNotEmpty) ...[
                            const SizedBox(height: 3),
                            Text(
                              widget.snippet!,
                              // Indistinguishable rows get a second line rather
                              // than ellipsising the one thing that would have
                              // told them apart.
                              maxLines: widget.indistinguishable ? 2 : 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Color(0xffc4cecd),
                                fontSize: 12,
                                fontStyle: FontStyle.italic,
                              ),
                            ),
                          ],
                          const SizedBox(height: 3),
                          Row(
                            children: [
                              Container(
                                width: 8,
                                height: 8,
                                decoration: BoxDecoration(
                                  color: widget.statusColor,
                                  shape: BoxShape.circle,
                                ),
                              ),
                              const SizedBox(width: 6),
                              Expanded(
                                child: Text(
                                  widget.subtitle,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: Color(0xff9aa6a8),
                                  ),
                                ),
                              ),
                              if (widget.activityAt != null) ...[
                                const SizedBox(width: 6),
                                _RelativeActivityText(at: widget.activityAt!),
                              ],
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Rich hover popover for a session row: full git context + the longer-form
/// LLM detail summary (falls back to the one-liner, then a placeholder).
class _SessionGlanceCard extends StatelessWidget {
  const _SessionGlanceCard({
    required this.title,
    required this.status,
    required this.statusColor,
    required this.repoName,
    required this.branch,
    required this.worktreeName,
    required this.cwd,
    required this.snippet,
    required this.detail,
    this.customLabel,
  });

  final String title;
  final String? customLabel;
  final String status;
  final Color statusColor;
  final String? repoName;
  final String? branch;
  final String? worktreeName;
  final String? cwd;
  final String? snippet;
  final String? detail;

  @override
  Widget build(BuildContext context) {
    final summary = (detail != null && detail!.isNotEmpty)
        ? detail!
        : (snippet != null && snippet!.isNotEmpty
              ? snippet!
              : 'No summary yet.');
    final custom = customLabel?.trim();
    final hasCustomLabel = custom != null && custom.isNotEmpty;
    final hasBranch = branch != null && branch!.isNotEmpty;
    final hasWorktree = worktreeName != null && worktreeName != branch;
    final hasCwd = cwd != null && cwd!.isNotEmpty;
    final showCustomLabelRow = hasCustomLabel && title != custom;
    final hasDetails = showCustomLabelRow ||
        repoName != null ||
        hasBranch ||
        hasWorktree ||
        hasCwd;
    return Material(
      color: Colors.transparent,
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: const Color(0xff1b2327),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: const Color(0xff334044)),
          boxShadow: const [
            BoxShadow(
              color: Color(0x66000000),
              blurRadius: 16,
              offset: Offset(0, 6),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: statusColor,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 7),
                Expanded(
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 13,
                    ),
                  ),
                ),
                Text(
                  status,
                  style: const TextStyle(
                    color: Color(0xff9aa6a8),
                    fontSize: 11,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            if (showCustomLabelRow)
              _GlanceRow(icon: Icons.label_outline, label: custom),
            if (repoName != null)
              _GlanceRow(icon: Icons.folder_outlined, label: repoName!),
            if (hasBranch)
              _GlanceRow(icon: Icons.account_tree_outlined, label: branch!),
            if (hasWorktree)
              _GlanceRow(icon: Icons.alt_route, label: worktreeName!),
            // The full working directory, wrapping across lines so the whole
            // path is readable here even when the rail line had to truncate it.
            if (hasCwd)
              _GlanceRow(
                icon: Icons.subdirectory_arrow_right,
                label: cwd!,
                wrap: true,
              ),
            if (hasDetails)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Divider(height: 1, color: Color(0xff2b363a)),
              ),
            Text(
              summary,
              style: const TextStyle(
                color: Color(0xffc4cecd),
                fontSize: 12,
                height: 1.35,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _GlanceRow extends StatelessWidget {
  const _GlanceRow({
    required this.icon,
    required this.label,
    this.wrap = false,
  });

  final IconData icon;
  final String label;
  // When true the label wraps across lines instead of truncating — used for the
  // full working-directory path so it stays fully readable in the popover.
  final bool wrap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        crossAxisAlignment: wrap
            ? CrossAxisAlignment.start
            : CrossAxisAlignment.center,
        children: [
          Icon(icon, size: 13, color: const Color(0xff7f8b8d)),
          const SizedBox(width: 7),
          Expanded(
            child: Text(
              label,
              maxLines: wrap ? null : 1,
              overflow: wrap ? TextOverflow.clip : TextOverflow.ellipsis,
              style: const TextStyle(color: Color(0xffb4bfc0), fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}

/// Lowercases [value] and reduces every run of non-alphanumerics to a single
/// `-`, so `feat/rail-row` and `feat-rail-row` compare equal.
String _slugify(String value) => value
    .toLowerCase()
    .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
    .replaceAll(RegExp(r'^-+|-+$'), '');

/// True when [worktree] only restates [branch], under either common naming
/// convention: the whole branch flattened (`feat/rail-row` → `feat-rail-row`),
/// or just its last segment, which is what this project's own
/// `git worktree add worktrees/<name> -b <type>/<name>` recipe produces
/// (`feat/rail-row` → `rail-row`).
///
/// The rail leads with the branch, so an echoing worktree name would spend the
/// tile's second line repeating the first. The hover glance card still shows
/// both, unabbreviated, for the cases where the distinction matters.
@visibleForTesting
bool worktreeEchoesBranch(String worktree, String? branch) {
  if (branch == null) return false;
  final full = _slugify(branch);
  if (full.isEmpty) return false;
  final slug = _slugify(worktree);
  if (slug == full) return true;
  final lastSegment = branch.split('/').last;
  final tail = _slugify(lastSegment);
  return tail.isNotEmpty && slug == tail;
}

/// Indices of rail rows whose title *and* repo both match another row's, so
/// their leading lines are identical and cannot tell them apart.
///
/// This is the two-agents-on-one-branch case. The snippet is then the only
/// differentiator that exists, so the tile gives it a second line rather than
/// ellipsising the one thing that would have distinguished the rows.
///
/// Keyed on the rendered title and the repo rather than on the underlying git
/// fields, since the defect is "these rows read the same". It deliberately
/// ignores the meta line: two rows can share a title and repo yet differ there,
/// which costs a needless second snippet line and nothing else.
/// Separator for the grouping key in [indistinguishableRailRows].
///
/// `\u0000` because it cannot occur in a title or a repo name, so no pair of
/// rows can collide by containing the separator themselves — `a|b` + `c` and
/// `a` + `b|c` would otherwise group together. Written as an escape rather than
/// the literal control character, which is invisible in an editor and can make
/// tooling treat the file as binary.
const String _railGroupSeparator = '\u0000';

@visibleForTesting
Set<int> indistinguishableRailRows(List<SessionVm> sessions, [DateTime? now]) {
  // One clock for the whole pass, and the same one the tiles render against, so
  // the grouping key can never sample the inferred-worktree TTL at a different
  // instant than the rendered [SessionVm.railTitleAt] title it is grouping on.
  final at = now ?? DateTime.now();
  final groups = <String, List<int>>{};
  for (var i = 0; i < sessions.length; i++) {
    final key =
        '${sessions[i].railTitleAt(at)}$_railGroupSeparator${sessions[i].repoName ?? ''}';
    groups.putIfAbsent(key, () => <int>[]).add(i);
  }
  return {
    for (final group in groups.values)
      if (group.length > 1) ...group,
  };
}

/// Compact "how long since this session last did something" label, e.g. `now`,
/// `4m`, `2h`, `3d`.
///
/// Null when [at] is null; see [SessionVm.snippetUpdatedAt] for why a row may
/// legitimately have no stamp.
@visibleForTesting
String? formatRelativeActivity(DateTime? at, DateTime now) {
  if (at == null) return null;
  final elapsed = now.difference(at);
  // A stamp in the future is clock skew between stamping and rendering, not
  // time travel; `inSeconds` going negative lands here and reads as "now".
  if (elapsed.inSeconds < 60) return 'now';
  if (elapsed.inMinutes < 60) return '${elapsed.inMinutes}m';
  if (elapsed.inHours < 24) return '${elapsed.inHours}h';
  return '${elapsed.inDays}d';
}

/// A rail row's identity: the daemon's session id, or a local-only fallback for
/// a scratch session that has none.
///
/// The rail spells this out in three places (the reorder handler, the layout's
/// row list, and the tile's `ValueKey`) and they must agree exactly: the layout
/// maps a drop index back to a row by this key, and a `ValueKey` that disagreed
/// with the list it was built from would reorder the wrong row.
String _rowKeyFor(SessionVm session) =>
    session.remoteSessionId ?? 'local:${session.title}';

/// Collapses a leading local-home prefix to `~` — e.g. `/Users/me/dev` →
/// `~/dev`. Returns null when [path] is not under the local home (e.g. a path
/// from a remote daemon), so callers fall back to showing it in full.
String? _homeAbbreviatedPath(String path) {
  final normalized = trimTrailingSlash(localHomeDir());
  if (normalized == null) return null;
  if (path == normalized) return '~';
  if (path.startsWith('$normalized/') || path.startsWith('$normalized\\')) {
    return '~${path.substring(normalized.length)}';
  }
  return null;
}

/// A relative activity stamp ("4m") that ages in place.
///
/// Owns its ticker instead of having the page drive one: a `setState` on the
/// host rebuilds the workspace and its terminal panes, and re-running that
/// layout on a timer just to age a label is a bad trade. Only this text
/// rebuilds.
class _RelativeActivityText extends StatefulWidget {
  const _RelativeActivityText({required this.at});

  final DateTime at;

  @override
  State<_RelativeActivityText> createState() => _RelativeActivityTextState();
}

class _RelativeActivityTextState extends State<_RelativeActivityText> {
  // Half the label's finest step (a minute), so the visible value is never more
  // than ~30s stale without waking the widget more than twice a minute.
  static const Duration _tickInterval = Duration(seconds: 30);

  Timer? _timer;

  @override
  void initState() {
    super.initState();
    if (!runningUnderFlutterTest()) {
      _timer = Timer.periodic(_tickInterval, (_) {
        if (mounted) setState(() {});
      });
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Non-null: `at` is non-nullable, and the formatter returns null only for a
    // null stamp.
    final label = formatRelativeActivity(widget.at, DateTime.now())!;
    return Text(
      label,
      maxLines: 1,
      style: const TextStyle(color: Color(0xff7f8b8d), fontSize: 11),
    );
  }
}

/// Renders a single-line meta string that adapts to the available width: shows
/// [full] when it fits; else [abbreviated] (e.g. a `~/…` path) when that fits;
/// else scrolls it as a marquee when [animate] is set, or truncates with an
/// ellipsis. The marquee is reserved for the selected row so the rail stays
/// quiet.
class _MetaLineText extends StatelessWidget {
  const _MetaLineText({
    required this.full,
    required this.abbreviated,
    required this.animate,
    required this.style,
  });

  final String full;
  final String? abbreviated;
  final bool animate;
  final TextStyle style;

  bool _fits(String text, double maxWidth) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      maxLines: 1,
      textDirection: TextDirection.ltr,
    )..layout();
    return painter.width <= maxWidth;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final maxWidth = constraints.maxWidth;
        if (maxWidth.isFinite && _fits(full, maxWidth)) {
          return Text(full, style: style, maxLines: 1, softWrap: false);
        }
        final abbr = abbreviated;
        if (abbr != null && maxWidth.isFinite && _fits(abbr, maxWidth)) {
          return Text(abbr, style: style, maxLines: 1, softWrap: false);
        }
        if (animate && marqueeAnimationsEnabled()) {
          return _MarqueeText(text: full, style: style);
        }
        // Static fallback: prefer the abbreviated form so the most meaningful
        // tail still shows before the ellipsis.
        return Text(
          abbr ?? full,
          style: style,
          maxLines: 1,
          softWrap: false,
          overflow: TextOverflow.ellipsis,
        );
      },
    );
  }
}

/// Horizontally scrolls [text] back and forth so an over-long single line stays
/// fully readable. One there-and-back cycle takes [cyclePeriod] with a brief
/// pause at each end. Renders as static text when the content already fits.
class _MarqueeText extends StatefulWidget {
  const _MarqueeText({required this.text, required this.style});

  final String text;
  final TextStyle style;

  /// One full there-and-back scroll cycle takes roughly this long.
  static const Duration cyclePeriod = Duration(seconds: 15);

  @override
  State<_MarqueeText> createState() => _MarqueeTextState();
}

class _MarqueeTextState extends State<_MarqueeText>
    with SingleTickerProviderStateMixin {
  final ScrollController _scroll = ScrollController();
  late final AnimationController _controller = AnimationController(
    vsync: this,
    // Half a cycle per direction; repeat(reverse:) gives the full there-and-back.
    duration: _MarqueeText.cyclePeriod ~/ 2,
  );

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onTick);
    WidgetsBinding.instance.addPostFrameCallback((_) => _start());
  }

  @override
  void didUpdateWidget(_MarqueeText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _start());
    }
  }

  void _start() {
    if (!mounted || !_scroll.hasClients) return;
    if (_scroll.position.maxScrollExtent <= 0) {
      _controller
        ..stop()
        ..value = 0;
      return;
    }
    if (!_controller.isAnimating) {
      _controller.repeat(reverse: true);
    }
  }

  void _onTick() {
    if (!_scroll.hasClients) return;
    final max = _scroll.position.maxScrollExtent;
    if (max <= 0) return;
    _scroll.jumpTo(max * _holdEased(_controller.value));
  }

  /// Eases 0→1 with a hold at each end so the scroll pauses before reversing.
  double _holdEased(double v) {
    const hold = 0.12;
    if (v <= hold) return 0;
    if (v >= 1 - hold) return 1;
    return Curves.easeInOut.transform((v - hold) / (1 - 2 * hold));
  }

  @override
  void dispose() {
    _controller.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      controller: _scroll,
      scrollDirection: Axis.horizontal,
      physics: const NeverScrollableScrollPhysics(),
      child: Text(
        widget.text,
        style: widget.style,
        maxLines: 1,
        softWrap: false,
      ),
    );
  }
}

class SessionWorkspace extends StatelessWidget {
  const SessionWorkspace({
    super.key,
    required this.session,
    this.onCloseSession,
    this.onViewFit,
    this.onOpenRail,
    this.onRefit,
    this.onToggleJudge,
  });

  final SessionVm session;
  final VoidCallback? onCloseSession;
  final void Function(int cols, int rows)? onViewFit;
  // Mobile only: opens the session rail overlay from the workspace header.
  final VoidCallback? onOpenRail;
  // Re-asserts this device's terminal size on the shared PTY.
  final VoidCallback? onRefit;
  final VoidCallback? onToggleJudge;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        WorkspaceHeader(
          session: session,
          onClose: onCloseSession,
          onOpenRail: onOpenRail,
          onRefit: onRefit,
          onToggleJudge: onToggleJudge,
        ),
        Expanded(
          child: TerminalPane(
            key: ValueKey(session.title),
            terminalId: session.title,
            controller: session.terminalController,
            terminal: session.terminal,
            fallbackRows: session.rows,
            onTerminalResizeBind: (callback) {
              session.onTerminalResize = callback;
            },
            onViewFit: (cols, rows) =>
                (onViewFit ?? session.noteViewFit)(cols, rows),
            focusCursorRevision: session.focusCursorRevision,
            bracketedPasteEnabled: session.bracketedPasteEnabled,
            isExited: session.status == 'exited',
          ),
        ),
      ],
    );
  }
}

class WorkspaceHeader extends StatelessWidget {
  const WorkspaceHeader({
    super.key,
    required this.session,
    this.onClose,
    this.onOpenRail,
    this.onRefit,
    this.onToggleJudge,
  });

  final SessionVm session;
  final VoidCallback? onClose;
  // Mobile only: opens the session rail overlay. Null on desktop, where the
  // rail is always visible beside the workspace.
  final VoidCallback? onOpenRail;
  // Re-asserts this device's terminal size on the shared PTY, so switching back
  // to this device reclaims the size from whichever device resized it last.
  final VoidCallback? onRefit;
  final VoidCallback? onToggleJudge;

  @override
  Widget build(BuildContext context) {
    // Header subtitle: the branch when in a repo, else the working directory
    // (home-abbreviated), so a non-repo session still shows where it is.
    // When a custom label is active, show repo and branch so full git context
    // remains visible under the custom title.
    final cwd = session.cwd;
    final branch = session.branch;
    final inRepo = session.repoName != null;
    final hasBranch = branch != null && branch.trim().isNotEmpty;
    final fallbackCwd = (cwd != null && cwd.isNotEmpty)
        ? (_homeAbbreviatedPath(cwd) ?? cwd)
        : '';
    final String headerMeta;
    if (session.trimmedCustomLabel != null) {
      if (inRepo && hasBranch) {
        headerMeta = '${session.repoName!}  ·  $branch';
      } else if (inRepo) {
        headerMeta = session.repoName!;
      } else {
        headerMeta = fallbackCwd;
      }
    } else {
      headerMeta = hasBranch ? branch : fallbackCwd;
    }
    return Container(
      height: 68,
      padding: const EdgeInsets.symmetric(horizontal: 22),
      decoration: const BoxDecoration(
        color: Color(0xff151a1d),
        border: Border(bottom: BorderSide(color: Color(0xff263033))),
      ),
      child: Row(
        children: [
          if (onOpenRail != null) ...[
            IconButton(
              icon: const Icon(Icons.menu, color: Color(0xffcdd7d6)),
              tooltip: 'Sessions',
              onPressed: onOpenRail,
            ),
            const SizedBox(width: 4),
          ],
          Icon(session.icon, color: const Color(0xff7fd1c7)),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  session.displayTitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  headerMeta,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Color(0xff9aa6a8)),
                ),
              ],
            ),
          ),
          if (onToggleJudge != null) ...[
            IconButton(
              icon: session.judgePolicyEffective
                  ? const Icon(
                      Icons.auto_awesome,
                      size: 20,
                      color: Color(0xff7fd1c7),
                    )
                  : const Icon(
                      Icons.person_outline,
                      size: 20,
                      color: Color(0xffffc857),
                    ),
              tooltip: session.judgePolicyEffective
                  ? (session.judgePolicyExplicit == true
                      ? 'Auto-Approval: ON (click to disable)'
                      : 'Auto-Approval: Default ON (click to disable)')
                  : (session.judgePolicyExplicit == false
                      ? 'Auto-Approval: OFF (click to enable)'
                      : 'Auto-Approval: Default OFF (click to enable)'),
              onPressed: onToggleJudge,
            ),
            const SizedBox(width: 4),
          ],
          Icon(Icons.circle, size: 12, color: session.statusColor),
          const SizedBox(width: 8),
          Text(
            session.status,
            style: const TextStyle(color: Color(0xffcdd7d6)),
          ),
          const SizedBox(width: 8),
          if (onRefit != null)
            IconButton(
              icon: const Icon(Icons.fit_screen, color: Color(0xffcdd7d6)),
              tooltip: 'Refit terminal to this device',
              onPressed: onRefit,
            ),
          const SizedBox(width: 8),
          if (onClose != null)
            IconButton(
              icon: const Icon(Icons.close, color: Color(0xffcdd7d6)),
              tooltip: 'Close session',
              onPressed: onClose,
            )
          else
            const Icon(Icons.more_horiz, color: Color(0xffcdd7d6)),
        ],
      ),
    );
  }
}

class _PairingView extends StatefulWidget {
  const _PairingView({
    required this.deviceCode,
    required this.verificationUri,
    required this.daemonHostUri,
    required this.expiresAt,
    required this.isChallengeLoading,
    required this.challengeError,
    required this.onRefreshChallenge,
    required this.onPair,
    required this.onCancel,
  });

  final String? deviceCode;
  // The clickable pairing URL, non-null only when the daemon is on this machine.
  final Uri? verificationUri;
  // The `127.0.0.1:<port>/pair` URL to open on the daemon host, shown as an
  // instruction when `verificationUri` is null (a remote daemon).
  final Uri? daemonHostUri;
  final DateTime? expiresAt;
  final bool isChallengeLoading;
  final String? challengeError;
  final Future<void> Function() onRefreshChallenge;
  final Future<void> Function(String pin) onPair;
  final VoidCallback onCancel;

  @override
  State<_PairingView> createState() => _PairingViewState();
}

class _PairingViewState extends State<_PairingView> {
  final TextEditingController _pinController = TextEditingController();
  bool _isLoading = false;
  String? _errorMessage;

  @override
  void dispose() {
    _pinController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final pin = _pinController.text
        .replaceAll(RegExp(r'\s+'), '')
        .toUpperCase()
        .replaceAll(RegExp(r'[IL]'), '1')
        .replaceAll('O', '0');
    final validChars = RegExp(r'^[0-9A-HJ-KM-NP-TV-Z]{8}$');
    if (!validChars.hasMatch(pin)) {
      setState(() {
        _errorMessage =
            'PIN must be 8 characters (letters and digits, excluding U)';
      });
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      await widget.onPair(pin);
    } catch (e) {
      setState(() {
        _isLoading = false;
        _errorMessage = e.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  String _expiryLabel(DateTime? expiresAt) {
    if (expiresAt == null) return '';
    final hour = expiresAt.hour.toString().padLeft(2, '0');
    final minute = expiresAt.minute.toString().padLeft(2, '0');
    return 'Expires at $hour:$minute';
  }

  Future<void> _copyText(String label, String value) async {
    await Clipboard.setData(ClipboardData(text: value));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('$label copied'),
        duration: const Duration(milliseconds: 1400),
      ),
    );
  }

  Future<void> _openVerificationUri(Uri uri) async {
    final opened = await openExternalUri(uri);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          opened ? 'Verification page opened' : 'Open this URL in a browser',
        ),
        duration: const Duration(milliseconds: 1400),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final deviceCode = widget.deviceCode;
    final verificationUri = widget.verificationUri;
    final hasVerificationUri = verificationUri != null;
    final daemonHostUri = widget.daemonHostUri;
    final expiryLabel = _expiryLabel(widget.expiresAt);

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(Icons.security, color: Color(0xff7fd1c7), size: 28),
            const SizedBox(width: 12),
            const Text(
              'Pair Remote Device',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w700,
                color: Colors.white,
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        Text(
          hasVerificationUri
              ? 'This browser is not paired with the Triage daemon. Open the verification URL, enter this device code to get a PIN, then enter the PIN below.'
              : daemonHostUri != null
              ? 'This browser is not paired with the Triage daemon. On the computer running triaged, open the URL below and enter this device code to get a PIN, then enter the PIN below.'
              : 'This browser is not paired with the Triage daemon. On the computer running triaged, open the daemon pairing page and enter this device code to get a PIN, then enter the PIN below.',
          style: const TextStyle(
            color: Color(0xffa5b1b4),
            fontSize: 14,
            height: 1.4,
          ),
        ),
        const SizedBox(height: 18),
        if (widget.isChallengeLoading && deviceCode == null)
          const Center(
            child: Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: CircularProgressIndicator(
                strokeWidth: 2.5,
                valueColor: AlwaysStoppedAnimation<Color>(Color(0xff7fd1c7)),
              ),
            ),
          )
        else ...[
          if (hasVerificationUri) ...[
            const Text(
              'Verification URL',
              style: TextStyle(color: Color(0xff7f8b8d), fontSize: 12),
            ),
            const SizedBox(height: 6),
            Tooltip(
              message: 'Open verification URL',
              child: SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: () => _openVerificationUri(verificationUri),
                  icon: const Icon(Icons.open_in_new, size: 18),
                  label: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      verificationUri.toString(),
                      overflow: TextOverflow.ellipsis,
                      maxLines: 1,
                    ),
                  ),
                  style: OutlinedButton.styleFrom(
                    alignment: Alignment.centerLeft,
                    foregroundColor: const Color(0xff7fd1c7),
                    side: const BorderSide(color: Color(0xff344145)),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 12,
                    ),
                  ),
                ),
              ),
            ),
          ] else ...[
            const Text(
              'Open on the computer running triaged',
              style: TextStyle(color: Color(0xff7f8b8d), fontSize: 12),
            ),
            const SizedBox(height: 6),
            if (daemonHostUri != null)
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: SelectableText(
                      daemonHostUri.toString(),
                      style: const TextStyle(
                        color: Color(0xffcdd7d6),
                        fontSize: 14,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Tooltip(
                    message: 'Copy pairing URL',
                    child: IconButton(
                      icon: const Icon(
                        Icons.copy,
                        size: 18,
                        color: Color(0xff7f8b8d),
                      ),
                      onPressed: () =>
                          _copyText('Pairing URL', daemonHostUri.toString()),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                    ),
                  ),
                ],
              )
            else
              const Text(
                'Use the daemon host pairing page or run triage pair.',
                style: TextStyle(color: Color(0xffcdd7d6), fontSize: 14),
              ),
          ],
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 12,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xff101517),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: const Color(0xff344145)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Device Code',
                        style: TextStyle(
                          color: Color(0xff7f8b8d),
                          fontSize: 12,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          Expanded(
                            child: SelectableText(
                              deviceCode ?? '--------',
                              style: const TextStyle(
                                color: Color(0xffedf7f6),
                                fontSize: 24,
                                fontWeight: FontWeight.w800,
                                letterSpacing: 4,
                              ),
                            ),
                          ),
                          IconButton(
                            tooltip: 'Copy device code',
                            onPressed: deviceCode == null
                                ? null
                                : () => _copyText('Device code', deviceCode),
                            icon: const Icon(Icons.copy, size: 20),
                            color: const Color(0xff7fd1c7),
                          ),
                        ],
                      ),
                      if (expiryLabel.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Text(
                          expiryLabel,
                          style: const TextStyle(
                            color: Color(0xff7f8b8d),
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 10),
              IconButton(
                onPressed: widget.isChallengeLoading
                    ? null
                    : () => widget.onRefreshChallenge(),
                icon: widget.isChallengeLoading
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2.2,
                          valueColor: AlwaysStoppedAnimation<Color>(
                            Color(0xff7fd1c7),
                          ),
                        ),
                      )
                    : const Icon(Icons.refresh),
                tooltip: 'Refresh device code',
                color: const Color(0xffcdd7d6),
              ),
            ],
          ),
        ],
        if (widget.challengeError != null) ...[
          const SizedBox(height: 12),
          Text(
            widget.challengeError!,
            style: const TextStyle(color: Color(0xffff6b6b), fontSize: 13),
          ),
        ],
        const SizedBox(height: 24),
        TextField(
          controller: _pinController,
          maxLength: 8,
          textCapitalization: TextCapitalization.characters,
          style: const TextStyle(
            fontSize: 22,
            letterSpacing: 6,
            fontWeight: FontWeight.bold,
            color: Color(0xff7fd1c7),
          ),
          decoration: const InputDecoration(
            labelText: '8-Character PIN',
            labelStyle: TextStyle(
              fontSize: 14,
              letterSpacing: 0,
              color: Color(0xff7f8b8d),
            ),
            counterText: '',
            border: OutlineInputBorder(),
            enabledBorder: OutlineInputBorder(
              borderSide: BorderSide(color: Color(0xff2a3437)),
            ),
            focusedBorder: OutlineInputBorder(
              borderSide: BorderSide(color: Color(0xff7fd1c7)),
            ),
          ),
          onSubmitted: (_) => _isLoading ? null : _submit(),
        ),
        if (_errorMessage != null) ...[
          const SizedBox(height: 12),
          Text(
            _errorMessage!,
            style: const TextStyle(color: Color(0xffff6b6b), fontSize: 13),
          ),
        ],
        const SizedBox(height: 24),
        Wrap(
          alignment: WrapAlignment.end,
          spacing: 12,
          runSpacing: 8,
          children: [
            TextButton(
              onPressed: _isLoading ? null : widget.onCancel,
              style: TextButton.styleFrom(
                foregroundColor: const Color(0xff7f8b8d),
              ),
              child: const Text('Cancel (Offline Mode)'),
            ),
            ElevatedButton(
              onPressed: _isLoading ? null : _submit,
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xff2b6f6f),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 12,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              child: _isLoading
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.5,
                        valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                      ),
                    )
                  : const Text('Pair Device'),
            ),
          ],
        ),
      ],
    );
  }
}
