# Changelog

## Unreleased

## 1.1.0 - 2026-08-15

- Switch to Hook-only operation with no login startup, global watcher, per-session monitor, or repeating waiting loop.
- Migrate existing installations by stopping owned background processes and removing owned `Run` entries and the legacy scheduled watcher.
- Keep final completion/failure verification and permission sounds through short-lived Hook processes, and document the reduced intermediate-event coverage.

## 1.0.3 - 2026-08-12

- Disable immediate sounds for recoverable tool-step failures by default while retaining final task failure sounds and the opt-in setting.
- Verify that a `Stop` Hook has a matching terminal rollout event before playing completion feedback, preventing intermediate Stop events from sounding like finished tasks.
- Suppress global completion feedback from explicitly marked subagent sessions.

## 1.0.2 - 2026-08-01

- Give permission and other action-required events an independent, more audible `waiting_volume` setting.
- Support an optional `action-custom.mp3` while retaining the generated WAV fallback.
- Make the documented `--version` command work in Windows PowerShell.
- Migrate verified pre-1.0 root-level Hooks and avoid recreating an existing Windows `Run` registry key.
- Read Hook payloads as raw UTF-8 so redirected permission requests are not corrupted by console encoding changes.

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
