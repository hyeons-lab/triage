## Thinking

The Windows and Linux Flutter clients were branded `triage_client` (window title +
Windows version metadata), unlike macOS which shows "Triage" (via `PRODUCT_NAME`).
We want them to display "Triage" too.

Constraint: the workspace already ships a `triage` TUI executable (the `triage`
crate) and a `triaged` daemon. The desktop client's executable must NOT be named
`triage`/`Triage`, or it would collide with the `triage` TUI on case-insensitive
filesystems (Windows, macOS).

Resolution (mirrors macOS, where `Triage.app`'s inner `Triage` binary is never on
PATH): change only the **display name** to "Triage" and keep the on-disk executable
as `triage_client`. So `BINARY_NAME`, `APPLICATION_ID`, and the Windows
`InternalName`/`OriginalFilename` (which must match the real `triage_client.exe`)
are left unchanged; only user-visible strings change.

## Plan

1. Windows: window title (`runner/main.cpp`) and `ProductName` + `FileDescription`
   (`runner/Runner.rc`) → "Triage". Keep `BINARY_NAME`/`InternalName`/`OriginalFilename`.
2. Linux: header-bar and window titles (`runner/my_application.cc`) → "Triage". Keep
   `BINARY_NAME`/`APPLICATION_ID`.
3. No README/workflow change: the artifacts still contain `triage_client(.exe)`, and
   the release zips/tars the whole build output regardless of binary name.
4. Commit devlog + plan + change, push, open PR.
