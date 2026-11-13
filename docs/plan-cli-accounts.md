# Switcher 升级方案 v2：Claude Code / Codex CLI 多账号（profile 目录 + shim）

日期 2026-11-12 · 基线 `main@6e9a459` · 方向：Fable（director-fable，两轮），加上主会话本机实测
v1 草案（全局搬凭据 + live-swap 引擎）已作废，本文件取代它。

## 0. 结论

- **CLI 不搬凭据。**
  - 每个账号永久住在一个 profile 目录里：Claude 用 `CLAUDE_CONFIG_DIR`，Codex 用 `CODEX_HOME`。
  - 每个目录在原地登录一次，之后不再动。
  - 现有的 `~/.claude` 和 `~/.codex` 原地成为 1 号账号。
- **"切换"只改指针，即新进程用哪个目录。**
  - 指针由 Switcher 生成的 PATH shim 读取。
  - 正在跑的会话继续用自己的目录，各自刷新各自的钥匙串项。
  - 这样就不存在写回覆盖或 refresh token 轮换的竞争，旧方案的 live-swap 引擎整块删掉。
- **Claude Desktop 和 Antigravity 保持现有的模式 A**（退出 → 搬凭据 → 重启），不改。
- **目录约定与 token-arcade 一致**：`~/.claude-profiles/<name>`、`~/.codex-profiles/<name>`。面板可以直接看到这些账号。

## 1. 已实测的事实（不碰真实登录）

| 事实 | 证据 |
|---|---|
| 钥匙串服务名是 `Claude Code-credentials-` 加上 sha256(`CLAUDE_CONFIG_DIR` 原样字符串) 的前 8 位；不设变量时没有后缀 | 用假的 `security` 记录 claude 2.1.323 的调用：real → `bb154569`，与手算一致 |
| 不做任何路径规范化 | 软链接路径得到 `d489b4e6`（按链接字符串，不按目标）；带尾斜杠得到 `8e6f52bc` |
| 推论 1：指针不能做成软链接 | 否则所有账号会共用一个钥匙串项 |
| 推论 2：每个 profile 必须始终传同一个规范字符串 | 由上面两条得出 |
| 游离项 `Claude Code-credentials-e82e953b` 对应 sha256(`/Users/<user>/.claude`) | 说明曾有人设过 `CLAUDE_CONFIG_DIR=~/.claude`。默认账号必须**不设**这个变量 |
| 设置 `CLAUDE_CONFIG_DIR` 后，`.claude.json` 在该目录内（还有 `.lock` 和 `backups/`） | 实测 |
| claude 解析为 `~/.local/bin/claude` → `~/.local/share/claude/versions/2.1.323`；codex 解析为 `/opt/homebrew/bin/codex`（Cask 0.167.2） | `which -a` |
| `.zprofile` 先执行 `brew shellenv` 再前置 `~/.local/bin`；`.zshrc` 又前置了三次 | Fable 读 rc 文件 |
| 本机还没有 `~/.claude-profiles`、`~/.codex-profiles`，也没有 `rate-limits.json` | 实测 |
| Codex 的 `auth.json` 是文件模式 | 实测 |

## 2. 设计

### 2.1 指针与 shim
- **指针文件**：`~/.config/switcher/active-claude`、`active-codex`。内容是一行 `default`，或者一个规范绝对路径。原子写入（写临时文件再 rename）。
- **shim**：生成的 POSIX sh，约 15 行，放在 `~/.local/share/switcher/bin/`，真实二进制路径写死在里面。不能放进 `~/.local/bin`，那里会被 claude 的更新程序改写。
  1. `CLAUDE_CONFIG_DIR` 或 `CODEX_HOME` 已经设置（Orca、token-arcade、手动、嵌套启动）：原样透传。
  2. 设置了 `SWITCHER_BYPASS=1`：原样透传。
  3. 指针是 `default`：不设变量（不能设成 `~/.claude`）。
  4. 指针是路径：校验它在 profiles 根下、存在、不是软链接、没有尾斜杠，然后设置变量并 `exec`。
  5. 指针无效：回落到 default；只在 tty 下向 stderr 提示。
  6. 防递归：真实二进制不能是 shim 自己。
- **PATH**：用户点击后，往 rc 文件**末尾**追加一行带标记的 `export PATH=…`。它必须在 `brew shellenv` 和所有 `~/.local/bin` 前置之后，`doctor` 负责监督。
- **路径全程用 String。** 注册表里存规范字符串，原样传给 shim 和哈希函数，绝不经过 `URL` 往返：`standardizedFileURL` 和 `resolvingSymlinksInPath` 会改 `/private` 前缀和尾斜杠，哈希就变了。
- **`switcher exec <cli> <who> -- …`**：只对这一条命令指定账号，相当于按终端固定账号。

