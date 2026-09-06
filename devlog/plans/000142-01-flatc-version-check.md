# 000142-01: flatc generation check

## Thinking

`triage-core`'s build script locates `flatc` and runs it, but never checks which FlatBuffers
generation it belongs to. FlatBuffers versions its generator and runtime together and generated
Rust calls runtime APIs of its own generation, so a mismatched compiler still exits zero and writes
a file, and the failure appears one step later as a hundred or so rustc type errors inside a
generated file that nothing attributes to `flatc`.

This is easy to hit rather than theoretical: `apt install flatbuffers-compiler` on Ubuntu ships
2.0.x, while the workspace pins the runtime in the twenties.

The expected major could be a constant in the build script, but then it has to be updated in
lockstep with the workspace pin, and forgetting reintroduces the silent incompatibility. Reading
the pin from the workspace manifest keeps one source of truth.

The check should be a diagnostic, not a new way to fail a working build: an unreadable version or
manifest warns and proceeds, since the compile itself is the next check.

## Plan

1. Parse `flatc --version` for the major version.
2. Read the `flatbuffers` pin from the workspace manifest for the expected major.
3. Hard error when older, naming both versions and how to install a matching compiler; warn when
   newer; warn and skip when either version cannot be read.
4. Register the manifest with `rerun-if-changed` so a pin bump re-runs the check.
5. Verify all four paths against a stubbed `flatc`.
