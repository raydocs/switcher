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

let board = Switchboard()
var args = Array(CommandLine.arguments.dropFirst())
let command = args.isEmpty ? "list" : args.removeFirst()

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