### 2.2 接入账号
- **1 号账号**：`~/.claude` 和 `~/.codex` 原地注册，零迁移，安装时不碰任何真实登录。
- **`switcher add <cli> <name>`**：
  1. 建 0700 目录；
  2. 按 §2.3 建链接；
  3. 用默认目录的 `.claude.json` 播种：排除 `oauthAccount`、`userID`，保留 `mcpServers` 和项目信任；
  4. 打印登录命令：`CLAUDE_CONFIG_DIR=<path> claude` 后跑 `/login`，或 `CODEX_HOME=<path> codex login`。
- **不导入 Orca 的账号。**

### 2.3 共享内容（链接都指向默认目录）
| | 无条件共享（目录） | 验证后再共享（文件，见 §3） | 各自独立 |
|---|---|---|---|
| Claude | `agents/ commands/ skills/ plugins/ scripts/ projects/ file-history/` | `settings.json CLAUDE.md keybindings.json history.jsonl` | `.claude.json`、`.credentials.json`、`daemon/`、缓存、遥测、`rate-limits.json` |
| Codex | `skills/ plugins/ rules/` | `AGENTS.md config.toml sessions/` | `auth.json`、sqlite、日志、`packages/` |

- **为什么共享 `projects/`**：额度用完切账号后还能 `--resume` 接着干，这正是切换的目的。
- **代价**：token-arcade 按账号统计的本地 token 会混在一起。以后可以加一个 SessionStart 钩子，记录每个会话属于哪个 profile，把归因找回来。
- **文件链接的风险**：如果 CLI 写文件时用 rename，链接会被换成普通文件。这种情况改为"副本 + doctor 报告差异"。

### 2.4 GUI 启动的 CLI
- Claude Desktop 内嵌的 claude、ChatGPT.app 和 app-server-daemon、IDE 插件都不走 PATH，**永远用默认目录**。这是明确的语义：指针只管经 shim 启动的新进程。
- 想让这些 GUI 进程换账号：在默认目录里重新登录，或者换 Desktop 本身的账号（Switcher 已有的模式 A）。
- **不用 `launchctl setenv`**：它会影响 Desktop 内嵌的 CLI。
- T3 是否经过 shim 要实测（§3）。

### 2.5 共存
- **Orca**：它自己设置环境变量，shim 透传。它的"系统默认"会跟着指针变，这一点写进文档；需要时用 `SWITCHER_BYPASS=1` 绕过。
- **token-arcade**：它用绝对路径加显式环境变量调用，不经过 shim，无冲突。但它按目录名排序映射 cc2–cc5（最多 4 个，Codex 只有 co2），新建目录会让别名移位。建议用 `TOKEN_CLAUDE_PROFILES` 固定。
- **cc-same**：只和 Claude Desktop 有关，不变。

### 2.6 额度、到期、身份（参考 token-arcade 用 Swift 重写；Switcher 永不自己刷新 token）
- **Claude 额度**：
  - 读该 profile 的钥匙串项，取 `expiresAt`、`refreshTokenExpiresAt` 和订阅类型。
  - 有 `rate-limits.json` 时优先读它：5 分钟内直接用；接口失败时 15 分钟内的读数可以兜底。
  - 否则调 `api.anthropic.com/api/oauth/usage`，请求头带 `anthropic-beta: oauth-2025-04-20`。遇到 429 就退避，不重试。
- **保活**：token 过期时，带上该 profile 的环境变量跑一次最小的 `claude -p --model haiku --tools '' --setting-sources '' --no-session-persistence --strict-mcp-config --disable-slash-commands`，让 CLI 自己续期。每个 profile 30 分钟最多一次，只在手动刷新或 refresh token 剩余不到 5 天时触发。
- **Codex 额度**：带 `CODEX_HOME` 启动 `codex app-server`，调 `account/read{refreshToken:false}` 和 `account/rateLimits/read`，读完复核 `account_id`。
- **身份**：Claude 读该目录 `.claude.json` 里的 `oauthAccount`；Codex 解 `id_token` 的 JWT payload。
- **界面**：显示"登录有效至 X"，这是闲置账号静默失效的唯一预警。

### 2.7 `switcher doctor`（只读，从不输出密钥值）
- 在 `zsh -lc`、`-ic`、`-c` 三种模式下，`claude` 和 `codex` 都解析到 shim。
- 真实二进制存在，且不是 shim 自己。
- 每个 profile 的哈希对应的钥匙串项存在（只查存在与否）。
- 指针有效，路径无尾斜杠、不是软链接。
- 链接仍是链接，目标正确。
- 各 profile 之间的 `mcpServers` 差异。
- 各账号的到期时间。
- 只报告、不删除：游离后缀项（如 `-e82e953b`）、陈旧的 `~/.claude/.credentials.json`、rc 文件里的 PATH 行不在最后。

## 3. 待验证的事实

