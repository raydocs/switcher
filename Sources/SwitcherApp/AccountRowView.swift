import SwiftUI
import SwitcherCore

/// Words the views share, next to `L.t`.
extension L {
    static var fiveHour: String { "5h" }
    static var week: String { t("Week", "本周") }

    /// "35m", "2h", "3d": a length of time, rounded to one unit.
    static func span(_ seconds: TimeInterval) -> String {
        let m = max(1, Int(seconds / 60))
        if m < 60 { return t("\(m)m", "\(m) 分钟") }
        let h = m / 60
        if h < 48 { return t("\(h)h", "\(h) 小时") }
        return t("\(h / 24)d", "\(h / 24) 天")
    }

    static func ago(_ date: Date, now: Date = Date()) -> String {
        let s = span(now.timeIntervalSince(date))
        return t("\(s) ago", "\(s)前")
    }

    static func resets(_ date: Date, now: Date = Date()) -> String {
        let left = date.timeIntervalSince(now)
        if left <= 0 { return t("resets now", "即将重置") }
        let s = span(left)
        return t("resets in \(s)", "将在 \(s)后重置")
    }

    static var removeExplained: String {
        t("Switcher forgets its saved sign-in on this Mac. The account itself is not affected.",
          "Switcher 会删除它保存在这台 Mac 上的登录，账号本身不受影响。")
    }

    static func poolName(_ pool: QuotaBucket.Pool) -> String {
        switch pool {
        case .gemini5h: "Gemini " + fiveHour
        case .geminiWeekly: "Gemini " + week
        case .claude5h: "Claude " + fiveHour
        case .claudeWeekly: "Claude " + week
        case .argonWeekly: "Argon " + week
        }
    }
}

/// One account: click to switch, right-click (or the ellipsis on hover) to rename, sit out or remove.
struct AccountRowView: View {
    let model: AppModel
    let provider: ProviderID
    let row: AccountRow
    let index: Int
    @Binding var removing: String?
    @Binding var renaming: String?
    var isBest = false
    var forcedHover = false

    @State private var hovering = false
    @State private var draftAlias = ""
    @FocusState private var focused: Bool
    @FocusState private var aliasFocused: Bool
    @Environment(\.staticRender) private var staticRender

    private var app: String { provider.displayName }
    private var display: (title: String, subtitle: String?) { model.displayLabel(row.slot) }
    private var switchable: Bool { row.canSwitch && !row.isCurrent }
    private var highlighted: Bool { hovering || forcedHover || focused }
    private var isTarget: Bool { model.job?.provider == provider && model.job?.target == row.id }
    private var sitsOut: Bool { row.slot.disabled }
    private var matchingCLIQuota: CLIQuota? {
        provider == .claude ? model.matchingCLIQuota(forDesktopEmail: row.slot.email) : nil
    }
    private var showSavedAge: Bool {
        provider == .claude && !row.isCurrent && row.canSwitch && !row.probablyExpired && row.setAsideAt != nil
    }
    private var hasDetail: Bool {
        display.subtitle != nil || row.quota != nil || matchingCLIQuota != nil || showSavedAge || !row.canSwitch || row.probablyExpired
    }

    var body: some View {
        Group {
            if removing == row.id {
                removeConfirm
            } else if renaming == row.id {
                renameForm
            } else {
                normal
            }
        }
        .opacity(model.isBusy && !isTarget ? 0.4 : 1)
    }

    // MARK: The row

