import Foundation
import SwitcherCore

let usage = """
switcher: switch Claude Desktop and Antigravity between your accounts.

  switcher list [--json]               every app's accounts, numbered
  switcher switch <app> [<who>]        switch to an account, or the next one (Claude restarts)
  switcher add <app>                   restart the app signed out, to sign in to another account
  switcher remove <app> <who>          take an account off the list, forgetting its saved sign-in
  switcher alias <app> <who> <name>    give an account a short name ("-" clears it)
  switcher disable|enable <app> <who>  leave an account out of Next Account, or put it back
  switcher move <app> <who> <number>   give an account another number
  switcher usage                       read every Antigravity account's quota from Google now
  switcher import-cc-same              take over CC Same's saved Claude sign-ins and list
  switcher cli ...                     Claude Code, Codex and Antigravity CLI accounts per terminal: run `switcher cli help`

<app> is claude or antigravity (c / a). <who> is a number, alias, email or the start of an ID.
"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("switcher: \(message)\n".utf8))
    exit(1)
}

func app(_ s: String?) -> ProviderID {
    switch s?.lowercased() {
    case "claude", "c": .claude
    case "antigravity", "agy", "a": .antigravity
    default: fail("say which app: claude or antigravity")
    }
}

func ago(_ d: Date) -> String {
    let s = Date().timeIntervalSince(d)
    if s < 90 { return "just now" }
    if s < 5400 { return "\(Int(s / 60)) min ago" }
    if s < 129_600 { return "\(Int(s / 3600)) h ago" }
    return "\(Int(s / 86_400)) d ago"
}

// MARK: - switcher cli

let cliUsage = """
switcher cli: Claude Code, Codex and Antigravity CLI accounts, chosen per new terminal session.

  switcher cli [list] [--json]         every profile, who it is signed in as, and which is active
  switcher cli use <cli> [<who>]       new claude/codex/agy processes use this account (or the next)
  switcher cli add [<cli>] [<name>]    add an account: sign in in the browser, then offer to switch
                                       (--no-login: only the folder; --use: switch without asking)
  switcher cli login <cli> [<who>]     sign an account in again (default: the active one)
  switcher cli remove <cli> <who> [--yes]
                                       sign an account out and move its folder to the Trash
  switcher cli link [<cli>]            link shared settings into every profile
  switcher cli exec <cli> <who> [-- <command> [args]]
                                       run a command (default: the real CLI) as one account
  switcher cli install [--no-rc]       install the PATH shims (and the line in ~/.zshrc)
  switcher cli uninstall               remove the shims and the rc lines
  switcher cli doctor                  check shims, sign-ins, links and keychain items
  switcher cli usage [<cli>] [--renew] read each profile's quota now (--renew: let Claude renew an expired sign-in)
  switcher cli usage [<cli>] --json    the same, as JSON (schema switcher.usage.v1), with headroom and the best account
  switcher cli usage [<cli>] --cached  the last readings as JSON: no request, no process, no keychain

