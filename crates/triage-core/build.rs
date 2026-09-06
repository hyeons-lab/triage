use std::path::PathBuf;
use std::process::Command;

fn main() {
    println!("cargo:rerun-if-changed=schema/triage.fbs");
    println!("cargo:rerun-if-changed=../../Cargo.toml");

    // 1. Locate flatc compiler
    let flatc_path = find_flatc();

    let Some(flatc) = flatc_path else {
        panic!(
            "Error: FlatBuffers schema compiler 'flatc' is required to compile triage-core.\n\
             Please install flatc globally (e.g. via 'winget install Google.flatbuffers', \n\
             'brew install flatbuffers', or download from github.com/google/flatbuffers)."
        );
    };

    // 2. Reject a generator that cannot produce code this runtime can compile
    check_flatc_generation(&flatc);

    // Ensure output directory exists
    let out_dir = PathBuf::from(std::env::var("OUT_DIR").unwrap());

    // 3. Compile flatbuffers schema
    let status = Command::new(&flatc)
        .arg("--rust")
        .arg("-o")
        .arg(&out_dir)
        .arg("schema/triage.fbs")
        .status();

    match status {
        Ok(s) if s.success() => {}
        Ok(s) => {
            panic!("flatc failed with exit code: {:?}", s.code());
        }
        Err(e) => {
            panic!("failed to execute flatc at {:?}: {}", flatc, e);
        }
    }
}

fn find_flatc() -> Option<PathBuf> {
    // 1. Check if flatc is on the PATH
    if let Some(paths) = std::env::var_os("PATH") {
        for path in std::env::split_paths(&paths) {
            let exe = if cfg!(target_os = "windows") {
                path.join("flatc.exe")
            } else {
                path.join("flatc")
            };
            if exe.is_file() {
                return Some(exe);
            }
        }
    }

    // 2. Windows-specific winget package fallback
    if cfg!(target_os = "windows") {
        let local_appdata = std::env::var_os("LOCALAPPDATA")?;
        let fallback = PathBuf::from(local_appdata)
            .join("Microsoft")
            .join("WinGet")
            .join("Packages")
            .join("Google.flatbuffers_Microsoft.Winget.Source_8wekyb3d8bbwe")
            .join("flatc.exe");
        if fallback.exists() {
            return Some(fallback);
        }
    }

    None
}

/// Fails the build when `flatc` is older than the `flatbuffers` runtime crate.
///
/// FlatBuffers versions its generator and its runtime together, and generated
/// Rust calls into runtime APIs of its own generation. A `flatc` from a
/// different generation still exits successfully and writes a file, so the
/// mismatch surfaces a step later as a hundred or so rustc type errors inside
/// generated code that nothing points back at `flatc`. Distributions make this
/// easy to hit: `apt install flatbuffers-compiler` on Ubuntu still ships 2.0.x
/// against a runtime pinned here in the twenties.
fn check_flatc_generation(flatc: &std::path::Path) {
    let Some(found) = flatc_major(flatc) else {
        // Never block on an unreadable version. A generator that does not
        // answer `--version` may still be fine, and the compile speaks next.
        println!(
            "cargo:warning=could not read the version of flatc at {flatc:?}; skipping the compatibility check"
        );
        return;
    };
    let Some(required) = pinned_flatbuffers_major() else {
        println!(
            "cargo:warning=could not read the flatbuffers pin from the workspace manifest; skipping the flatc compatibility check"
        );
        return;
    };

    if found < required {
        panic!(
            "Error: flatc {found}.x is too old for the flatbuffers {required}.x runtime this \n\
             workspace pins, and its generated Rust will not compile.\n\
             \n\
             Found: {flatc:?} (major version {found})\n\
             Needs: flatc {required}.x\n\
             \n\
             Install a matching flatc ('brew install flatbuffers', \n\
             'winget install Google.flatbuffers', or a release from \n\
             github.com/google/flatbuffers). Distribution packages are often \n\
             several generations behind."
        );
    }
    if found > required {
        println!(
            "cargo:warning=flatc {found}.x is newer than the pinned flatbuffers {required}.x runtime; if generated code fails to compile, align the two"
        );
    }
}

/// Reads the major version from `flatc --version`, whose output is shaped like
/// `flatc version 25.12.19`.
fn flatc_major(flatc: &std::path::Path) -> Option<u64> {
    let output = Command::new(flatc).arg("--version").output().ok()?;
    if !output.status.success() {
        return None;
    }
    let text = String::from_utf8_lossy(&output.stdout);
    text.split_whitespace()
        .find_map(|token| token.split('.').next()?.parse::<u64>().ok())
}

/// Reads the `flatbuffers` major version pinned in the workspace manifest, so
/// this check tracks the pin instead of drifting from it.
fn pinned_flatbuffers_major() -> Option<u64> {
    let manifest = PathBuf::from(std::env::var_os("CARGO_MANIFEST_DIR")?)
        .parent()?
        .parent()?
        .join("Cargo.toml");
    let text = std::fs::read_to_string(manifest).ok()?;
    let line = text
        .lines()
        .map(str::trim)
        .find(|line| line.starts_with("flatbuffers"))?;
    let version = line.split('"').nth(1)?;
    version.split('.').next()?.parse::<u64>().ok()
}
