<p align="center">
  <img src="assets/icon-1024.png" width="128" height="128" alt="Switcher 图标">
</p>

<h1 align="center">Switcher</h1>

<p align="center">
  一键把 <b>Claude Desktop</b> 和 <b>Antigravity</b> 切到你的另一个账号。<br>
  原生 macOS 菜单栏应用，不用重新登录，也不用来回粘贴 token。
</p>

<p align="center">
  <a href="#安装">安装</a> ·
  <a href="#原理">原理</a> ·
  <a href="README.md">English</a>
</p>

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/popover-dark.png">
    <img src="docs/popover-light.png" width="380" alt="Switcher 菜单栏弹窗">
  </picture>
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/claude-dark.png">
    <img src="docs/claude-light.png" width="380" alt="Switcher 菜单栏弹窗">
  </picture>
</p>

## 功能

- **一键切换账号。** 在菜单栏里点一个账号，Switcher 会退出应用、换上那个账号的登录，再重新打开，打开时已经是新账号。
  Antigravity 切一次大约两秒。
- **下一个账号。** 一个按钮切到列表里的下一个账号，停用的账号会跳过。
- **所有 Antigravity 账号的额度。** 每个账号的 Gemini 和 Claude 额度（5 小时和每周）并排显示，切之前就知道哪个号还有余量。
- **照常添加账号。** 点"添加账号"，应用会停在登录页，正常登录即可，Switcher 会记住它；原来的账号也会保留。
- **用邮箱区分账号。** 每个账号显示它的邮箱，从应用自己的文件里读出来。
- **Claude Code 和 Codex CLI 账号。** 选择新的 `claude` 和 `codex` 终端会话用哪个账号，并查看每个账号的额度。这些与桌面应用是分开的：切换 CLI 账号只改变*新的* `claude` / `codex` 进程用哪个账号。正在运行的会话保留原账号，不会退出任何程序，Claude Desktop 和 ChatGPT 应用也不受影响。切换桌面应用的方式和以前一样。详见 [CLI 账号](#cli-accounts-claude-code-and-codex)。
- **附带命令行。** `switcher list`、`switcher switch claude 2`、`switcher usage` 等。

## 安装

**Homebrew**

```sh
brew install --cask raydocs/tap/switcher
```

**直接下载。** 从 [Releases](https://github.com/raydocs/switcher/releases) 下载 `Switcher.zip`，解压到
`/Applications`，然后运行一次 `xattr -dr com.apple.quarantine /Applications/Switcher.app`。
这个版本是 ad-hoc 签名、没有公证，不做这一步 macOS 会拦住它。

**从源码构建**（需要 Xcode 16 或 Swift 6 工具链）：

```sh
git clone https://github.com/raydocs/switcher && cd switcher
scripts/bundle.sh && cp -R dist/Switcher.app /Applications/
```

需要 macOS 14 或更新版本。

## CLI accounts (Claude Code and Codex)

每个账号有自己的文件夹，Switcher 把新的终端会话指向其中一个。

- **配置文件夹。** Claude Code 用 `~/.claude-profiles/<name>`，Codex 用 `~/.codex-profiles/<name>`。账号 1 是默认账号：你平时的 `~/.claude` 和 `~/.codex`，保持不动。
- **指针。** `~/.config/switcher/active-claude` 和 `active-codex` 各只有一行：新进程应该使用的文件夹。`switcher cli use` 只改写这一行，不移动任何凭据。
- **垫片（shim）。** `switcher cli install` 会在 `~/.local/share/switcher/bin` 放入小的 `claude` 和 `codex` 垫片，并在 `~/.zshrc` 末尾加一行 PATH。垫片读取指针，为该进程设置 `CLAUDE_CONFIG_DIR` 或 `CODEX_HOME`，然后运行真正的 CLI。默认账号则什么都不设。`switcher cli uninstall` 会把两者都删掉。
- **共享设置。** 新建的配置文件夹会从默认文件夹链接你的配置和历史，所以切换之后 `--resume` 仍能找到你的会话。共享项（Claude Code）：`agents`、`commands`、`skills`、`plugins`、`scripts`、`hooks`、`projects`、`file-history`、`todos`、`CLAUDE.md`、`settings.json`、`keybindings.json`、`history.jsonl`。共享项（Codex）：`skills`、`plugins`、`rules`、`prompts`、`sessions`、`archived_sessions`、`AGENTS.md`、`config.toml`、`session_index.jsonl`、`history.jsonl`。其余内容各账号独立：登录状态、缓存、数据库，以及 Claude Code 的 `.claude.json`。

这套文件夹结构与 [token-arcade](https://github.com/raydocs/token-arcade) 相同。Switcher 也能和 Orca 共存：如果 `CLAUDE_CONFIG_DIR` 或 `CODEX_HOME` 已经设置，垫片会原样透传。设置 `SWITCHER_BYPASS=1` 可以让某一条命令跳过垫片。

**快速开始**

```sh
switcher cli install                 # shims and the PATH line; open a new terminal afterwards
switcher cli add cc work             # make ~/.claude-profiles/work and print how to sign it in
                                     # now run the sign-in command it printed
switcher cli use cc work             # new `claude` processes now use "work"
switcher cli exec co 2 -- codex      # run Codex as account 2, once, without changing the pointer
switcher cli usage                   # quota of every profile
switcher cli doctor                  # check shims, sign-ins, links and keychain items
```

**命令**

| 命令 | 作用 |
|---|---|
| `switcher cli [list] [--json]` | 每个配置文件夹、它登录的是谁，以及哪个是当前激活的 |
| `switcher cli use <cli> [<who>]` | 新的 `claude` / `codex` 进程使用这个账号（不带 `<who>`：下一个账号） |
| `switcher cli add <cli> <name>` | 创建配置文件夹并显示如何登录 |
| `switcher cli link [<cli>]` | 把共享设置链接到每个配置文件夹 |
| `switcher cli exec <cli> <who> [-- <command> [args]]` | 以某个账号运行一条命令（默认：真正的 CLI） |
| `switcher cli install [--no-rc]` | 安装垫片和 `~/.zshrc` 中的那一行（`--no-rc`：只装垫片，由你自己把文件夹加入 PATH） |
| `switcher cli uninstall` | 删除垫片和 rc 中的相关行 |
| `switcher cli doctor` | 检查垫片、登录状态、链接和钥匙串条目 |
| `switcher cli usage [<cli>] [--renew]` | 立即读取每个配置文件夹的额度；`--renew` 允许 CLI 续期已过期的登录 |

`<cli>` 为 `claude` 或 `codex`（即 `cc` / `co`）。`<who>` 可以是数字（1 = 默认账号）、名称或 `default`。

## 原理

一个应用的登录状态就是几个文件和钥匙串条目。Switcher 只是把它们挪来挪去，从不解密、读取或上传你的凭据。

| 应用 | 登录状态包括 |
|---|---|
| Claude Desktop | claude.ai 网页会话（Cookies、Local/Session Storage、IndexedDB）和 `config.json` 里的 token 缓存键，仍由 Claude 自己的密钥加密 |
| Antigravity | 登录钥匙串里的 OAuth token（`gemini` / `antigravity`）和 `app_storage.json` 里的 onboarding 键 |
| Claude Code CLI | 钥匙串条目 `Claude Code-credentials[-<8 hex of sha256(folder)>]` 和配置文件夹里的 `.claude.json`。不移动任何内容 |
| Codex CLI | 配置文件夹里的 `auth.json`。不移动任何内容 |

每次切换都有日志：先退出应用，把当前登录放到一边，再放回目标账号的登录，全部落盘后才提交。中途出错或者断电，下次启动会把它做完或者撤销，
不会出现两个账号各一半的情况。登录状态只移动、不复制，所以一份保存的登录永远只在一个地方。

保存的登录放在 `~/Library/Application Support/Switcher/`。

**网络。** Switcher 只会发出以下请求，没有其他：

- Antigravity 额度：对每个保存的账号，在内存里用它自己的 token 刷新一次，然后向 Google 查询额度。
- Claude Code 额度：`https://api.anthropic.com/api/oauth/usage`，使用该配置文件自己的访问 token，且仅在没有新鲜的 statusline 读数时发送。
- Codex 额度：通过本地的 `codex app-server`，由它自己与 OpenAI 通信。

Switcher 从不刷新 CLI 的 token。`switcher cli usage --renew` 会运行一次最小的 `claude -p`（一个很小的 Haiku 请求），让 Claude Code 自己续期登录。除此之外不发送任何内容。

## 已知限制

- 在 Claude Desktop 4.23118 和 Antigravity 2.31 上测过。这两个应用时不时会改登录状态的存法，更新之后先切一次，确认切到的是对的账号。
- 通过 GUI 启动的 CLI，以及不经过 PATH 的 IDE 插件，始终使用默认账号。
- 如果 shell rc 把另一个文件夹放在 Switcher 那一行之前，垫片就会失效。`switcher cli doctor` 会给出警告。
- 在 Claude Code 2.1.323 和 Codex 0.167.2 上测过。
- 不显示 Claude Desktop 的套餐用量（应用已经不再把它写进可读的文件）。

## 声明

Switcher 是独立项目，与 Anthropic 和 Google 无关，也未获得它们的认可或支持。Claude 和 Antigravity 是各自所有者的商标。
请只用于你自己的账号，并遵守各服务的条款。

## 许可证

[MIT](LICENSE)
