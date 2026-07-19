use std::fs;
use std::io::{self, Write};
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::thread;
use std::time::{Duration, SystemTime};

/// Bounds the recursive source walk so a symlink cycle cannot spin forever.
const MAX_WATCH_DEPTH: u32 = 32;

/// Flutter client sources whose mtimes decide whether `build/web` is stale.
/// Relative to `flutter/triage_client/`.
const CLIENT_SOURCES: &[&str] = &[
    "lib",
    "web",
    "assets",
    "fonts",
    "pubspec.yaml",
    "pubspec.lock",
];

fn main() {
    println!("cargo:rustc-check-cfg=cfg(embed_real_client)");
    println!("cargo:rustc-check-cfg=cfg(embed_packaged_client)");
    println!("cargo:rerun-if-env-changed=TRIAGE_SKIP_FLUTTER_BUILD");

    // Watch the crate root so that staging a `dist/` (release packaging) is
    // noticed. `dist` itself must only be watched once it exists: cargo treats a
    // `rerun-if-changed` path that is missing as permanently dirty, which would
    // rebuild this crate on every single invocation.
    println!("cargo:rerun-if-changed=.");
    if Path::new("dist").exists() {
        println!("cargo:rerun-if-changed=dist");
    }

    let packaged_client_path = Path::new("dist/index.html");
    let client_dir = Path::new("../../flutter/triage_client");
    let dev_client_path = client_dir.join("build/web/index.html");

    // Release packaging (see .github/workflows/publish.yml) stages a prebuilt
    // bundle into `dist/`. That always wins, and never triggers a local build.
    if packaged_client_path.exists() {
        println!("cargo:rustc-cfg=embed_packaged_client");
        return;
    }

    ensure_dev_client(client_dir, &dev_client_path);

    if dev_client_path.exists() {
        // Watch the bundle itself so that regenerating it by other means (a
        // manual `flutter build web`) still invalidates this crate. Emitted only
        // once it exists — a missing watched path is permanently dirty.
        println!("cargo:rerun-if-changed={}", dev_client_path.display());
        println!("cargo:rustc-cfg=embed_real_client");
    } else {
        warn(
            "no Flutter web bundle found; embedding the placeholder client from web_fallback/. \
             Run `flutter build web --release` in flutter/triage_client to get the real UI.",
        );
    }
}

/// Rebuild `flutter/triage_client/build/web` when the Dart sources are newer
/// than the last bundle, so `cargo build`/`cargo install` can't quietly embed a
/// stale client. Skipped when the sources aren't present (crates.io consumers),
/// when Flutter isn't installed (the Rust-only CI job), or on explicit opt-out.
fn ensure_dev_client(client_dir: &Path, dev_client_path: &Path) {
    let mut newest_source: Option<SystemTime> = None;
    for entry in CLIENT_SOURCES {
        let path = client_dir.join(entry);
        watch(&path, &mut newest_source, MAX_WATCH_DEPTH);
    }

    // Nothing to watch means this isn't a full checkout (e.g. a crates.io
    // source tarball), so there is nothing to build from.
    let Some(newest_source) = newest_source else {
        return;
    };

    // Only affirmative values opt out; an empty or negative value must not
    // silently disable the rebuild, since that reintroduces the stale bundle
    // this script exists to prevent.
    if std::env::var_os("TRIAGE_SKIP_FLUTTER_BUILD")
        .is_some_and(|value| !matches!(value.to_str(), None | Some("") | Some("0") | Some("false")))
    {
        return;
    }

    if bundle_is_current(client_dir, dev_client_path, newest_source) {
        return;
    }

    let Some(flutter) = flutter_command() else {
        // Deliberately silent about what is embedded instead: the caller warns
        // when no bundle exists at all, and claiming one was "left in place"
        // here would be wrong in exactly that case.
        warn(
            "Flutter client sources changed but the `flutter` command was not found; \
             the web bundle was not rebuilt.",
        );
        return;
    };

    // Serialize against other cargo invocations (a terminal build racing
    // rust-analyzer's `cargo check`) so two Flutter builds can't interleave
    // writes into the same output directory.
    let _lock = BuildLock::acquire(&client_dir.join("build/.triage-flutter-build.lock"));

    // Whoever held the lock may have produced a current bundle while we waited.
    if bundle_is_current(client_dir, dev_client_path, newest_source) {
        return;
    }

    let reason = if dev_client_path.exists() {
        "out of date"
    } else {
        "missing"
    };
    println!(
        "cargo:warning=Flutter web bundle is {reason}; running `flutter build web --release` (this can take a minute)"
    );

    // Matches the release build in .github/workflows/publish.yml so local
    // builds embed the same bundle shape as published ones. `flutter build`
    // runs `pub get` itself, so no separate step is needed.
    let status = Command::new(flutter)
        .args(["build", "web", "--release"])
        .current_dir(client_dir)
        .status();

    match status {
        // Stamp only on success, so a failed build is retried rather than
        // mistaken for a current one.
        Ok(status) if status.success() => {
            let stamp = build_stamp_path(client_dir);
            if let Err(err) = fs::write(&stamp, b"") {
                warn(&format!(
                    "could not write the build stamp {}: {err}. The client will rebuild on \
                     every cargo build until this is fixed.",
                    stamp.display()
                ));
            }
        }
        Ok(status) => panic!(
            "`flutter build web --release` failed with {status}. Fix the client build, or set \
             TRIAGE_SKIP_FLUTTER_BUILD=1 to build the daemon against the existing bundle."
        ),
        Err(err) => panic!(
            "could not run `flutter build web --release`: {err}. Set \
             TRIAGE_SKIP_FLUTTER_BUILD=1 to build the daemon against the existing bundle."
        ),
    }
}

