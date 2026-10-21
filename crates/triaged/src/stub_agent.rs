// Not a Rust module: `build.rs` compiles this file into a standalone test
// helper binary (`triage-stub-agent`) in OUT_DIR. Tests copy it under an
// agent's binary name (`claude`, `codex`, ...) so observation and restore
// tests run against a real kernel-visible process with controlled argv.
//
// It ignores argv entirely (agent resume flags included) and blocks quietly
// until killed, with a two-minute cap so a leaked test helper exits on
// its own instead of lingering.

use std::time::Duration;

fn main() {
    for _ in 0..120 {
        std::thread::sleep(Duration::from_secs(1));
    }
}