1–5 项在临时 `HOME` 下做，配合假的 `security` 和假二进制，不碰真实登录；6–8 项需要你同意。
1. [ ] CLI 写 `settings.json` / `history.jsonl` 后，链接是否还在（找一个会写用户设置的非交互命令，候选是 plugin enable/disable）。
2. [ ] 在临时 `CODEX_HOME` 跑 `codex mcp add` 后，`config.toml` 的链接是否还在。
3. [ ] 是否每个 profile 各起一个 Claude daemon、Codex 是否各下载一份 `packages/`（磁盘和进程开销）。
4. [ ] 在 shim 下跑 `claude update` / `claude doctor`，会不会报"多重安装"。
5. [ ] 共享 `sessions/` 后 `codex resume` 能不能看到会话，还是依赖各自的 sqlite 索引。
6. [ ] 跨 profile `claude --resume`：在草稿目录建一个会话，换 profile 后续接。
7. [ ] 同一账号在新 profile 登录，会不会吊销 Orca 或默认目录里的会话（用次要账号测）。
8. [ ] T3 启动的进程是否经过 shim：只查进程环境里有没有 `CLAUDE_CONFIG_DIR` 这个变量名，不打印环境内容。

**会改变结论的情况**
- 第 1 或第 2 项发现链接会被替换：对应文件改为"副本 + 报告差异"。
- 第 7 项发现新登录会吊销旧会话：同一个账号不能同时放在 Orca 和 Switcher 里，你要为每个账号选一个归属。

## 4. 阶段与派工

规则：
- 一个单元一份 brief、一个 worker，在 `wip/<unit>` 分支上做。
- 测试只用临时目录和 fake（`Sandbox`、`MemorySecrets`、假二进制、URLProtocol 桩）。
- 主会话（Opus）审每个 diff。
- shim、钥匙串名、链接这三块属于 auth/路由，合并前按你的规则过一轮 Codex（`gpt-6.1-sol` xhigh）独立审查。

| 阶段 | 内容 | 执行 | 完成条件 / 检查 |
|---|---|---|---|
| P0 | §3 第 1–5 项实验 | Sonnet（临时 HOME） | 每项有命令和实测输出；主会话记入 SESSION_STATE |
| P1 | `Profiles` 核心：注册表（String 路径）、`claudeKeychainService`、指针原子读写、链接计划的 apply/check、`.claude.json` 播种 | Opus 定类型和接口 → Sonnet 实现 | `swift test` 通过；有哈希测试向量（`bb154569` 这种可复现的）；拒绝尾斜杠和软链接；能检测链接被替换；apply 幂等 |
| P2 | shim 生成和安装（只在点击时追加带标记的 rc 末行） | Opus 写 shim → Sonnet 写测试 | 假二进制打印环境的测试覆盖：指针生效、透传、`default` 不设变量、无效指针回落、无递归、BYPASS |
| P3 | CLI 命令 `add / switch / exec / list / doctor` | Sonnet | 测试通过；你同意后跑一次真机只读 `doctor`，能识别默认账号并报告游离项 |
| P4 | 额度与到期（§2.6） | Sonnet；Opus 审 token 处理 | URLProtocol 桩和假 app-server 的测试通过；你同意后读一次真实默认账号 |
| P5 | 界面：账号行、到期倒计时、"仅对新会话生效"文案、`doctor` 结果入口 | worker-fable | 测试通过；浅色和深色截图由 Fable 自评 |
| P6 | 真实上线：建一个 profile、登录、切换、续接 | 主会话，需要你同意 | §3 第 6–8 项勾掉；AGENTS.md 的 Rules 里加一条"verified on claude 2.1.3xx / codex 0.167" |
| 并行 | 崩溃点扫描测试（模式 A）、钥匙串形状校验、`trash/` 14 天清理、CI（`swift test`）、README 和 Network 段 | Sonnet；CI 文件和 zh-CN 同步给 Haiku | 各自测试通过；CI 在 `wip/ci` 上跑绿 |

依赖关系：P0 → P1 → P2 → P3 → {P4, P5} → P6；"并行"一行随时可以做。

## 5. 需要你拍板（附推荐）

| # | 决策 | 推荐 |
|---|---|---|
| 1 | CLI 改用 profile + shim，放弃模式 A | 是 |
| 2 | 共享 `projects/` 和历史，以便跨账号 `--resume` | 共享 |
| 3 | 目录约定沿用 token-arcade | 是，并用 `TOKEN_CLAUDE_PROFILES` 固定别名 |
| 4 | Switcher 是否改 rc 文件 | 你点击后追加带标记的末行，由 doctor 监督 |
| 5 | 保活运行（每次真实消耗一次 Haiku 调用） | 只在手动刷新时，或 refresh token 剩余不到 5 天时触发 |
| 6 | 网络：读 Anthropic 用量接口；Codex 走 app-server | 允许，同时更新 README |
| 7 | GUI 启动的 CLI 固定用默认账号 | 接受 |
| 8 | 游离钥匙串项和陈旧文件 | 你看过 doctor 报告后手动删除；Switcher 永不自动删 |

## 6. Brief 模板

```
目标：<一句话>
范围：<文件>；不要改：<模式 A 的 provider / UI / 无关文件>
规则：AGENTS.md 全文；测试只用临时目录和 fake；不碰真实钥匙串、真实应用、真实 rc 文件
完成条件：<可验证的条件>
检查：swift test --filter <X>，然后 swift test
交付：diff 摘要 + 检查输出原文；在 wip/<unit> 分支，不要合并
```
