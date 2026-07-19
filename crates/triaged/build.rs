use std::fs;
use std::io;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::thread;
use std::time::{Duration, SystemTime};

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
        watch(&path, &mut newest_source);
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
/// Released on drop, including when the build panics, so a failed build does
/// not wedge every later one.
struct BuildLock(PathBuf);

impl BuildLock {
    /// Blocks until the lock is free. Returns `None` — meaning "build anyway,
    /// unserialized" — if the lock can't be created or the wait times out;
    /// a slow build must never permanently block one.
    fn acquire(path: &Path) -> Option<Self> {
        const POLL: Duration = Duration::from_millis(250);
        const MAX_WAIT: Duration = Duration::from_secs(15 * 60);
        // Longer than any plausible build, so only a crashed one is reaped.
        const STALE_AFTER: Duration = Duration::from_secs(30 * 60);

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
                Ok(_) => return Some(Self(path.to_path_buf())),
                Err(err) if err.kind() == io::ErrorKind::AlreadyExists => {}
                // Read-only or otherwise unusable location: don't fail the build.
                Err(_) => return None,
            }

            let held_for = path
                .metadata()
                .and_then(|meta| meta.modified())
                .ok()
                .and_then(|held_since| SystemTime::now().duration_since(held_since).ok());
            if held_for.is_some_and(|age| age > STALE_AFTER) {
                let _ = fs::remove_file(path);
                continue;
            }

            if waited >= MAX_WAIT {
                return None;
            }
            thread::sleep(POLL);
            waited += POLL;
        }
    }
}

impl Drop for BuildLock {
    fn drop(&mut self) {
        let _ = fs::remove_file(&self.0);
    }
}

/// Watches `path` recursively, tracking the newest mtime seen in `newest`.
///
/// Directories are walked rather than watched wholesale so that cargo re-runs
/// this script for an edit to any individual client source.
fn watch(path: &Path, newest: &mut Option<SystemTime>) {
    let Ok(metadata) = path.symlink_metadata() else {
        return;
    };

    println!("cargo:rerun-if-changed={}", path.display());

    if let Ok(modified) = metadata.modified()
        && newest.is_none_or(|current| modified > current)
    {
        *newest = Some(modified);
    }

    if !metadata.is_dir() {
        return;
    }

    let Ok(entries) = path.read_dir() else {
        return;
    };
    for entry in entries.flatten() {
        watch(&entry.path(), newest);
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
