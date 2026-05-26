use std::path::PathBuf;
use std::process::Command;

fn main() {
    println!("cargo:rerun-if-changed=schema/triage.fbs");

    // 1. Locate flatc compiler
    let flatc_path = find_flatc();

    let Some(flatc) = flatc_path else {
        panic!(
            "Error: FlatBuffers schema compiler 'flatc' is required to compile triage-core.\n\
             Please install flatc globally (e.g. via 'winget install Google.flatbuffers', \n\
             'brew install flatbuffers', or download from github.com/google/flatbuffers)."
        );
    };

    // Ensure output directory exists
    let out_dir = PathBuf::from("src/generated");
    if !out_dir.exists() {
        std::fs::create_dir_all(&out_dir).unwrap();
    }

    // 2. Compile flatbuffers schema
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