    private var normal: some View {
        Button {
            model.switchTo(provider, row)
        } label: {
            HStack(alignment: hasDetail ? .top : .center, spacing: Metrics.avatarGap) {
                Avatar(label: display.title, seed: row.id)
                VStack(alignment: .leading, spacing: 5) {
                    VStack(alignment: .leading, spacing: 1) {
                        titleLine
                        if let subtitle = display.subtitle {
                            Text(subtitle)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    if provider == .antigravity, let quota = row.quota {
                        AntigravityQuotaLines(quota: quota, mode: model.quotaDisplayMode)
                    } else if let cliQuota = matchingCLIQuota {
                        ClaudeCLIReferenceLine(quota: cliQuota, mode: model.quotaDisplayMode)
                    }
                    if !row.canSwitch && !row.isCurrent {
                        Note(symbol: "info.circle", text: L.t(
                            "No saved sign-in yet. Choose Add Account and sign in to it once.",
                            "还没有保存它的登录。点“添加账号…”登录一次后即可切换。"))
                    } else if row.probablyExpired {
                        Note(symbol: "exclamationmark.circle", text: L.t(
                            "This sign-in may have expired. \(app) may ask you to sign in again.",
                            "这个登录可能已过期，切换后 \(app) 可能要求重新登录。"), tint: .orange)
                    } else if showSavedAge, let savedAt = row.setAsideAt {
                        let ageDays = Date().timeIntervalSince(savedAt) / 86400
                        let nearExpiry = ageDays >= 24
                        HStack(spacing: 4) {
                            if nearExpiry {
                                Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
                            }
                            Text(L.t("Saved \(L.ago(savedAt))", "保存于\(L.ago(savedAt))"))
                                .foregroundStyle(nearExpiry ? .secondary : .tertiary)
                        }
                        .font(.subheadline)
                        .lineLimit(1)
                        .help(nearExpiry
                            ? L.t("Saved sign-ins usually expire after ~28 days without use.", "长期未使用的保存登录通常在约 28 天后过期。")
                            : "")
                    }
                }
                .opacity(sitsOut && !row.isCurrent ? 0.55 : 1)
            }
            .padding(.horizontal, Metrics.rowH)
            .padding(.vertical, Metrics.rowV)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(RowButtonStyle(highlighted: highlighted && switchable, current: row.isCurrent, focused: focused))
        .disabled(!switchable)
        .focused($focused)
        .focusEffectDisabled()
        .onHover { hovering = $0 }
        .overlay(alignment: .topTrailing) {
            if (hovering || forcedHover) && !model.isBusy {
                moreMenu
                    .padding(.trailing, Metrics.rowH)
                    .padding(.top, Metrics.rowV)
            }
        }
        .contextMenu { if !model.isBusy { menuItems } }
        .help(switchable ? L.t("Switch \(app) to \(display.title)", "将 \(app) 切换到 \(display.title)") : "")
        .accessibilityLabel(display.title)
        .accessibilityValue(row.isCurrent ? L.t("Current account", "当前账号") : "")
    }

    private var titleLine: some View {
        HStack(spacing: 6) {
            Text(display.title)
                .font(.body.weight(row.isCurrent ? .semibold : .medium))
                .foregroundStyle(row.canSwitch || row.isCurrent ? .primary : .secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(1)
            if let plan = row.quota?.plan {
                Tag(text: plan.replacingOccurrences(of: "Google AI ", with: ""))
                    .help(plan)
            }
            if sitsOut {
                Tag(text: L.t("Skipped", "已跳过"))
                    .help(L.t("Next Account skips this one. Clicking it still switches.", "“下一个账号”会跳过它，点击仍可切换。"))
            }
            Spacer(minLength: 4)
            trailing
            if (hovering || forcedHover) && !model.isBusy {
                // Room for the ellipsis menu laid over the row.
                Color.clear.frame(width: 16, height: 1)
            }
        }
    }

    @ViewBuilder private var trailing: some View {
        if isTarget {
            Spinner(size: 12)
        } else if row.isCurrent {
            HStack(spacing: 3) {
                Image(systemName: "checkmark").font(.caption2.weight(.bold))
                Text(L.t("Current", "当前")).font(.subheadline.weight(.medium))
            }
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Fill.tint, in: Capsule())
            .fixedSize()
        } else if switchable && highlighted {
            HStack(spacing: 3) {
                Text(L.t("Switch", "切换"))
                Image(systemName: "arrow.right")
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(Color.accentColor)
            .fixedSize()
        } else if isBest && switchable {
            HStack(spacing: 4) {
                Image(systemName: "arrow.right.circle.fill").foregroundStyle(.green)
                Text(L.t("Most room", "余量最多")).foregroundStyle(.secondary)
            }
            .font(.subheadline.weight(.medium))
            .fixedSize()
            .help(L.t("The current account is nearly out; this one has the most quota left.",
                      "当前账号配额快用完了，这个账号余量最多。"))
        } else if switchable && index < 9 {
            Text("⌘\(index + 1)")
                .font(.subheadline)
                .monospacedDigit()
                .foregroundStyle(.tertiary)
                .fixedSize()
        }
    }

    // MARK: Menu

    @ViewBuilder private var moreMenu: some View {
        let glyph = Image(systemName: "ellipsis.circle").font(.body).foregroundStyle(.secondary)
        if staticRender {
            glyph
        } else {
            Menu { menuItems } label: { glyph }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help(L.t("More", "更多"))
        }
    }

    @ViewBuilder private var menuItems: some View {
        Button(L.t("Rename…", "设别名…")) {
            draftAlias = row.slot.alias ?? ""
            removing = nil
            renaming = row.id
        }
        Button(sitsOut ? L.t("Include in Next Account", "恢复参与“下一个账号”") : L.t("Sit Out of Next Account", "不参与“下一个账号”")) {
            model.setDisabled(provider, row.id, !sitsOut)
        }
        Divider()
        Button(L.t("Remove…", "移除…"), role: .destructive) {
            renaming = nil
            removing = row.id
        }
        .disabled(row.isCurrent)
    }

    private var renameForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: Metrics.avatarGap) {
                Avatar(label: display.title, seed: row.id)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L.t("Set alias", "设置别名"))
                        .font(.body.weight(.semibold))
                    if let email = model.displayEmail(row.slot.email) {
                        Text(email)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
            if staticRender {
                let shown = draftAlias.isEmpty ? (row.slot.alias ?? "") : draftAlias
                Text(shown.isEmpty ? L.t("e.g. work, personal", "例如：工作、个人") : shown)
                    .font(.body)
                    .foregroundStyle(shown.isEmpty ? .tertiary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Fill.hover, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            } else {
                TextField(L.t("e.g. work, personal", "例如：工作、个人"), text: $draftAlias)
                    .textFieldStyle(.roundedBorder)
                    .focused($aliasFocused)
                    .onSubmit { saveAlias() }
            }
            HStack(spacing: 6) {
                if row.slot.alias != nil {
                    Button(L.t("Clear", "清除")) {
                        model.setAlias(provider, row.id, nil)
                        renaming = nil
                    }
                    .buttonStyle(QuietButtonStyle())
                    .font(.subheadline)
                }
                Spacer()
                Button(L.t("Cancel", "取消")) { renaming = nil }
                    .buttonStyle(SoftButtonStyle(compact: true))
                    .keyboardShortcut(.cancelAction)
                Button(L.t("Save", "保存")) { saveAlias() }
                    .buttonStyle(SoftButtonStyle(kind: .tinted, compact: true))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, Metrics.rowH)
        .padding(.vertical, Metrics.rowV)
        .background(Fill.card, in: RoundedRectangle(cornerRadius: Metrics.radius, style: .continuous))
        .onAppear {
            if draftAlias.isEmpty { draftAlias = row.slot.alias ?? "" }
            if !staticRender { aliasFocused = true }
        }
    }

    private func saveAlias() {
        let trimmed = draftAlias.trimmingCharacters(in: .whitespacesAndNewlines)
        model.setAlias(provider, row.id, trimmed.isEmpty ? nil : trimmed)
        renaming = nil
    }

    private var removeConfirm: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: Metrics.avatarGap) {
                Avatar(label: display.title, seed: row.id)
                VStack(alignment: .leading, spacing: 3) {
                    Text(L.t("Remove \(display.title)?", "移除 \(display.title)？"))
                        .font(.body.weight(.semibold))
                        .lineLimit(2)
                    Text(L.removeExplained)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 6) {
                Spacer()
                Button(L.t("Cancel", "取消")) { removing = nil }
                    .buttonStyle(SoftButtonStyle(compact: true))
                    .keyboardShortcut(.cancelAction)
                Button(L.t("Remove", "移除")) {
                    model.remove(provider, row.id)
                    removing = nil
                }
                .buttonStyle(SoftButtonStyle(kind: .destructive, compact: true))
            }
        }
        .padding(.horizontal, Metrics.rowH)
        .padding(.vertical, Metrics.rowV)
        .background(Fill.card, in: RoundedRectangle(cornerRadius: Metrics.radius, style: .continuous))
    }
}

/// A small neutral capsule: the plan, "Skipped".
struct Tag: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Fill.card, in: Capsule())
            .fixedSize()
    }
}

