use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::SystemTime;

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

    if std::env::var_os("TRIAGE_SKIP_FLUTTER_BUILD").is_some_and(|v| v != "0") {
        return;
    }

    let bundle_built_at = dev_client_path
        .metadata()
        .and_then(|meta| meta.modified())
        .ok();
    if bundle_built_at.is_some_and(|built_at| built_at >= newest_source) {
        return;
    }

    if !flutter_available() {
        warn(
            "Flutter client sources changed but the `flutter` command was not found; \
             leaving the existing web bundle in place.",
        );
        return;
    }

    let reason = if bundle_built_at.is_some() {
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
    let status = Command::new("flutter")
        .args(["build", "web", "--release"])
        .current_dir(client_dir)
        .status();

    match status {
        Ok(status) if status.success() => {}
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

/// Emit `rerun-if-changed` for `path` (recursing into directories) and fold its
/// mtime into `newest`.
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
        let child = entry.path();
        // Dart tooling drops caches inside the source tree; watching them would
        // cause spurious rebuilds.
        if matches!(
            child.file_name().and_then(|n| n.to_str()),
            Some(".dart_tool")
        ) {
            continue;
        }
        watch(&child, newest);
    }
}

fn flutter_available() -> bool {
    let candidates: &[&str] = if cfg!(windows) {
        &["flutter.bat", "flutter"]
    } else {
        &["flutter"]
    };

    candidates.iter().copied().any(which)
}

/// Minimal PATH lookup — avoids pulling a build dependency in just for this.
fn which(name: &str) -> bool {
    let Some(path) = std::env::var_os("PATH") else {
        return false;
    };
    std::env::split_paths(&path).any(|dir| {
        let candidate: PathBuf = dir.join(name);
        candidate.is_file()
    })
}

fn warn(message: &str) {
    println!("cargo:warning={message}");
}