/// Whether the last *successful* build covered every current source.
///
/// Keyed on a stamp this script writes after Flutter exits zero, not on a file
/// from the bundle: `flutter build web` copies `index.html` into place before it
/// compiles, so a build that fails partway leaves a fresh `index.html` beside
/// stale JS. Trusting that would silently mark a broken bundle as current.
///
/// The comparison is strict because filesystems with coarse (1s) mtime
/// granularity would otherwise report a source saved in the same tick as the
/// stamp write as already built, dropping that edit from the embedded client.
fn bundle_is_current(client_dir: &Path, dev_client_path: &Path, newest_source: SystemTime) -> bool {
    // The stamp alone is not enough: deleting `build/web` to force a clean
    // client build leaves the stamp behind, and trusting it would embed the
    // placeholder instead of rebuilding.
    dev_client_path.exists()
        && build_stamp_path(client_dir)
            .metadata()
            .and_then(|meta| meta.modified())
            .is_ok_and(|built_at| built_at > newest_source)
}

/// Marker recording when Flutter last completed a build successfully. Lives in
/// the gitignored `build/` directory alongside the bundle it describes, so
/// deleting `build/` correctly forces a rebuild.
fn build_stamp_path(client_dir: &Path) -> PathBuf {
    client_dir.join("build/.triage-client-stamp")
}

/// Advisory cross-process lock held for the duration of a Flutter build.
///
/// Released on drop, including when the build panics. A build *killed* outright
/// never runs `Drop`, so the holder also refreshes the lock's mtime on a
/// heartbeat and waiters reclaim a lock that has gone quiet.
struct BuildLock {
    path: PathBuf,
    token: String,
    stop: Arc<AtomicBool>,
    heartbeat: Option<thread::JoinHandle<()>>,
}

impl BuildLock {
    const TICK: Duration = Duration::from_millis(250);
    const MAX_WAIT: Duration = Duration::from_secs(15 * 60);
    /// How often the holder refreshes the lock's mtime while building.
    const HEARTBEAT: Duration = Duration::from_secs(30);
    /// A lock whose mtime has not advanced in this long belongs to a process
    /// that died without running `Drop` — a build killed with Ctrl-C, say. Must
    /// stay well below `MAX_WAIT`, or a waiter gives up before it can ever reap
    /// and a single killed build wedges every later one.
    const STALE_AFTER: Duration = Duration::from_secs(2 * 60);

    /// Blocks until the lock is free. Returns `None` — meaning "build anyway,
    /// unserialized" — if the lock can't be created or the wait times out;
    /// a slow build must never permanently block one.
    fn acquire(path: &Path) -> Option<Self> {
        if let Some(parent) = path.parent() {
            let _ = fs::create_dir_all(parent);
        }

        let mut waited = Duration::ZERO;
        loop {
            match fs::OpenOptions::new()
                .create_new(true)
                .write(true)
                .open(path)
            {
                Ok(mut file) => {
                    // Stamp ownership so that a holder whose lock was reclaimed
                    // cannot go on refreshing, or ultimately delete, the lock
                    // that now belongs to someone else.
                    let token = format!(
                        "{}-{}",
                        std::process::id(),
                        SystemTime::now()
                            .duration_since(SystemTime::UNIX_EPOCH)
                            .map(|since| since.as_nanos())
                            .unwrap_or_default()
                    );
                    let _ = file.write_all(token.as_bytes());
                    return Some(Self::holding(path, token));
                }
                Err(err) if err.kind() == io::ErrorKind::AlreadyExists => {}
                // Read-only or otherwise unusable location: don't fail the build.
                Err(_) => return None,
            }

            let idle_for = path
                .metadata()
                .and_then(|meta| meta.modified())
                .ok()
                .and_then(|touched_at| SystemTime::now().duration_since(touched_at).ok());
            if idle_for.is_some_and(|idle| idle > Self::STALE_AFTER) {
                warn(&format!(
                    "reclaiming the Flutter build lock {} — no heartbeat for over {}s, so the \
                     process holding it is gone.",
                    path.display(),
                    Self::STALE_AFTER.as_secs()
                ));
                let _ = fs::remove_file(path);
                continue;
            }

            // Say so on the first pass: an unexplained multi-minute pause in
            // cargo is indistinguishable from a wedged build.
            if waited.is_zero() {
                warn(&format!(
                    "waiting for another Flutter build to finish (lock: {}). Delete that file if \
                     no build is running.",
                    path.display()
                ));
            }

            if waited >= Self::MAX_WAIT {
                warn("gave up waiting for the Flutter build lock; building unserialized.");
                return None;
            }
            thread::sleep(Self::TICK);
            waited += Self::TICK;
        }
    }

