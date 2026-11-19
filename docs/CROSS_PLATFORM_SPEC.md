# Switcher Cross-Platform State & CLI Specification

This document freezes the on-disk state schemas, security invariants, and CLI JSON contracts shared between **Switcher for macOS** and future ports (including **Switcher for Windows**).

---

## 1. Core Security Invariants (All Platforms)

1. **Move, never copy (Desktop accounts):**
   - A saved desktop sign-in is moved atomically (rename) between the live app folder / OS credential store and Switcher's vault. It is put back at most once, so stale duplicate sessions are never left behind.
   - Swaps are journaled (`journal.json`) so a crash or power loss mid-swap cleanly rolls back or finishes on next launch (`recover()`).
2. **Never move or rename CLI folders:**
   - Claude Code names its OS credential entry using the first 8 hex digits of `SHA-256(raw CLAUDE_CONFIG_DIR string)`. Renaming a profile folder or canonicalizing symlinks/trailing slashes breaks sign-in discovery.
   - Switching CLI accounts ONLY rewrites a local pointer file (`claude.current` / `codex.current`). Running sessions are never interrupted.
   - The `default` CLI account ALWAYS leaves `CLAUDE_CONFIG_DIR` / `CODEX_HOME` **unset** (never set to `~/.claude` or `~/.codex`).
3. **Private file permissions & zero secret persistence in caches:**
   - All state/config files containing metadata, caches, or journals are written atomically (`0600` on POSIX; current-user ACL on Windows).
   - No cache (`quota-cache.json`, `antigravity-usage.json`, `alert-state.json`) or diagnostic report may ever contain OAuth access tokens, refresh tokens, or API keys.
4. **No unsolicited token refresh:**
   - Quota reads never run `claude -p` or rotate refresh tokens automatically (`renewLogin` only runs on explicit user action).

---

## 2. Directory Layout Mapping

| Role | macOS | Windows (Recommended) |
|---|---|---|
| Desktop state & vault | `~/Library/Application Support/Switcher` | `%LOCALAPPDATA%\Switcher` |
| CLI config & pointers | `~/.config/switcher` (`$XDG_CONFIG_HOME/switcher`) | `%APPDATA%\Switcher\cli` |
| CLI PATH shims | `~/.local/share/switcher/bin` (`claude`, `codex`) | `%LOCALAPPDATA%\Switcher\bin` (`claude.cmd`, `codex.cmd`) |
| Claude Code profiles | `~/.claude` (default), `~/.claude-profiles/<name>` | `%USERPROFILE%\.claude`, `%USERPROFILE%\.claude-profiles\<name>` |
| Codex profiles | `~/.codex` (default), `~/.codex-profiles/<name>` | `%USERPROFILE%\.codex`, `%USERPROFILE%\.codex-profiles\<name>` |
| Desktop secrets | macOS Login Keychain (`security` / SecItem) | Windows Credential Manager (`CredWriteW` / DPAPI) |

---

## 3. Shared State File Schemas

### 3.1 Desktop Roster (`<state>/accounts.json`)
Compatible with `cc-same`'s `accounts.json` slot shape:
```json
{
  "version": 1,
  "lists": {
    "claude": [
      {
        "number": 1,
        "account": "<uuid>",
        "email": "ada@lovelace.dev",
        "alias": "work",
        "disabled": false,
        "addedAt": 1790000000,
        "orgs": ["<org-uuid>"]
      }
    ],
    "antigravity": [
      {
        "number": 1,
        "account": "ada@lovelace.dev",
        "email": "ada@lovelace.dev",
        "alias": "studio",
        "disabled": false,
        "addedAt": 1790000000,
        "orgs": []
      }
    ]
  }
}
```
- Display priority: `alias` (primary title) → `email` (secondary subtitle when alias is set, or primary title otherwise) → `"Account <id-prefix-8>"`.

### 3.2 CLI Display Metadata (`<cli-config>/cli-meta.json`)
Stores display aliases without ever renaming profile directories on disk:
```json
{
  "version": 1,
  "aliases": {
    "claude:work": "Work Main",
    "codex:account2": "Side"
  }
}
```
- Key format: `"<kind>:<folderName>"` where `<kind>` is `"claude"` or `"codex"`, and `<folderName>` is `"default"` or a valid `[A-Za-z0-9._-]{1,64}` folder name.
- Alias validation: trimmed, `1...32` characters, no control characters, not all digits, case-insensitively unique per `<kind>`.

