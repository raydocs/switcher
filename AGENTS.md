# Switcher: agent notes

Native macOS (14+) menu bar app and CLI that switches the official sign-ins of Claude Desktop and
Antigravity, and shows each Antigravity account's quota. SwiftPM, Swift 6 toolchain in language mode 5, no third-party dependencies.

## Layout
- `Sources/SwitcherCore`: everything that touches disk, processes or the keychain.
  - `SignInVault.swift`: journaled, all-or-nothing swap of one app's sign-in; `recover()` after a crash.
  - `Providers.swift`: what each app's sign-in is (`claudeLayout`, `antigravityLayout`) and the switch flow.
  - `Switchboard.swift`: the facade the app and CLI use.
  - `CLIProfiles.swift`: Claude Code / Codex / Antigravity CLI (`agy`) profile folders, the pointer, shared-item symlinks, `CLIEnv`, the keychain service name, and `agy`'s keyring-unavailable marker.
  - `CLIShim.swift`: the PATH shim scripts and the `~/.zshrc` block (`switcher cli install` / `uninstall`).
  - `CLIAccounts.swift`: who each profile is signed in as, credential fingerprints, the read-only keychain reader and `doctor`.
  - `CLIQuota.swift`: Claude Code quota (statusline file, usage endpoint, `renewLogin`), Codex quota (`codex app-server`), and Antigravity CLI quota (`AgyCLIQuota`, Google Cloud Code).
  - `CLIUsage.swift`: headroom, pace, `scopeParts`, activity detection, backoff and `switcher.usage.v1`.
  - `CLICommands.swift`: `switcher cli` argument parsing, `exec` environment edits and the profile list.
- `Sources/SwitcherApp`: SwiftUI app. `AppModel` is the only thing that calls the core; views never do.
- `Sources/switcher`: CLI.
- `scripts/bundle.sh`: builds `dist/Switcher.app` (with `switcher` signed under `Contents/MacOS/switcher`).

## Rules
- Tests run only on temp dirs (`Sandbox` in `Tests/SwitcherCoreTests/SwitchTests.swift`) with `FakeApp`
  and `MemorySecrets`. Never `Env.live`, the real keychain or real app processes from a test.
- Never run a real switch, import or sync against the owner's data without their explicit go.
- Sign-ins move (rename), never copy: a saved copy is put back at most once.
- Claude's sign-in format must stay compatible with cc-same's `logins/<uuid>` folders.
- Antigravity sign-in = keychain `gemini`/`antigravity` (go-keyring) + `app_storage.json` onboarding keys
  (`agy.onboarding.*` since 2.3x, `jetski.onboarding.*` before) + the 2.30 token file
  `~/.gemini/jetski-standalone-oauth-token`. Verified by live switches on 2.31; re-check after updates.
- CLI accounts never move credentials: switching only rewrites the pointer file.
- CLI paths are Strings end to end, never URL round trips. Claude Code's keychain name is sha256 of the
  raw `CLAUDE_CONFIG_DIR` string, so a symlink or trailing slash changes it; the default account leaves
  the variable unset. Verified on claude 2.1.323 with a fake `security`.
- Named `agy` profiles (`~/.agy-profiles/<name>`) keep their OAuth token in `<profile>/antigravity-cli/antigravity-oauth-token` by refreshing `<profile>/antigravity-cli/cache/antigravity-keyring-unavailable`, leaving the login keychain's `gemini`/`antigravity` item untouched.
- Never touch shims, rc files or the pointer on the real HOME from a test, or without the owner's go.
- `renewLogin` (a real `claude -p` run) only on an explicit request (`--renew`), never on its own.
- CLI tests use `CLIEnv(home: tmp, fallbackSearchDirs: [])` and `MemoryCLIKeychain`.
- Check: `swift test`. App: `scripts/bundle.sh && open dist/Switcher.app`.
