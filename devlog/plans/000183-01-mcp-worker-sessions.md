# MCP Worker Sessions

## Thinking

The daemon already starts and shuts down sessions, exports TRIAGE_SESSION_ID to children, and recognizes multiple agent runtimes. MCP exposes observation and coordination mail but omits the lifecycle operations. A thin wrapper closes that gap without adding an agent scheduler or duplicating daemon session logic.

The new tools must validate their arguments before invoking the daemon, preserve argv boundaries, require an absolute working directory, and return failures using the existing MCP protocol/tool error distinction. Launching a process is non-idempotent; an ambiguous transport failure must not trigger a blind retry. Shutdown is destructive, and coordinators must use the exact session IDs they created.

The work is stacked on PR #213, which is itself stacked on PR #212. Scope the review to this branch's own changes. Do not install binaries, reload the running daemon, or launch actual agent conversations as part of validation.

## Plan

1. Add start_session and shutdown_session MCP definitions and dispatch. Accept command, optional args, required absolute cwd, and optional bounded rows/cols. Return the session ID or completed-session result through structured content.
2. Reject blank commands, embedded NULs, invalid cwd, malformed argv, unsupported fields, and invalid terminal sizes before any session API call. Forward argv directly, without shell interpolation.
3. Extend the recording API tests for forwarding, four runtime executable names, omitted options, validation without side effects, backend failures, structured results, and mutation annotations. Exercise a real session lifecycle against an isolated test daemon if the existing test harness supports it.
4. Update the MCP README and checked-in coordination skill with launch, exact-ID ownership, shutdown, wake/wait, and non-durable mailbox behavior.
5. Run version consistency, formatting, strict workspace clippy, rustdoc with warnings denied, and workspace tests using CI's Flutter-build opt-out. Run other applicable CI gates and record platform or environment limitations explicitly.
6. Run the local max-effort review loop, fix actionable findings, and confirm clean. Update the devlog before committing.
7. Commit and push the feature branch using an explicit destination refspec. Open a stacked PR targeting feat/d1-approval-judge with a description matching the commit body.
