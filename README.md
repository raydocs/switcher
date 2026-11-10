<p align="center">
  <img src="assets/icon-1024.png" width="128" height="128" alt="Switcher icon">
</p>

<h1 align="center">Switcher</h1>

<p align="center">
  One click to move <b>Claude Desktop</b> and <b>Antigravity</b> to another of your accounts.<br>
  A native macOS menu bar app. No re-login, no copy-pasting tokens.
</p>

<p align="center">
  <a href="#install">Install</a> ·
  <a href="#how-it-works">How it works</a> ·
  <a href="README.zh-CN.md">中文</a>
</p>

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/popover-dark.png">
    <img src="docs/popover-light.png" width="380" alt="Switcher's menu bar popover">
  </picture>
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/claude-dark.png">
    <img src="docs/claude-light.png" width="380" alt="Switcher's menu bar popover">
  </picture>
</p>

## What it does

- **Switch accounts in one click.** Pick an account from the menu bar. Switcher quits the app, puts that
  account's sign-in in place and opens the app again, already signed in. An Antigravity switch
  takes about two seconds.
- **Next account.** One button moves to the next account in your list, skipping the ones you turned off.
- **Antigravity quota for every account.** See each account's Gemini and Claude quota (5-hour and
  weekly) side by side, so you know which one still has room before you switch.
- **Add accounts the normal way.** "Add account" opens the app on its sign-in page. Sign in as usual
  and Switcher remembers it; the account you left stays saved.
- **Knows who you are.** Each account is shown by its email, read from the app's own files.
- **CLI included.** `switcher list`, `switcher switch claude 2`, `switcher usage` and more.

## Install

**Homebrew**

```sh
brew install --cask raydocs/tap/switcher
```

**Download.** Grab `Switcher.zip` from [Releases](https://github.com/raydocs/switcher/releases), unzip
it into `/Applications`, then run `xattr -dr com.apple.quarantine /Applications/Switcher.app` once.
The build is ad-hoc signed (not notarized), so macOS blocks it without that step.

**From source** (Xcode 16 or the Swift 6 toolchain):

```sh
git clone https://github.com/raydocs/switcher && cd switcher
scripts/bundle.sh && cp -R dist/Switcher.app /Applications/
```

Requires macOS 14 or later.

## How it works

An app's sign-in is a handful of files and keychain items. Switcher moves them; it never decrypts,
reads or sends your credentials anywhere.

| App | What a sign-in is |
|---|---|
| Claude Desktop | The claude.ai web session (cookies, local and session storage, IndexedDB) and the token cache keys in `config.json`, all still encrypted by Claude's own key |
| Antigravity | The OAuth token in the login keychain (`gemini` / `antigravity`) and the onboarding keys in `app_storage.json` |

Each switch is journaled: the app is quit first, the current sign-in is set aside, the target one is
put back, and the journal is committed only once everything is on disk. If anything fails halfway, or
the Mac loses power, the next start finishes or undoes it, so you are never left with half of two
accounts. Sign-ins are moved, never copied, so a saved sign-in is only ever in one place.

Saved sign-ins live in `~/Library/Application Support/Switcher/`.

**Network.** The only requests Switcher makes are the Antigravity quota reads: for each saved
account it refreshes that account's own token in memory and asks Google for its quota. Nothing is
sent anywhere else.

## Known limitations

- Tested with Claude Desktop 4.23118 and Antigravity 2.31. Both apps change how they store sign-ins
  from time to time; after an update, switch once and check you landed on the right account.
- Claude Desktop's plan usage isn't shown (the app no longer keeps it in a readable file).

## Not affiliated

Switcher is an independent project. It is not made, endorsed or supported by Anthropic or Google.
Claude and Antigravity are trademarks of their owners. Use it only with accounts you own, and follow
each service's terms.

## License

[MIT](LICENSE)