/// An Antigravity account's quota, in the same meters as CLI usage: Gemini as the main pair,
/// Claude-in-Antigravity dimmer under it (both with weekly pace marks), then Argon (when used > 0)
/// and the next reset as one quiet line.
struct AntigravityQuotaLines: View {
    let quota: AntigravityQuota
    var mode: QuotaDisplayMode = .used

    private static let labelWidth: CGFloat = 38

    /// The fullest pool that says when it resets: the one worth waiting for.
    private var nextReset: QuotaBucket? {
        quota.buckets.filter { $0.resetsAt != nil && $0.used > 0 }.max { $0.used < $1.used }
    }

    private var isStale: Bool { Date().timeIntervalSince(quota.fetchedAt) > 30 * 60 }

    private var hasWeeklyPace: Bool {
        [quota.bucket(.geminiWeekly), quota.bucket(.claudeWeekly)].contains { $0?.pace() != nil }
    }

    private var detail: String {
        let suffix = mode == .used ? L.t(" used", " 已用") : L.t(" left", " 剩余")
        var lines = quota.buckets.map { b in
            let shown = mode.shownPercent(used: b.used)
            return "\(L.poolName(b.pool)): \(shown)%\(suffix)" + (b.resetsAt.map { ", " + L.resets($0) } ?? "")
        }
        if hasWeeklyPace {
            lines.append(mode == .used
                ? L.t("The mark on \(L.week) is an even pace: use past it runs out before the reset.",
                      "“\(L.week)”上的刻度是匀速使用的位置：超过它，会在重置前用完。")
                : L.t("The mark on \(L.week) is an even pace: remaining below it runs out before the reset.",
                      "“\(L.week)”上的刻度是匀速使用的余量基准：低于它，会在重置前用完。"))
        }
        lines.append(L.t("Read \(L.ago(quota.fetchedAt))", "读取于\(L.ago(quota.fetchedAt))"))
        return lines.joined(separator: "\n")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            pair("Gemini", quota.bucket(.gemini5h), quota.bucket(.geminiWeekly), warning: quota.problem)
            if quota.bucket(.claude5h) != nil || quota.bucket(.claudeWeekly) != nil {
                pair("Claude", quota.bucket(.claude5h), quota.bucket(.claudeWeekly), warning: nil)
                    .opacity(0.75)
            }
            footnote
        }
        .opacity(isStale ? 0.75 : 1)
        .help(detail)
    }

    private func pair(_ name: String, _ five: QuotaBucket?, _ weekly: QuotaBucket?, warning: String?) -> some View {
        let weeklyPace = weekly?.pace().map { Int($0.rounded()) }
        return HStack(spacing: 8) {
            Text(name)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(width: Self.labelWidth, alignment: .leading)
                .padding(.trailing, -4)
            UsageMeter(title: L.fiveHour, name: name + " " + L.fiveHour, percent: five?.used, mode: mode)
            UsageMeter(title: L.week, name: name + " " + L.week, percent: weekly?.used, pace: weeklyPace, mode: mode)
            Spacer(minLength: 0)
            if let warning {
                Image(systemName: "exclamationmark.triangle")
                    .font(.subheadline)
                    .foregroundStyle(.orange)
                    .help(L.t("The last quota read failed; these are the previous numbers.\n\(warning)",
                              "上次读取配额失败，显示的是之前的数字。\n\(warning)"))
                    .accessibilityLabel(L.t("Quota read failed", "配额读取失败"))
            }
        }
    }

    @ViewBuilder private var footnote: some View {
        let argon = quota.bucket(.argonWeekly).flatMap { $0.used > 0 ? $0 : nil }
        let reset = nextReset
        if argon != nil || reset != nil || isStale {
            HStack(spacing: 10) {
                if let argon {
                    let shown = mode.shownPercent(used: argon.used)
                    HStack(spacing: 4) {
                        Text("Argon").frame(width: Self.labelWidth, alignment: .leading)
                        Text(L.week)
                        Text("\(shown)%")
                            .monospacedDigit()
                            .foregroundStyle(argon.used >= 90 ? AnyShapeStyle(Color.red) : AnyShapeStyle(.secondary))
                    }
                    .opacity(0.75)
                }
                Spacer(minLength: 0)
                if isStale {
                    Text(L.ago(quota.fetchedAt)).foregroundStyle(.tertiary)
                } else if let reset, let at = reset.resetsAt {
                    Text(L.poolName(reset.pool) + " " + L.resets(at)).foregroundStyle(.tertiary)
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
    }
}

/// Quiet reference usage bar on a Claude Desktop row when a Claude Code CLI account shares the same email.
struct ClaudeCLIReferenceLine: View {
    let quota: CLIQuota
    var mode: QuotaDisplayMode = .used

    private var windows: [CLIQuotaWindow] {
        let main = ["5h", "week"].compactMap { label in quota.windows.first { $0.label == label } }
        return main.isEmpty ? Array(quota.windows.prefix(2)) : main
    }

    private func pace(_ w: CLIQuotaWindow) -> Int? {
        guard w.label == "week" || CLIUsage.duration(w) == 7 * 86400 else { return nil }
        return CLIUsage.pace(w, now: Date()).map { Int($0.rounded()) }
    }

    var body: some View {
        HStack(spacing: 8) {
            ForEach(windows, id: \.label) { w in
                UsageMeter(
                    title: L.cliWindow(w.label),
                    name: "Claude " + L.cliWindow(w.label),
                    percent: Int(w.usedPercent.rounded()),
                    pace: pace(w),
                    mode: mode
                )
            }
            Spacer(minLength: 0)
            Tag(text: "CLI")
        }
        .opacity(0.85)
        .help(L.t(
            "Reference usage from the Claude Code account with the same email (read \(L.ago(quota.observedAt))).",
            "参考用量：来自同邮箱的 Claude Code 账号（读取于\(L.ago(quota.observedAt))）。"))
    }
}
