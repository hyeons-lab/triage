# Plan: Mobile Viewport Meta Tag and Responsive Mobile Layout

## Thinking

When accessing the Triage web client from mobile browsers (iOS Safari, Android Chrome), the application does not fit into the device viewport correctly. It renders scaled down and virtual terminals wrap text across lines formatted for desktop widths (~110-120 columns) rather than the physical mobile screen width (~45-50 columns). Furthermore, the workspace header overflows on narrow mobile screens (360-390px) because fixed horizontal padding and trailing controls crowd out the session title.

### Root Cause Analysis

1. **Missing Viewport Meta Tag in `web/index.html`**:
   The HTML template contains no `<meta name="viewport" ...>` tag. According to mobile browser standards, when this tag is absent, mobile browsers emulate a 980px desktop viewport. Consequently:
   - `window.innerWidth` and Flutter's `MediaQuery.of(context).size.width` report 980px instead of 390px.
   - The browser zooms out by ~0.4x to fit 980px onto the screen.
   - `FitAddon` measures a 948px wrapper and sizes the terminal to ~110-120 columns. When the PTY formats output for 120 columns, the text either wraps awkwardly or overflows.

2. **Platform & Layout Sizing Gating in `lib/main.dart`**:
   `isMobilePlatform()` only checks `defaultTargetPlatform == TargetPlatform.iOS || defaultTargetPlatform == TargetPlatform.android`. On web browsers that report desktop tokens or iPadOS desktop mode, this evaluates to false. Squeezing the desktop side-by-side layout (`Row([rail, VerticalDivider, workspace])`) onto narrow screens puts a 260px rail beside the terminal, leaving almost no room. Sizing should be responsive: if `isMobilePlatform() || MediaQuery.of(context).size.width < 768`, the collapsible overlay rail should be used.
   In addition, `isWebMobileBrowser()` should be introduced across `platform_env_io.dart` and `platform_env_web.dart` so mobile browsers and touch devices are recognized as mobile platforms.

3. **`WorkspaceHeader` Horizontal Crowding**:
   `WorkspaceHeader` in `lib/main.dart` has 22px horizontal padding and trailing items totaling ~224px. On narrow screens (360-390px), this crowds `Expanded(title)` down to negligible width or causes RenderFlex overflow. On mobile or narrow widths, horizontal padding should be reduced to 12px, the status text should be omitted in favor of the status dot icon, and icon button padding should be compact.

4. **Terminal Wrapper Margins on Mobile**:
   `_terminalWrapper` in `terminal_pane_web.dart` uses 16px left/right margins (32px total). On mobile screens, using 8px margins (16px total) gives 2-3 additional columns to the terminal.

## Plan

1. **Web Viewport Configuration**:
   Update `flutter/triage_client/web/index.html` to include:
   `<meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no, viewport-fit=cover">`.

2. **Mobile Web & Responsive Layout Detection**:
   - Add `bool isWebMobileBrowser()` to `flutter/triage_client/lib/platform_env_io.dart` (returning `false`) and `flutter/triage_client/lib/platform_env_web.dart` (checking navigator user-agent, touch points, and coarse pointer).
   - In `flutter/triage_client/lib/main.dart`, update `isMobilePlatform()` to also return true when `isWebMobileBrowser()` is true.
   - In `flutter/triage_client/lib/main.dart` `SessionWorkspace` layout, check `final isNarrow = !runningUnderFlutterTest() && MediaQuery.of(context).size.width < 768;` and `final isMobile = isMobilePlatform() || isNarrow;`.

3. **Responsive `WorkspaceHeader`**:
   In `flutter/triage_client/lib/main.dart` `WorkspaceHeader`:
   - Detect narrow screens via `final isNarrow = MediaQuery.of(context).size.width < 600;`.
   - Adjust horizontal padding to `isNarrow ? 12 : 22`.
   - Compact icon button padding, visual density, and icon sizes on narrow screens.
   - Hide `Text(session.status)` on narrow screens, relying on the status dot wrapped in a Tooltip.
   - Scale down title font size to 15 (from 18) and subtitle to 11 (from 14) on narrow screens to prevent truncation.

4. **Terminal Margin Optimization**:
   In `flutter/triage_client/lib/widgets/terminal_pane_web.dart`, use 8px horizontal margins on mobile devices (`_isMobile ? 8 : 16`) to maximize character columns.

5. **Validation and Verification**:
   - Format Dart code with `dart format`.
   - Run `flutter analyze` and `flutter test`.
   - Run `cargo fmt --all -- --check`.
   - Verify zero em dashes across git diff.
   - Rebuild Flutter web client (`flutter build web --release`).
   - Rebuild daemon (`cargo build -p triaged --release`), re-sign, and reload (`triaged reload`).
