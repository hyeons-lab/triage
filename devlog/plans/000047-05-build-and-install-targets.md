## Thinking

We need to fulfill the user's request:
1. Build the flutter web client (`flutter build web` in `flutter/triage_client`)
2. Build the flutter macos client (`flutter build macos` in `flutter/triage_client`)
3. Build `triage` then `triaged` (Rust workspace member crates)
4. Install `triage` and `triaged` (using `cargo install --path ...`)
5. Copy the new macOS app (`Triage.app`) to `/Applications`.

Let's review the build process.
- For the Flutter web client, running `flutter build web` from `flutter/triage_client` will compile the web app to `flutter/triage_client/build/web`.
- Building `triage` then `triaged` Cargo crates:
  Since `triaged`'s `build.rs` checks for `../../flutter/triage_client/build/web/index.html` to set the `embed_real_client` cfg, compiling `triaged` after the web client build will automatically embed the real web client into the daemon binary!
  We should run:
  `cargo build --release -p triage`
  `cargo build --release -p triaged`
- Installing the cargo binaries:
  We can run:
  `cargo install --path crates/triage`
  `cargo install --path crates/triaged`
  This will install `triage` and `triaged` binaries to `$HOME/.cargo/bin/`.
- For the Flutter macOS client, `flutter build macos` will compile the native app to `flutter/triage_client/build/macos/Build/Products/Release/Triage.app`.
- We then copy `Triage.app` to `/Applications` via:
  `rm -rf /Applications/Triage.app`
  `cp -R flutter/triage_client/build/macos/Build/Products/Release/Triage.app /Applications/`

### Collapsed Sidebar Layout Bug Fix

**Thinking**:
When the side sessions rail (sidebar) collapses, the terminal pane expands and the viewport size grows. However, the client-side PTY resize notifications on native macOS (`terminal_pane_stub.dart`) were debounced by `260ms`, which was longer than the animation duration (`220ms`), and introduced a lengthy mismatch delay where PTY writes were laid out under the old constraints. On the web client, this debounce is `100ms`, which works extremely well.

We reduced the debounce duration in `terminal_pane_stub.dart` from `260ms` to `100ms`. We will now rebuild all the build targets to apply this layout fix.

**Plan Addition**:
1. **Rebuild Flutter Web Client**: `flutter build web` inside `flutter/triage_client`.
2. **Rebuild Flutter macOS Client**: `flutter build macos` inside `flutter/triage_client`.
3. **Recompile Rust Crates**: `cargo build --release -p triage && cargo build --release -p triaged`.
4. **Reinstall Rust Binaries**: `cargo install --path crates/triage && cargo install --path crates/triaged`.
5. **Redeploy macOS App**: Copy new `Triage.app` to `/Applications`.

Let's outline these steps explicitly in the Plan.

## Plan

1. **Build Flutter Web Client**:
   Run `flutter build web` inside `flutter/triage_client`.
2. **Build Flutter macOS Client**:
   Run `flutter build macos` inside `flutter/triage_client`.
3. **Build Rust Crates**:
   Build `triage` first, then `triaged` using release profile:
   `cargo build --release -p triage`
   `cargo build --release -p triaged`
4. **Install Rust Binaries**:
   Install `triage` and `triaged` to cargo bin:
   `cargo install --path crates/triage`
   `cargo install --path crates/triaged`
5. **Copy macOS App to Applications**:
   Remove any existing `/Applications/Triage.app` and copy the newly built app:
   `rm -rf /Applications/Triage.app`
   `cp -R flutter/triage_client/build/macos/Build/Products/Release/Triage.app /Applications/`
