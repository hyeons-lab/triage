# Client Cache Refresh

## Thinking

The stale-client symptom can come from two separate cache layers. The daemon caches web override assets in memory, so a freshly deployed client file can remain invisible until the daemon cache is manually reloaded. Older Flutter web builds can also leave behind a service worker and CacheStorage entries that keep serving stale app shell files even when normal browser refreshes ask the daemon again.

The fix should remove stale app-code cache state without deleting localStorage, because this branch intentionally uses localStorage as the browser-profile device boundary for pairing.

## Plan

1. Stop caching mutable override-directory assets in daemon memory while keeping embedded assets cached.
2. Add explicit browser cache cleanup headers for the app shell and bootstrap responses.
3. Serve `/flutter_service_worker.js` as a cleanup worker that removes stale CacheStorage entries and unregisters itself.
4. Add web bootstrap cleanup in `index.html` that unregisters service workers and clears CacheStorage without touching localStorage.
5. Validate the override-cache behavior, service-worker cleanup response, workspace check, formatting, whitespace, and Flutter widget tests.