    /// Starts the heartbeat that keeps this lock looking alive to waiters.
    fn holding(path: &Path, token: String) -> Self {
        let stop = Arc::new(AtomicBool::new(false));
        let beat_path = path.to_path_buf();
        let beat_stop = Arc::clone(&stop);
        let beat_token = token.clone();

        // Ticks far more often than HEARTBEAT so `Drop` can join promptly
        // instead of blocking the build for up to a full heartbeat.
        let heartbeat = thread::spawn(move || {
            let mut since_touch = Duration::ZERO;
            while !beat_stop.load(Ordering::Relaxed) {
                thread::sleep(Self::TICK);
                since_touch += Self::TICK;
                if since_touch < Self::HEARTBEAT {
                    continue;
                }
                since_touch = Duration::ZERO;

                // Stop the moment the lock is no longer ours: refreshing it
                // would keep another process's lock alive on its behalf.
                if !Self::owns(&beat_path, &beat_token) {
                    break;
                }
                if let Ok(file) = fs::OpenOptions::new().write(true).open(&beat_path) {
                    let _ = file.set_modified(SystemTime::now());
                }
            }
        });

        Self {
            path: path.to_path_buf(),
            token,
            stop,
            heartbeat: Some(heartbeat),
        }
    }

    /// Whether the lock file still carries this holder's token — false once it
    /// has been reclaimed and recreated by someone else.
    fn owns(path: &Path, token: &str) -> bool {
        fs::read_to_string(path).is_ok_and(|content| content == token)
    }
}

impl Drop for BuildLock {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Relaxed);
        if let Some(heartbeat) = self.heartbeat.take() {
            let _ = heartbeat.join();
        }
        // Only ever remove our own lock; after a reclaim this file belongs to
        // whichever build took it over.
        if Self::owns(&self.path, &self.token) {
            let _ = fs::remove_file(&self.path);
        }
    }
}

/// Watches `path` recursively, tracking the newest mtime seen in `newest`.
///
/// Symlinks are followed so that a directory linked into the client sources is
/// still covered; `depth` is what stops a symlink cycle from recursing forever.
fn watch(path: &Path, newest: &mut Option<SystemTime>, depth: u32) {
    // Follows symlinks, unlike symlink_metadata: the target's mtime is what
    // says whether a source changed, and a broken link simply drops out here.
    let Ok(metadata) = path.metadata() else {
        return;
    };

    println!("cargo:rerun-if-changed={}", path.display());

    if let Ok(modified) = metadata.modified()
        && newest.is_none_or(|current| modified > current)
    {
        *newest = Some(modified);
    }

    if !metadata.is_dir() || depth == 0 {
        return;
    }

    let Ok(entries) = path.read_dir() else {
        return;
    };
    for entry in entries.flatten() {
        watch(&entry.path(), newest, depth - 1);
    }
}

/// The Flutter launcher to spawn, or `None` when the SDK isn't on `PATH`.
///
/// The resolved name is returned rather than a bool because Windows ships
/// `flutter.bat`: `Command::new("flutter")` resolves only `flutter.exe` there
/// and would fail to spawn an SDK this function had just reported as present.
fn flutter_command() -> Option<&'static str> {
    let candidates: &[&str] = if cfg!(windows) {
        &["flutter.bat", "flutter.exe"]
    } else {
        &["flutter"]
    };

    candidates.iter().copied().find(|name| which(name))
}

/// Minimal PATH lookup — avoids pulling a build dependency in just for this.
fn which(name: &str) -> bool {
    let Some(path) = std::env::var_os("PATH") else {
        return false;
    };
    std::env::split_paths(&path).any(|dir| is_executable(&dir.join(name)))
}

/// A file that can actually be spawned. The mode check matters on Unix: a
/// non-executable file named `flutter` on `PATH` would otherwise be reported as
/// an SDK and then panic the build when it fails to spawn.
#[cfg(unix)]
fn is_executable(path: &Path) -> bool {
    use std::os::unix::fs::PermissionsExt;

    path.metadata()
        .is_ok_and(|meta| meta.is_file() && meta.permissions().mode() & 0o111 != 0)
}

#[cfg(not(unix))]
fn is_executable(path: &Path) -> bool {
    path.is_file()
}

fn warn(message: &str) {
    println!("cargo:warning={message}");
}