### 3.3 CLI Pointers (`<cli-config>/claude.current`, `<cli-config>/codex.current`)
Single line UTF-8 text:
- `"default\n"` → shim leaves `CLAUDE_CONFIG_DIR` / `CODEX_HOME` unset.
- `"<exact-profile-folder-path>\n"` → shim exports the variable only if it is a direct child of `<profilesRoot>`, valid folder name, real directory (not a symlink), and the variable is not already set (`SWITCHER_BYPASS=1` also bypasses).

### 3.4 CLI Quota Cache (`<cli-config>/quota-cache.json`)
```json
{
  "version": 1,
  "entries": {
    "claude:work": {
      "accountKey": "<accountUuid>:<orgUuid>",
      "quota": {
        "windows": [
          { "label": "5h", "usedPercent": 42.5, "resetsAt": 1800003600 },
          { "label": "week", "usedPercent": 18.0, "resetsAt": 1800300000 }
        ],
        "source": "usage endpoint",
        "observedAt": 1800000000,
        "plan": "max"
      }
    }
  }
}
```
- `accountKey` guard: cached readings are ONLY used if the profile's current `accountKey` matches the cached `accountKey`.

### 3.5 Antigravity Quota Cache (`<state>/antigravity-usage.json`)
Map of `<lowercased-email>` → `AntigravityQuota`:
```json
{
  "ada@lovelace.dev": {
    "plan": "Google AI Pro",
    "buckets": [
      { "pool": "gemini5h", "used": 34, "resetsAt": 1800008640 },
      { "pool": "geminiWeekly", "used": 12, "resetsAt": 1800324000 },
      { "pool": "claude5h", "used": 78, "resetsAt": 1800012240 },
      { "pool": "claudeWeekly", "used": 41, "resetsAt": 1800324000 },
      { "pool": "argonWeekly", "used": 6, "resetsAt": 1800324000 }
    ],
    "fetchedAt": 1800000000,
    "problem": null
  }
}
```

### 3.6 Notification Deduplication Ledger (`<state>/alert-state.json`)
```json
{
  "version": 1,
  "windows": {
    "Claude Code:claude:default:5h": {
      "highestTier": 80,
      "resetBucket": 1800003600,
      "updatedAt": 1800000000
    }
  },
  "expiries": {
    "cliRefresh:Claude Code:claude:work": 1800259200
  }
}
```
- `resetBucket` is rounded to 5-minute increments (`300s`) to prevent duplicate notifications from minor clock jitter.
- Entries older than 30 days are automatically pruned.

---

## 4. Machine-Readable CLI Contract (`switcher.usage.v1`)

Produced by `switcher cli usage [<cli>] --json` and `switcher cli usage [<cli>] --cached`:
- `schema`: `"switcher.usage.v1"`
- `generatedAt`: ISO-8601 UTC timestamp
- `groups[]`: per CLI (`claude`, `codex`):
  - `cli`, `active` (folder name), `best` (folder name with most remaining headroom when active is `low`/`out`, or `null`), `accounts[]`:
    - `number`, `name`, `active`, `email`, `plan`, `signIn`, `status` (`ok` | `low` | `out` | `unknown`), `percentLeft`, `tightestWindow`, `scopedWarning`, `windows[]`, `observedAt`, `stale`.

---

## 5. Platform Abstraction Boundary for Windows Port

To share logic cleanly when building Switcher for Windows (Swift on Windows or Rust/C# mirroring `SwitcherCore`):
1. **`SecretStore` / `CLIKeychain`**: abstract macOS Keychain behind Windows Credential Manager (`advapi32.dll`) + DPAPI (`CryptUnprotectData` where apps use Electron `safeStorage`).
2. **`AppController`**: abstract `NSRunningApplication` graceful quit/launch behind Win32 `WM_CLOSE` → process exit wait → `ShellExecuteExW` / `CreateProcessW`.
3. **`CLIShim`**: generate lightweight `.cmd` + PowerShell wrapper shims in `%LOCALAPPDATA%\Switcher\bin` prepended to User `PATH`, honoring identical `CLAUDE_CONFIG_DIR`, `CODEX_HOME`, and `SWITCHER_BYPASS=1` semantics.
4. **Shared CLI links**: use NTFS directory junctions (`mklink /J`) and file hardlinks/symlinks (without requiring Developer Mode where junctions suffice) for shared CLI config folders, keeping auth files strictly per-profile.
