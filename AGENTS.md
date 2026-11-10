# Switcher: agent notes

Native macOS (14+) menu bar app and CLI that switches the official sign-ins of Claude Desktop and
Antigravity, and shows each Antigravity account's quota. SwiftPM, Swift 6 toolchain in language mode 5, no third-party dependencies.

## Layout
- `Sources/SwitcherCore`: everything that touches disk, processes or the keychain.
  - `SignInVault.swift`: journaled, all-or-nothing swap of one app's sign-in; `recover()` after a crash.
  - `Providers.swift`: what each app's sign-in is (`claudeLayout`, `antigravityLayout`) and the switch flow.
  - `Switchboard.swift`: the facade the app and CLI use.
- `Sources/SwitcherApp`: SwiftUI app. `AppModel` is the only thing that calls the core; views never do.
- `Sources/switcher`: CLI.
- `scripts/bundle.sh`: builds `dist/Switcher.app`.

## Rules
- Tests run only on temp dirs (`Sandbox` in `Tests/SwitcherCoreTests/SwitchTests.swift`) with `FakeApp`
  and `MemorySecrets`. Never `Env.live`, the real keychain or real app processes from a test.
- Never run a real switch, import or sync against the owner's data without their explicit go.
- Sign-ins move (rename), never copy: a saved copy is put back at most once.
- Claude's sign-in format must stay compatible with cc-same's `logins/<uuid>` folders.
- Antigravity sign-in = keychain `gemini`/`antigravity` (go-keyring) + `app_storage.json` onboarding keys
  (`agy.onboarding.*` since 2.3x, `jetski.onboarding.*` before) + the 2.30 token file
  `~/.gemini/jetski-standalone-oauth-token`. Verified by live switches on 2.31; re-check after updates.
- Check: `swift test`. App: `scripts/bundle.sh && open dist/Switcher.app`.