<cli> is claude, codex or agy (cc / co / antigravity). <who> is a number (1 = the default account), a name, an email or default.
"""

func makeCLIEnv() -> CLIEnv {
    let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
    let noFallback = ProcessInfo.processInfo.environment["SWITCHER_NO_FALLBACK_PATH"] == "1"
    return noFallback ? CLIEnv(home: home, fallbackSearchDirs: []) : CLIEnv(home: home)
}

func makeCLIKeychain() -> CLIKeychain {
    ProcessInfo.processInfo.environment["SWITCHER_NO_KEYCHAIN"] == "1" ? MemoryCLIKeychain() : LiveCLIKeychain()
}

func resolveRealBinary(_ kind: CLIKind, env: CLIEnv) -> String? {
    if let fromShim = CLIShim.realBinary(ofShim: env.shim(kind)),
       fromShim.hasPrefix("/"), CLIShim.isRegularExecutable(fromShim), !CLIShim.isShim(fromShim)
    {
        return fromShim
    }
    return CLIShim.findRealBinary(kind, env: env)
}

/// A line from the terminal, trimmed; nil at end of input.
func ask(_ prompt: String) -> String? {
    print(prompt, terminator: "")
    fflush(stdout)
    return readLine()?.trimmingCharacters(in: .whitespaces)
}

/// Run the CLI's own sign-in inside `profile`'s folder, in this terminal, then say who it is
/// signed in as and (for a new account) offer to point new sessions at it.
func signIn(_ profile: CLIProfile, env: CLIEnv, profiles: CLIProfiles, keychain: CLIKeychain,
            createdNow: Bool, offerToUse: Bool, useWithoutAsking: Bool) -> Never {
    let kind = profile.kind
    guard let real = resolveRealBinary(kind, env: env) else {
        fail("no real \(kind.command) found on PATH; sign in later with:\n  \(kind.loginCommand(profile))")
    }
    print("Signing in a \(kind.displayName) account: finish in the browser that opens (Ctrl-C cancels)…\n")
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: real)
    proc.arguments = kind.loginArguments
    proc.currentDirectoryURL = URL(fileURLWithPath: env.home, isDirectory: true)
    var environment = env.augmentedEnvironment()
    environment["HOME"] = env.home
    for (v, value) in CLICommands.envEdits(profile) { environment[v] = value }
    var agyStage: String?
    if kind == .agy {
        environment["AGY_CLI_CDE_AUTH_ACTION"] = "login"
        environment["SWITCHER_BYPASS"] = "1"
        if !profile.isDefault {
            do {
                let stage = try CLILoginRun.prepareAgyLoginStaging(for: profile)
                agyStage = stage
                environment["HOME"] = stage
            } catch {
                fail(error.localizedDescription)
            }
        }
    }
    proc.environment = environment
    // Ctrl-C belongs to the sign-in while it runs.
    signal(SIGINT, SIG_IGN)
    defer { signal(SIGINT, SIG_DFL) }
    do {
        try proc.run()
    } catch {
        if let stage = agyStage { CLILoginRun.finalizeAgyLoginStaging(loginHome: stage, for: profile, succeeded: false) }
        fail("cannot run \(real): \(error.localizedDescription)")
    }
    proc.waitUntilExit()
    if let stage = agyStage {
        CLILoginRun.finalizeAgyLoginStaging(loginHome: stage, for: profile, succeeded: proc.terminationStatus == 0)
    }
    print("")
    let after = profiles.signIn(profile, keychain: keychain)
    let expired = after.refreshExpiresAt.map { $0 <= Date() } ?? false
    guard proc.terminationStatus == 0, after.state != .signedOut, !expired else {
        if createdNow, after.state == .signedOut {
            try? profiles.discardUnsignedIn(profile, keychain: keychain)
            print("Not signed in, so nothing was added. Run `switcher cli add \(kind.command)` to try again.")
        } else {
            print("Not signed in yet. Try again any time with:\n  switcher cli login \(kind.command) \(profile.name)")
        }
        exit(1)
    }
    let who = profiles.identity(profile, keychain: keychain)
    let label = [who?.email, who?.plan.map { "(\($0))" }].compactMap { $0 }.joined(separator: " ")
    print("✓ Signed in\(label.isEmpty ? "" : " as " + label) · account \(profile.name)")
    if let twin = profiles.duplicates(of: profile, keychain: keychain).first {
        print("  This is the same account as \(twin.name). If that was not meant: `switcher cli remove \(kind.command) \(profile.name)`.")
    }
    guard offerToUse, !profile.isDefault, profiles.active(kind) != profile else { exit(0) }
    var use = useWithoutAsking
    if !use {
        let answer = ask("Use it for new \(kind.command) sessions now? [Y/n] ")?.lowercased() ?? "n"
        use = answer.isEmpty || answer.hasPrefix("y")
    }
    if use {
        do { try profiles.setActive(profile) } catch { fail(error.localizedDescription) }
        print("New \(kind.command) sessions now use \(label.isEmpty ? profile.name : who?.email ?? profile.name). Back: `switcher cli use \(kind.command) default`.")
    } else {
        print("Switch any time: `switcher cli use \(kind.command) \(who?.email ?? profile.name)`.")
    }
    exit(0)
}

func runCLI(_ args: [String]) -> Never {
    // HOME rather than NSHomeDirectory(), so a test run can point everything at a temporary folder.
    let env = makeCLIEnv()
    let profiles = CLIProfiles(env: env)
    let keychain = makeCLIKeychain()
    var args = args
    let sub = args.isEmpty ? "list" : args.removeFirst()

    func cli(_ s: String?) -> CLIKind {
        guard let k = CLICommands.kind(s) else { fail("say which CLI: claude, codex or agy (cc / co / antigravity)") }
        return k
    }

    do {
        switch sub {
        case "list", "ls":
            let groups = CLICommands.list(profiles, keychain: keychain)
            if args.contains("--json") {
                print(try CLICommands.listJSON(groups))
            } else {
                for g in groups {
                    print("\(g.name)\(g.shimInstalled ? "" : " (no shim yet: `switcher cli install`)")")
                    for e in g.profiles { print("  " + e.line()) }
                }
            }
        case "use":
            let kind = cli(args.first)
            let target: CLIProfile
            if args.count > 1 {
                target = try CLICommands.profile(profiles, kind, args[1], keychain: keychain)
            } else {
                guard let next = profiles.next(kind) else { fail("no other \(kind.displayName) profile yet: `switcher cli add \(kind.command) <name>`") }
                target = next
            }
            try profiles.setActive(target)
            if kind == .agy, !target.isDefault { try? profiles.prepareAgyProfile(target) }
            let email = profiles.identity(target, keychain: keychain)?.email
            print("New \(kind.command) processes now use \(target.name) (\(email ?? "no sign-in yet")). Sessions already running keep their account.")
            if !CLIShim.isShim(env.shim(kind)) {
                print("The \(kind.command) shim is not installed, so this pointer has no effect until `switcher cli install`.")
            }
        case "add":
            let tty = isatty(0) == 1 && isatty(1) == 1
            let flags = Set(args.filter { $0.hasPrefix("--") })
            var rest = args.filter { !$0.hasPrefix("--") }
            let kind: CLIKind
            if let k = CLICommands.kind(rest.first) {
                kind = k
                rest.removeFirst()
            } else if rest.isEmpty, tty {
                let answer = ask("Add which account? 1 Claude Code, 2 Codex, 3 Antigravity CLI [1]: ") ?? ""
                let picked: CLIKind? = switch answer {
                case "", "1": .claude
                case "2": .codex
                case "3": .agy
                default: CLICommands.kind(answer)
                }
                guard let k = picked else { fail("say claude, codex or agy") }
                kind = k
            } else {
                kind = cli(rest.first)
            }
            let name = rest.first ?? profiles.suggestedName(kind, keychain: keychain)
            // An account that exists but is not signed in is signed in, not added again.
            if let existing = profiles.list(kind).first(where: { $0.name.lowercased() == name.lowercased() }) {
                if let problem = profiles.credentialProblem(existing, keychain: keychain) {
                    fail("\(existing.name): \(problem)")
                }
                guard profiles.signIn(existing, keychain: keychain).state == .signedOut else {
                    let email = profiles.identity(existing, keychain: keychain)?.email
                    fail("\(existing.name) is already signed in\(email.map { " as \($0)" } ?? ""); `switcher cli add \(kind.command)` adds another")
                }
                guard tty, !flags.contains("--no-login") else { print("Sign it in with:\n  \(kind.loginCommand(existing))"); exit(0) }
                signIn(existing, env: env, profiles: profiles, keychain: keychain, createdNow: false, offerToUse: true, useWithoutAsking: flags.contains("--use"))
            }
            let p = try profiles.add(kind, name: name)
            guard tty, !flags.contains("--no-login") else {
                print("Created \(p.path)")
                print("Sign it in with:\n  \(kind.loginCommand(p))")
                exit(0)
            }
            signIn(p, env: env, profiles: profiles, keychain: keychain, createdNow: true, offerToUse: true, useWithoutAsking: flags.contains("--use"))
        case "login":
            let flags = Set(args.filter { $0.hasPrefix("--") })
            let rest = args.filter { !$0.hasPrefix("--") }
            let kind = cli(rest.first)
            let p = rest.count > 1 ? try CLICommands.profile(profiles, kind, rest[1], keychain: keychain) : profiles.active(kind)
            let createdNow = flags.contains("--rollback-if-unsigned")
            signIn(p, env: env, profiles: profiles, keychain: keychain, createdNow: createdNow, offerToUse: createdNow || flags.contains("--use"), useWithoutAsking: flags.contains("--use"))
        case "remove", "rm":
            let kind = cli(args.first)
            let rest = args.dropFirst().filter { !$0.hasPrefix("--") }
            guard let who = rest.first else { fail("say which account: a number, a name or an email") }
            let p = try CLICommands.profile(profiles, kind, who, keychain: keychain)
            guard !p.isDefault else { fail("the default account stays (it is \(env.defaultFolder(kind)))") }
            let email = profiles.identity(p, keychain: keychain)?.email
            let label = p.name + (email.map { " (\($0))" } ?? "")
            if !args.contains("--yes") {
                guard isatty(0) == 1 else { fail("add --yes to remove \(label) without asking") }
                let answer = ask("Sign \(label) out and move its folder to the Trash? Shared sessions and settings stay. [y/N] ")?.lowercased() ?? ""
                guard answer.hasPrefix("y") else { print("Nothing was removed."); exit(0) }
            }
            if !kind.logoutArguments.isEmpty, profiles.signIn(p, keychain: keychain).state != .signedOut,
               let real = resolveRealBinary(kind, env: env)
            {
                let run = CLILoginRun(profile: p, binary: real, arguments: kind.logoutArguments,
                                      workingDirectory: env.home, baseEnvironment: env.augmentedEnvironment())
                try run.start()
                let (exited, _) = run.wait(timeout: 15)
                if !exited { run.cancel(grace: 2) }
            }
            if kind == .claude, keychain.exists(service: claudeKeychainService(configDir: p.envValue)), !args.contains("--force") {
                fail("\(p.name)'s keychain item is still present after logout; run `CLAUDE_CONFIG_DIR=\(shellQuote(p.path)) claude auth logout` first, or pass --force to trash the folder anyway")
            }
            try profiles.remove(p)
            print("Removed \(label). New \(kind.command) sessions use \(profiles.active(kind).name).")
        case "link":
            let kinds = args.isEmpty ? CLIKind.allCases : [cli(args.first)]
            var any = false
            for kind in kinds {
                for p in profiles.list(kind) where !p.isDefault {
                    any = true
                    let made = try profiles.applyLinks(p)
                    print("\(kind.command) \(p.name): \(made.isEmpty ? "already linked" : "linked " + made.joined(separator: ", "))")
                }
            }
            if !any { print("No profiles yet: `switcher cli add <cli>`.") }
        case "exec":
            let req: CLICommands.ExecRequest
            do { req = try CLICommands.parseExec(args) } catch { fail(error.localizedDescription) }
            let profile = try CLICommands.profile(profiles, req.kind, req.who, keychain: keychain)
            if profile.kind == .agy, !profile.isDefault { try? profiles.prepareAgyProfile(profile) }
            var argv = req.command
            if argv.isEmpty {
                // The real binary, so the shim is not involved.
                guard let real = resolveRealBinary(req.kind, env: env) else { fail("no real \(req.kind.command) found on PATH") }
                argv = (req.kind == .agy && !profile.isDefault) ? [real, "--gemini_dir=" + profile.path] : [real]
            }
            for (v, value) in CLICommands.envEdits(profile) {
                if let value { setenv(v, value, 1) } else { unsetenv(v) }
            }
            var cargs: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) } + [nil]
            execvp(argv[0], &cargs)
            let why = String(cString: strerror(errno))
            FileHandle.standardError.write(Data("switcher: cannot run \(argv[0]): \(why)\n".utf8))
            exit(127)
        case "install":
            let installed = try CLIShim.installShims(env: env)
            for kind in CLIKind.allCases {
                if let real = installed[kind] { print("\(env.shim(kind)) runs \(real)") }
                else { print("\(kind.command): no real binary found on PATH; no shim written") }
            }
            if args.contains("--no-rc") {
                print("Skipped the rc files: put \(env.shimDir) first on PATH yourself.")
            } else {
                for rc in CLICommands.rcFiles(env) {
                    try CLIShim.installRC(rc, env: env)
                    print("Put the PATH line at the end of \(rc)")
                }
                print("Open a new terminal (or `exec zsh`) for it to take effect.")
            }
        case "uninstall":
            let rcs = CLICommands.rcFiles(env)
            try CLIShim.validateUninstallRC(rcs)
            CLIShim.uninstallShims(env: env)
            print("Removed the shims from \(env.shimDir).")
            for rc in rcs {
                let had = CLIShim.rcState((try? String(contentsOfFile: rc, encoding: .utf8)) ?? "") != .absent
                try CLIShim.uninstallRC(rc)
                if had { print("Removed the PATH line from \(rc).") }
            }
        case "doctor":
            let findings = CLIDoctor(profiles: profiles, keychain: keychain, rcFiles: CLICommands.rcFiles(env), resolve: CLIDoctor.zshResolve).run()
            for f in findings {
                let marker = switch f.level { case .ok: "[ok]     "; case .note: "[note]   "; case .warn: "[warn]   "; case .problem: "[problem]" }
                print("\(marker) \(f.message)")
            }
            exit(findings.contains { $0.level == .problem } ? 1 : 0)
        case "help", "-h", "--help":
            print(cliUsage)
        default:
            fail("unknown cli command \"\(sub)\"\n\n\(cliUsage)")
        }
    } catch {
        fail(error.localizedDescription)
    }
    exit(0)
}

/// `switcher cli usage`: every profile's quota, from the statusline file, Claude's usage endpoint,
/// `codex app-server` or Google Cloud Code. `--renew` asks Claude Code to renew an expired token.
func runCLIUsage(_ args: [String]) async -> Never {
    if args.contains("help") || args.contains("-h") || args.contains("--help") {
        print(cliUsage)
        exit(0)
    }
    var renew = false
    var asJSON = false
    var cachedOnly = false
    var positional: [String] = []
    for arg in args {
        if arg.hasPrefix("-") {
            switch arg {
            case "--renew": renew = true
            case "--json": asJSON = true
            case "--cached": cachedOnly = true; asJSON = true
            default: fail("unknown option \"\(arg)\"\n\n\(cliUsage)")
            }
        } else {
            positional.append(arg)
        }
    }
    if positional.count > 1 { fail("unexpected argument \"\(positional[1])\"\n\n\(cliUsage)") }
    let kinds: [CLIKind]
    if let first = positional.first {
        guard let k = CLICommands.kind(first) else { fail("say which CLI: claude, codex or agy") }
        kinds = [k]
    } else {
        kinds = CLIKind.allCases
    }

    let env = makeCLIEnv()
    let profiles = CLIProfiles(env: env)
    // `--cached`: the last readings only. No request, no process, no keychain.
    if cachedOnly {
        print(CLIUsageReport.build(profiles: profiles, kinds: kinds).json())
        exit(0)
    }
    let keychain = makeCLIKeychain()
    let cache = CLIQuotaCache(env: env)
    func say(_ line: String) { if !asJSON { print(line) } }
    var errors: [String: String] = [:]
    let fmt = DateFormatter()
    fmt.dateFormat = "MMM d HH:mm"
    let augmentedEnv = env.augmentedEnvironment()
    for kind in kinds {
        say(kind.displayName)
        let real = resolveRealBinary(kind, env: env)
        if kind == .codex, real == nil {
            let msg = "codex not found on PATH"
            say("  \(msg)")
            for p in profiles.list(kind) where profiles.signIn(p, keychain: keychain).state == .signedIn {
                errors[p.id] = msg
            }
            continue
        }
        for p in profiles.list(kind) {
            let id = profiles.identity(p, keychain: keychain)
            let accountKey = id?.accountKey
            let head = "  \(p.name)\(id?.email.map { " (\($0))" } ?? "")"
            func read() async throws -> CLIQuota {
                switch kind {
                case .claude:
                    try await ClaudeCodeQuota.read(profile: p, profiles: profiles, keychain: keychain, http: URLSessionHTTPGetter())
                case .codex:
                    try await CodexQuota.read(profile: p, codexBinary: real!, environment: augmentedEnv)
                case .agy:
                    try await AgyCLIQuota.read(profile: p, profiles: profiles, keychain: keychain)
                }
            }
            do {
                var q: CLIQuota
                do {
                    q = try await read()
                } catch CLIQuotaError.signInExpired where renew && kind == .claude {
                    guard let claudeBin = real else { throw CLIQuotaError.unavailable("claude not found on PATH for --renew") }
                    guard ClaudeCodeQuota.renewLogin(profile: p, claudeBinary: claudeBin, stateDir: env.config + "/renew", environment: augmentedEnv) else {
                        throw CLIQuotaError.signInExpired
                    }
                    q = try await read()
                }
                let updatedKey = profiles.identity(p, keychain: keychain)?.accountKey ?? accountKey
                try? cache.store(q, for: p, accountKey: updatedKey)
                say(head + "  [\(q.source)]")
                for w in q.windows {
                    say("    \(w.label): \(Int(w.usedPercent.rounded()))% used\(w.resetsAt.map { ", resets " + fmt.string(from: $0) } ?? "")")
                }
            } catch {
                errors[p.id] = error.localizedDescription
                say(head + "  ! \(error.localizedDescription)\(error as? CLIQuotaError == .signInExpired && kind == .claude ? " (try --renew)" : "")")
                if let old = cache.quota(for: p, accountKey: profiles.identity(p, keychain: keychain)?.accountKey) {
                    say("    last read \(ago(old.observedAt)): " + old.windows.map { "\($0.label) \(Int($0.usedPercent.rounded()))%" }.joined(separator: ", "))
                }
            }
        }
    }
    if asJSON {
        let now = Date()
        print(CLIUsageReport.build(
            profiles: profiles,
            kinds: kinds,
            now: now,
            keychain: keychain,
            signedIn: { p in
                let s = profiles.signIn(p, keychain: keychain)
                return s.state == .signedIn && (s.refreshExpiresAt.map { $0 > now } ?? true)
            },
            errors: errors
        ).json())
    }
    exit(0)
}

var args = Array(CommandLine.arguments.dropFirst())
let command = args.isEmpty ? "list" : args.removeFirst()
if command == "cli", args.first == "usage" { await runCLIUsage(Array(args.dropFirst())) }
if command == "cli" { runCLI(args) }
if command == "help" || command == "-h" || command == "--help" {
    print(usage)
    exit(0)
}

let board = Switchboard()

func who(_ p: ProviderID, _ q: String?) -> Slot {
    guard let q else { fail("say which account") }
    guard let slot = board.resolve(p, q) else { fail("no \(p.displayName) account matches \"\(q)\"") }
    return slot
}

func runSwitch(_ p: ProviderID, _ target: String?) {
    let name = board.provider(p).app.name
    do {
        let r = try board.switchTo(p, account: target, alwaysLaunch: false) { waited in
            if Int(waited) == 3 { print("Waiting for \(name) to quit. If it asks whether to quit, answer it there.") }
        }
        if let target {
            let label = Roster.load(board.env).slot(p, target)?.label ?? target
            print("\(name) is now signed in to \(label)\(r.launched ? "" : " (it will be when you open it)").")
        } else {
            print("\(name) is open on its sign-in page. Sign in to the account to add; the one you left is kept.")
        }
    } catch {
        fail(error.localizedDescription)
    }
}

do {
    board.recoverIfIdle()
    switch command {
    case "list", "ls", "accounts":
        let boards = board.board()
        if args.contains("--json") {
            let out = boards.map { b -> [String: Any] in
                [
                    "app": b.provider.rawValue, "installed": b.installed, "running": b.running, "current": b.current as Any,
                    "accounts": b.rows.map { r -> [String: Any] in
                        var d: [String: Any] = ["number": r.slot.number, "account": r.slot.account, "email": r.slot.email as Any,
                                                "alias": r.slot.alias as Any, "disabled": r.slot.disabled, "current": r.isCurrent, "canSwitch": r.canSwitch]
                        if let u = r.usage { d["usage"] = ["fiveHour": u.fiveHour as Any, "weekly": u.weekly as Any, "sampledAt": u.sampledAt.timeIntervalSince1970] }
                        return d
                    },
                ]
            }
            let data = try JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys])
            print(String(decoding: data, as: UTF8.self))
        } else {
            for b in boards {
                let state = !b.installed ? "not installed" : b.running ? "running" : "not running"
                print("\(b.provider.displayName) (\(state))")
                if b.rows.isEmpty { print("  no accounts yet: sign in once in the app") }
                for r in b.rows {
                    var line = "  \(r.isCurrent ? "●" : " ") \(r.slot.number). \(r.slot.label)"
                    if !r.isCurrent && !r.canSwitch { line += "  [sign in once to switch]" }
                    if r.probablyExpired { line += "  [may need signing in again]" }
                    if r.slot.disabled { line += "  [left out of Next]" }
                    print(line)
                }
                if b.interrupted { print("  a switch was cut short; it is finished or undone when \(b.provider.displayName) is quit") }
            }
            if let found = board.ccSameImport() {
                print("\nCC Same has \(found.logins.count) saved Claude sign-in(s): run `switcher import-cc-same`\(found.running ? " after quitting CC Same" : "").")
            }
        }
    case "switch", "sw":
        let p = app(args.first)
        if args.count > 1 {
            let slot = who(p, args[1])
            runSwitch(p, slot.account)
        } else {
            guard let next = board.nextAccount(p) else { fail("no other \(p.displayName) account has a saved sign-in yet") }
            runSwitch(p, next.account)
        }
    case "add":
        runSwitch(app(args.first), nil)
    case "remove", "rm":
        let p = app(args.first)
        let slot = who(p, args.dropFirst().first)
        try board.remove(p, account: slot.account)
        print("Removed \(slot.label).")
    case "alias":
        let p = app(args.first)
        let slot = who(p, args.dropFirst().first)
        guard args.count > 2 else { fail("say the alias, or - to clear it") }
        try Roster.edit(board.env) { try $0.setAlias(p, slot.account, args[2] == "-" ? nil : args[2]) }
    case "disable", "enable":
        let p = app(args.first)
        let slot = who(p, args.dropFirst().first)
        try Roster.edit(board.env) { $0.setDisabled(p, slot.account, command == "disable") }
    case "move":
        let p = app(args.first)
        let slot = who(p, args.dropFirst().first)
        guard args.count > 2, let n = Int(args[2]) else { fail("say the number") }
        try Roster.edit(board.env) { try $0.move(p, slot.account, to: n) }
    case "usage":
        // Antigravity: read every account's quota from Google now (Claude's numbers come from Claude).
        let quotas = await board.refreshAntigravityUsage()
        let roster = Roster.load(board.env)
        let names: [QuotaBucket.Pool: String] = [.gemini5h: "Gemini 5h", .geminiWeekly: "Gemini week", .argonWeekly: "Argon week", .claude5h: "Claude 5h", .claudeWeekly: "Claude week"]
        for (account, q) in quotas.sorted(by: { (roster.slot(.antigravity, $0.key)?.number ?? 99) < (roster.slot(.antigravity, $1.key)?.number ?? 99) }) {
            print("\(roster.slot(.antigravity, account)?.label ?? account)\(q.plan.map { "  (\($0))" } ?? "")")
            for b in q.buckets { print("    \(names[b.pool]!): \(b.used)% used\(b.resetsAt.map { "  resets \(ago(Date(timeIntervalSince1970: 2 * Date().timeIntervalSince1970 - $0.timeIntervalSince1970)).replacingOccurrences(of: " ago", with: "")) from now" } ?? "")") }
            if let p = q.problem { print("    ! \(p)") }
        }
        if quotas.isEmpty { print("No Antigravity account has a sign-in Switcher can read.") }
    case "import-cc-same":
        let r = try board.importCCSame()
        print("Imported \(r.logins) saved sign-in(s) and \(r.accounts) account(s) from CC Same.")
    default:
        fail("unknown command \"\(command)\"\n\n\(usage)")
    }
} catch {
    fail(error.localizedDescription)
}
