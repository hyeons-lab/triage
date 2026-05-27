# Plan — Address E2E Stress Client Panic Comments

## Thinking
We need to address the latest PR review comments targeting the E2E stress testing tool (`stress_client.rs`) to ensure robustness, prevent panics, and handle malformed IDs or pacing configurations safely.

1. **Tokio Pacing Interval Clamping**:
   - The current interval tick duration calculation is `1_000_000_000 / rate`. If `rate` is set very high (exceeding 1 billion), the division resolves to 0. Tokio's `interval` function panics immediately if the duration is zero.
   - We will clamp the duration to a minimum of 1 nanosecond using `.max(1)`.
   - We will verify that if `rate == 0`, we error out early with a clean error message (this is already in place, but we will keep it robust).

2. **Session and Client ID Parsing Safety**:
   - The stress client currently uses `.unwrap()` when constructing `ClientId` or `SessionId` (e.g., lines 153, 216, 254, 311). If malformed or unexpected data is encountered, this can crash the stress tool.
   - We will replace these `.unwrap()` calls with proper anyhow context propagation (`?` or `.context(...)?`).

3. **Validation and Lint Verification**:
   - We will run `cargo clippy --all-targets --all-features -- -D warnings` and `cargo test --workspace` to ensure zero-warning compilation and that all tests pass.

## Plan
- [ ] Modify `crates/triage-transport-ws/src/bin/stress_client.rs` to clamp the pacing interval duration calculation to at least 1 nanosecond.
- [ ] Eliminate all unsafe `.unwrap()` calls during `ClientId` and `SessionId` parsing inside `stress_client.rs`, propagating errors cleanly using `?` or `anyhow` contexts.
- [ ] Verify clean compilation with `cargo check --workspace`.
- [ ] Run formatting check with `cargo fmt --all -- --check`.
- [ ] Run lints with `cargo clippy --all-targets --all-features -- -D warnings`.
- [ ] Run all workspace tests with `cargo test --workspace`.
