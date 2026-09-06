# 000140: Mobile Viewport Meta Tag and Responsive Mobile Layout

## Agent

Gemini 3.8 Flash (High) @ triage branch fix/mobile-viewport-layout

## Intent

Configure the mobile viewport meta tag in the web client and make the application layout and workspace header responsive on mobile devices and narrow screens so terminal sessions fit physical device dimensions without awkward wrapping or RenderFlex overflows.

## What Changed

- **2026-09-06T09:44-0700** devlog/plans/000140-01-mobile-viewport-layout.md: Authored implementation plan covering viewport meta tag configuration, responsive rail drawer activation, workspace header compaction, and terminal margins.
- **2026-09-06T09:54-0700** flutter/triage_client/web/index.html: Added mobile viewport meta tag with device-width, initial and maximum scale 1.0, user-scalable no, and viewport-fit cover.
- **2026-09-06T09:54-0700** flutter/triage_client/lib/platform_env_io.dart, flutter/triage_client/lib/platform_env_web.dart: Added isWebMobileBrowser helper detecting mobile browsers and touch devices on web, stubbed to false on native.
- **2026-09-06T09:54-0700** flutter/triage_client/lib/main.dart: Wired isWebMobileBrowser into isMobilePlatform. Made SessionWorkspace rail layout responsive when screen width is under 768px outside test harnesses. Wrapped WorkspaceHeader in LayoutBuilder to adapt padding, icon sizes, action button density, and status display when width is under 600px.
- **2026-09-06T09:54-0700** flutter/triage_client/lib/widgets/terminal_pane_web.dart: Reduced terminal wrapper margins from 16px to 8px on mobile devices and narrow viewports.
- **2026-09-06T09:54-0700** flutter/triage_client/test/session_rail_identity_test.dart, flutter/triage_client/test/session_rail_layout_test.dart: Added tests verifying responsive WorkspaceHeader layout on narrow mobile vs desktop viewports, and platform mobile detection.

## Decisions

- **2026-09-06T09:44-0700 Decision: Mobile Viewport Meta Tag**: Add `<meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no, viewport-fit=cover">` to `web/index.html`. This tells mobile browsers to render at native device width rather than defaulting to the legacy 980px desktop virtual viewport.
- **2026-09-06T09:44-0700 Decision: Responsive Rail and Mobile Platform Detection**: Provide `isWebMobileBrowser()` in `platform_env_web.dart` to detect touch devices and mobile user agents, wire it into `isMobilePlatform()`, and activate the collapsible overlay rail when screen width is under 768px outside test harnesses.
- **2026-09-06T09:44-0700 Decision: Compact Workspace Header for Narrow Viewports**: On screens under 600px wide, reduce horizontal padding from 22px to 12px, use compact visual density on trailing action buttons, hide textual status in favor of the status dot with tooltip, and reduce header font sizes so the session title and branch remain legible without overflow.
- **2026-09-06T09:44-0700 Decision: 8px Mobile Terminal Margins**: Reduce terminal wrapper margins from 16px to 8px on mobile devices, reclaiming 16px of horizontal space for additional terminal character columns.

## Issues

- None.

## Progress

- [x] Create worktree and branch devlog / plan
- [x] Add viewport meta tag to `flutter/triage_client/web/index.html`
- [x] Add `isWebMobileBrowser()` to `platform_env_io.dart` and `platform_env_web.dart`
- [x] Update `isMobilePlatform()` and `SessionWorkspace` responsive layout in `lib/main.dart`
- [x] Update `WorkspaceHeader` responsive layout in `lib/main.dart`
- [x] Update terminal wrapper margin in `lib/widgets/terminal_pane_web.dart`
- [x] Format and run tests across Dart and Rust
- [x] Rebuild web client and reload daemon
- [x] Open PR

## Commits

- HEAD: fix(web): configure mobile viewport meta and responsive layout
