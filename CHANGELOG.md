# Changelog

## 1.0.1 - 2026-08-01

- Replace 250 ms recursive session scans with Windows file events and a five-second fallback check.
- Return nonzero exit codes for fatal manual/runtime errors and verify sound generation plus watcher startup during installation.
- Rotate local logs at 2 MB with three retained archives.
- Isolate watcher, state, and startup identities by `CODEX_HOME`.
- Make Hook updates atomic with unique backups and refuse unsafe reparse-point removal.
- Scope Hook ownership to the exact installation, migrate legacy commands, and use hidden encoded commands that are safe for special-character paths.
- Validate Hook and configuration structures before mutation; stage and verify runtime files plus sounds before atomic deployment.
- Dispatch Hook sounds asynchronously, ignore malformed Stop input, and restart the watcher after transient failures.
- Preserve split UTF-8 characters and later lines after a bad rollout record, handle truncation without replaying history, and deduplicate rollout lines across monitors.
- Reduce tool-failure false positives and prevent an old waiting loop or duplicated rollout event from clearing a newer turn.
- Make repeated uninstall a no-op for clean Hooks and complete all path/reparse-point checks before destructive changes.
- Align fallback settings with the documented non-repeating default.
- Add isolated adversarial runtime tests, pinned CI dependencies, and least-privilege CI settings.

## 1.0.0 - 2026-07-31

- Add success, failure, and action-required sounds for Codex on Windows.
- Preserve Codex native desktop notifications; no custom Toast implementation.
- Add idempotent Hook merge, user-login startup, safe uninstall, and Windows CI smoke test.
- Generate default sounds locally and support optional custom success/error MP3 files.
