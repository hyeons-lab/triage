# Plan: Nonblocking PTY Input & Bracketed Paste Support

## Thinking

1. **Root Cause Analysis:**
   - When large text (such as 4.7KB `results.txt`) is pasted into a session via the Triage web client:
     - `_containerPasteListener` in `terminal_pane_web.dart` intercepted the browser `paste` event, extracted plain text, and directly invoked `_sendInput(text)`. This completely bypassed `xterm.js`'s built-in `terminal.paste(text)` logic.
     - As a result, bracketed paste sequences (`\x1b[200~` and `\x1b[201~`) were NOT emitted, and multi-line text was sent as raw newlines. When pasted into an interactive CLI (`agy` / zsh), every newline acted as an immediate command submission.
     - When the 4,735 bytes reached `triaged`, `triaged::ws::handle_upgraded_ws` processed `ClientRequest::WriteInput` by calling `SessionManager::write_input(request)`.
     - `SessionManager::write_input` called `request_write_input`, which dispatched `ActorCommand::WriteInput { bytes, response }` to the session actor worker thread and performed a synchronous blocking `recv()` on `resp_rx`.
     - The session actor worker thread called `self.write_input(&bytes)`, which executed `writer.write_all(bytes)` on the master PTY descriptor.
     - On macOS, the kernel PTY buffer is typically 1,024–2,048 bytes. When writing 4,735 bytes to a blocking master PTY descriptor where the child process was not immediately draining stdin, `write()` blocked indefinitely in the kernel.
     - Because `writer.write_all()` blocked in the actor worker thread:
       - The actor worker thread could not process any further actor commands (`SummaryRows`, `Snapshot`, `Resize`, `ExtractHandover`).
       - `request_write_input` blocked the Tokio async task running `handle_upgraded_ws`, freezing the entire WebSocket connection (for all sessions).
       - The summarizer debounce thread blocked on `SessionManager::summary_rows(session_id)`.
       - The daemon and client became completely wedged.

2. **Resolution Architecture:**
   - **Backend (`triaged::session`):**
     - Decouple PTY input writing from the actor worker thread by using a dedicated `session-actor-writer` thread (or dedicated input worker). The actor worker (and `SessionManager::write_input`) will enqueue bytes to an input channel without blocking on the kernel PTY write.
     - Make `request_write_input` fire-and-forget: it dispatches the input command to the session and returns `Ok(())` immediately. A stuck or slow child process will never block the Tokio WebSocket handler task or the global session lock.
     - Ensure the writer thread gracefully drains and exits when the session shuts down or when the channel disconnects.
   - **Frontend (`flutter/triage_client/lib/widgets/terminal_pane_web.dart`):**
     - In `_bindContainerEvents` / `pasteListener`, route text through `_term.paste(text)` when the terminal is initialized. `xterm.js`'s `paste()` method automatically honors Mode 2004 (bracketed paste) if requested by the running shell/agent, formats the input safely, normalizes CRLF line endings, and invokes `onData`. Fall back to `_sendInput(text)` only if `_term` is uninitialized.

## Plan

1. Create a dedicated branch worktree `worktrees/fix-nonblocking-pty-input` on `fix/nonblocking-pty-input`.
2. Update `crates/triaged/src/session.rs`:
   - Implement `session-actor-writer` thread for live PTY writer handling so `write_all` runs on its own thread.
   - Make `request_write_input` fire-and-forget (non-blocking).
   - Update tests for `write_input` to verify non-blocking delivery and large payload writes without hanging.
3. Update `flutter/triage_client/lib/widgets/terminal_pane_web.dart`:
   - Use `js_util.callMethod(_term, 'paste', [text])` on web paste events to ensure bracketed paste sequences and line endings are preserved.
4. Verify:
   - Run `cargo fmt --all -- --check`
   - Run `cargo clippy --all-targets --all-features -- -D warnings`
   - Run `cargo test --workspace`
   - Run `flutter test` in `flutter/triage_client`
5. Check in devlog and commit with conventional commit message.
