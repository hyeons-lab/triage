## Thinking

The Phase 2 error path currently reconnects to the shared IPC path and treats
any accepting listener as the daemon that transferred the session descriptors.
If launchd kills that daemon and immediately respawns another one, the new
daemon can bind the same path first. Refusing then closes the only transferred
PTY master descriptors, while the respawned daemon never received them.

Capture the filesystem socket identity after the successful Phase 1 transfer.
On a Phase 2 write failure or Phase 3 EOF, compare the path's current identity
with the captured one before treating a listener as the original peer. A
different identity is a replacement daemon, so adopt the transferred sessions.
Keep the existing conservative behavior when an identity was not captured.

## Plan

1. Store the Phase 1 peer socket device and inode alongside the handover stream.
2. Require a matching identity as well as a successful connection before
   classifying a peer as alive.
3. Add a regression test covering a listener replaced at the same path.
4. Format, run the affected tests and full local CI gates, then run the max
   review-fix loop and record the result in the branch devlog.
