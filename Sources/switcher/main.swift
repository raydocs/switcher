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
  switcher cli ...                     Claude Code and Codex accounts per terminal: run `switcher cli help`

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
switcher cli: Claude Code and Codex accounts, chosen per new terminal session.

  switcher cli [list] [--json]         every profile, who it is signed in as, and which is active
  switcher cli use <cli> [<who>]       new claude/codex processes use this account (or the next)
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
  switcher cli usage [<cli>] [--renew] read each profile's quota now (--renew: let the CLI renew an expired sign-in)
  switcher cli usage [<cli>] --json    the same, as JSON (schema switcher.usage.v1), with headroom and the best account
  switcher cli usage [<cli>] --cached  the last readings as JSON: no request, no process, no keychain

<cli> is claude or codex (cc / co). <who> is a number (1 = the default account), a name, an email or default.
"""

/// A line from the terminal, trimmed; nil at end of input.
func ask(_ prompt: String) -> String? {
    print(prompt, terminator: "")
    fflush(stdout)
    return readLine()?.trimmingCharacters(in: .whitespaces)
}

/// Run the CLI's own sign-in inside `profile`'s folder, in this terminal, then say who it is
/// signed in as and (for a new account) offer to point new sessions at it.
func signIn(_ profile: CLIProfile, env: CLIEnv, profiles: CLIProfiles, createdNow: Bool, offerToUse: Bool, useWithoutAsking: Bool) -> Never {
    let kind = profile.kind
    guard let real = CLIShim.findRealBinary(kind, env: env) else {
        fail("no real \(kind.command) found on PATH; sign in later with:\n  \(kind.loginCommand(profile))")
    }
    print("Signing in a \(kind.displayName) account: finish in the browser that opens (Ctrl-C cancels)…\n")
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: real)
    proc.arguments = kind.loginArguments
    var environment = ProcessInfo.processInfo.environment
    for (v, value) in CLICommands.envEdits(profile) { environment[v] = value }
    proc.environment = environment
    // Ctrl-C belongs to the sign-in while it runs.
    signal(SIGINT, SIG_IGN)
    defer { signal(SIGINT, SIG_DFL) }
    do { try proc.run() } catch { fail("cannot run \(real): \(error.localizedDescription)") }
    proc.waitUntilExit()
    print("")
    let state = profiles.signIn(profile, keychain: LiveCLIKeychain()).state
    guard state != .signedOut else {
        if createdNow {
            try? profiles.discardUnsignedIn(profile, keychain: LiveCLIKeychain())
            print("Not signed in, so nothing was added. Run `switcher cli add \(kind.command)` to try again.")
        } else {
            print("Not signed in yet. Try again any time with:\n  switcher cli login \(kind.command) \(profile.name)")
        }
        exit(1)
    }
    let who = profiles.identity(profile)
    let label = [who?.email, who?.plan.map { "(\($0))" }].compactMap { $0 }.joined(separator: " ")
    print("✓ Signed in\(label.isEmpty ? "" : " as " + label) · account \(profile.name)")
    if let twin = profiles.duplicates(of: profile).first {
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
    let env = CLIEnv(home: ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory())
    let profiles = CLIProfiles(env: env)
    var args = args
    let sub = args.isEmpty ? "list" : args.removeFirst()

    func cli(_ s: String?) -> CLIKind {
        guard let k = CLICommands.kind(s) else { fail("say which CLI: claude or codex (cc / co)") }
        return k
    }

    do {
        switch sub {
        case "list", "ls":
            let groups = CLICommands.list(profiles, keychain: LiveCLIKeychain())
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
                target = try CLICommands.profile(profiles, kind, args[1])
            } else {
                guard let next = profiles.next(kind) else { fail("no other \(kind.displayName) profile yet: `switcher cli add \(kind.command) <name>`") }
                target = next
            }
            try profiles.setActive(target)
            let email = profiles.identity(target)?.email
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
                let answer = ask("Add which account? 1 Claude Code, 2 Codex [1]: ") ?? ""
                guard let k = answer.isEmpty ? .claude : (answer == "2" ? .codex : (answer == "1" ? .claude : CLICommands.kind(answer))) else { fail("say claude or codex") }
                kind = k
            } else {
                kind = cli(rest.first)
            }
            let name = rest.first ?? profiles.suggestedName(kind)
            // An account that exists but is not signed in is signed in, not added again.
            if let existing = profiles.list(kind).first(where: { $0.name.lowercased() == name.lowercased() }) {
                guard profiles.signIn(existing, keychain: LiveCLIKeychain()).state == .signedOut else {
                    let email = profiles.identity(existing)?.email
                    fail("\(existing.name) is already signed in\(email.map { " as \($0)" } ?? ""); `switcher cli add \(kind.command)` adds another")
                }
                guard tty, !flags.contains("--no-login") else { print("Sign it in with:\n  \(kind.loginCommand(existing))"); exit(0) }
                signIn(existing, env: env, profiles: profiles, createdNow: false, offerToUse: true, useWithoutAsking: flags.contains("--use"))
            }
            let p = try profiles.add(kind, name: name)
            guard tty, !flags.contains("--no-login") else {
                print("Created \(p.path)")
                print("Sign it in with:\n  \(kind.loginCommand(p))")
                exit(0)
            }
            signIn(p, env: env, profiles: profiles, createdNow: true, offerToUse: true, useWithoutAsking: flags.contains("--use"))
        case "login":
            let kind = cli(args.first)
            let p = args.count > 1 ? try CLICommands.profile(profiles, kind, args[1]) : profiles.active(kind)
            signIn(p, env: env, profiles: profiles, createdNow: false, offerToUse: false, useWithoutAsking: false)
        case "remove", "rm":
            let kind = cli(args.first)
            let rest = args.dropFirst().filter { !$0.hasPrefix("--") }
            guard let who = rest.first else { fail("say which account: a number, a name or an email") }
            let p = try CLICommands.profile(profiles, kind, who)
            guard !p.isDefault else { fail("the default account stays (it is \(env.defaultFolder(kind)))") }
            let email = profiles.identity(p)?.email
            let label = p.name + (email.map { " (\($0))" } ?? "")
            if !args.contains("--yes") {
                guard isatty(0) == 1 else { fail("add --yes to remove \(label) without asking") }
                let answer = ask("Sign \(label) out and move its folder to the Trash? Shared sessions and settings stay. [y/N] ")?.lowercased() ?? ""
                guard answer.hasPrefix("y") else { print("Nothing was removed."); exit(0) }
            }
            if profiles.signIn(p, keychain: LiveCLIKeychain()).state != .signedOut, let real = CLIShim.findRealBinary(kind, env: env) {
                let run = CLILoginRun(profile: p, binary: real, arguments: kind.logoutArguments)
                try run.start()
                run.wait()
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
            let profile = try CLICommands.profile(profiles, req.kind, req.who)
            var argv = req.command
            if argv.isEmpty {
                // The real binary, so the shim is not involved.
                guard let real = CLIShim.findRealBinary(req.kind, env: env) else { fail("no real \(req.kind.command) found on PATH") }
                argv = [real]
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
            CLIShim.uninstallShims(env: env)
            print("Removed the shims from \(env.shimDir).")
            for rc in CLICommands.rcFiles(env) {
                let had = CLIShim.rcState((try? String(contentsOfFile: rc, encoding: .utf8)) ?? "") != .absent
                try CLIShim.uninstallRC(rc)
                if had { print("Removed the PATH line from \(rc).") }
            }
        case "doctor":
            let findings = CLIDoctor(profiles: profiles, keychain: LiveCLIKeychain(), rcFiles: CLICommands.rcFiles(env), resolve: CLIDoctor.zshResolve).run()
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

/// `switcher cli usage`: every profile's quota, from the statusline file, Claude's usage endpoint
/// or `codex app-server`. Never refreshes a token itself; `--renew` asks the CLI to.
func runCLIUsage(_ args: [String]) async -> Never {
    let env = CLIEnv(home: ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory())
    let profiles = CLIProfiles(env: env)
    let keychain = LiveCLIKeychain()
    let cache = CLIQuotaCache(env: env)
    let kinds = args.first.flatMap(CLICommands.kind).map { [$0] } ?? CLIKind.allCases
    let renew = args.contains("--renew")
    let asJSON = args.contains("--json") || args.contains("--cached")
    // `--cached`: the last readings only. No request, no process, no keychain.
    if args.contains("--cached") {
        print(CLIUsageReport.build(profiles: profiles, kinds: kinds).json())
        exit(0)
    }
    func say(_ line: String) { if !asJSON { print(line) } }
    var errors: [String: String] = [:]
    let fmt = DateFormatter()
    fmt.dateFormat = "MMM d HH:mm"
    for kind in kinds {
        say(kind.displayName)
        guard let real = CLIShim.findRealBinary(kind, env: env) else { say("  \(kind.command) not found"); continue }
        for p in profiles.list(kind) {
            let accountKey = profiles.identity(p)?.accountKey
            let head = "  \(p.name)\(profiles.identity(p)?.email.map { " (\($0))" } ?? "")"
            func read() async throws -> CLIQuota {
                switch kind {
                case .claude: try await ClaudeCodeQuota.read(profile: p, profiles: profiles, keychain: keychain, http: URLSessionHTTPGetter())
                case .codex: try await CodexQuota.read(profile: p, codexBinary: real)
                }
            }
            do {
                var q: CLIQuota
                do { q = try await read() } catch CLIQuotaError.signInExpired where renew && kind == .claude {
                    guard ClaudeCodeQuota.renewLogin(profile: p, claudeBinary: real, stateDir: env.config + "/renew") else { throw CLIQuotaError.signInExpired }
                    q = try await read()
                }
                try? cache.store(q, for: p, accountKey: accountKey)
                say(head + "  [\(q.source)]")
                for w in q.windows {
                    say("    \(w.label): \(Int(w.usedPercent.rounded()))% used\(w.resetsAt.map { ", resets " + fmt.string(from: $0) } ?? "")")
                }
            } catch {
                errors[p.id] = error.localizedDescription
                say(head + "  ! \(error.localizedDescription)\(error as? CLIQuotaError == .signInExpired && kind == .claude ? " (try --renew)" : "")")
                if let old = cache.quota(for: p, accountKey: profiles.identity(p)?.accountKey) { say("    last read \(ago(old.observedAt)): " + old.windows.map { "\($0.label) \(Int($0.usedPercent.rounded()))%" }.joined(separator: ", ")) }
            }
        }
    }
    if asJSON {
        print(CLIUsageReport.build(profiles: profiles, kinds: kinds, signedIn: { profiles.signIn($0, keychain: keychain).state == .signedIn }, errors: errors).json())
    }
    exit(0)
}

let board = Switchboard()
var args = Array(CommandLine.arguments.dropFirst())
let command = args.isEmpty ? "list" : args.removeFirst()
if command == "cli", args.first == "usage" { await runCLIUsage(Array(args.dropFirst())) }
if command == "cli" { runCLI(args) }

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
    case "help", "-h", "--help":
        print(usage)
    default:
        fail("unknown command \"\(command)\"\n\n\(usage)")
    }
} catch {
    fail(error.localizedDescription)
}
