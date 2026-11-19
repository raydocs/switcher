import SwiftUI
import SwitcherCore

/// Settings → Terminal & Doctor: manage PATH shims, repair shared links, and run `CLIDoctor` in-app.
struct TerminalDoctorSettings: View {
    let model: AppModel
    private let staged: SettingsPage.Staged
    @State private var confirmingUninstall: Bool
    @Environment(\.staticRender) private var staticRender

    init(model: AppModel, staged: SettingsPage.Staged = .init()) {
        self.model = model
        self.staged = staged
        _confirmingUninstall = State(initialValue: staged.confirmUninstallShims)
    }

    private var problemCount: Int { model.doctorFindings.filter { $0.level == .problem }.count }
    private var warnCount: Int { model.doctorFindings.filter { $0.level == .warn }.count }
    private var noteCount: Int { model.doctorFindings.filter { $0.level == .note }.count }

    private var summaryText: String? {
        guard !model.doctorFindings.isEmpty else { return nil }
        if problemCount == 0 && warnCount == 0 {
            return L.t("All checks passed", "全部检查通过")
        }
        var parts: [String] = []
        if problemCount > 0 {
            parts.append(problemCount == 1 ? L.t("1 problem", "1 个问题") : L.t("\(problemCount) problems", "\(problemCount) 个问题"))
        }
        if warnCount > 0 {
            parts.append(warnCount == 1 ? L.t("1 warning", "1 个警告") : L.t("\(warnCount) warnings", "\(warnCount) 个警告"))
        }
        if noteCount > 0 {
            parts.append(noteCount == 1 ? L.t("1 note", "1 条提示") : L.t("\(noteCount) notes", "\(noteCount) 条提示"))
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.settingsGap) {
            setupSection
            doctorSection
        }
        .onAppear {
            if !staticRender {
                model.refreshTerminalStatus()
                if model.doctorFindings.isEmpty && !model.runningDoctor {
                    model.runDoctor()
                }
            }
        }
    }

    // MARK: Shell setup & actions

    private var setupSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader(
                symbol: "terminal",
                title: L.t("Shell setup", "终端环境"),
                detail: L.t("PATH shims & shell config", "PATH 启动器与 Shell 配置")
            )
            SettingsCard {
                if let status = model.terminalStatus {
                    ForEach(Array(status.shims.enumerated()), id: \.element.id) { index, shim in
                        if index > 0 { RowDivider() }
                        shimRow(shim)
                    }
                    ForEach(status.rcFiles) { rc in
                        RowDivider()
                        rcRow(rc)
                    }
                } else {
                    HStack(spacing: 8) {
                        Spinner(size: 12)
                        Text(L.t("Checking terminal setup…", "正在检查终端环境…"))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .padding(Metrics.cardPad)
                }
                RowDivider()
                if confirmingUninstall {
                    uninstallConfirm
                } else {
                    actionBar
                }
            }
        }
    }

    private func shimRow(_ info: TerminalSetupStatus.ShimInfo) -> some View {
        let home = NSHomeDirectory()
        let displayPath = info.realBinary.map { Privacy.redactDiagnostic($0, home: home) }
        return HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(info.kind.displayName)
                        .font(.body.weight(.medium))
                    Text(verbatim: info.kind.command)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                if let displayPath {
                    Text(displayPath)
                        .font(.subheadline.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Text(L.cliNotFound(info.kind))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            statusBadge(
                ok: info.shimInstalled,
                label: info.shimInstalled
                    ? L.t("Shim active", "已启用")
                    : (info.realBinary != nil ? L.t("Not installed", "未安装") : L.t("Not found", "未找到")),
                warn: !info.shimInstalled && info.realBinary != nil
            )
        }
        .padding(Metrics.cardPad)
    }

    private func rcRow(_ info: TerminalSetupStatus.RCInfo) -> some View {
        let shortPath = Privacy.redactDiagnostic(info.path, home: NSHomeDirectory())
        let label: String
        let ok: Bool
        let warn: Bool
        switch info.state {
        case .last:
            label = L.t("Configured", "已配置")
            ok = true
            warn = false
        case .notLast:
            label = L.t("Not at end", "不在末尾")
            ok = false
            warn = true
        case .absent:
            label = L.t("Not added", "未写入")
            ok = false
            warn = false
        }
        return HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(shortPath)
                    .font(.body.monospaced())
                Text(info.state == .notLast
                    ? L.t("Lines after Switcher's PATH block may shadow the shims.", "Switcher 的 PATH 配置后面还有其他行，可能会覆盖启动器。")
                    : L.t("Shell startup file checked by Switcher.", "Switcher 维护的 Shell 启动文件。"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            statusBadge(ok: ok, label: label, warn: warn)
        }
        .padding(Metrics.cardPad)
    }

    private func statusBadge(ok: Bool, label: String, warn: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: ok ? "checkmark.circle.fill" : (warn ? "exclamationmark.triangle.fill" : "circle"))
                .foregroundStyle(ok ? AnyShapeStyle(Color.green) : (warn ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.tertiary)))
            Text(label)
                .foregroundStyle(ok ? .primary : .secondary)
        }
        .font(.subheadline.weight(.medium))
        .fixedSize()
    }

    private var actionBar: some View {
        HStack(spacing: 8) {
            Button(L.t("Install / Reinstall Shims", "安装 / 重装 Shim")) {
                model.installCLIShims()
            }
            .buttonStyle(SoftButtonStyle(kind: .tinted, compact: true))
            Button(L.t("Fix Shared Links", "修复共享软链")) {
                model.repairCLILinks()
            }
            .buttonStyle(SoftButtonStyle(compact: true))
            .help(L.t("Creates any missing shared settings or history links in secondary CLI profiles without overwriting existing files.",
                      "为所有非默认 CLI 账号补全缺失的共享配置与会话软链，绝不覆盖已有文件。"))
            Spacer()
            if model.terminalStatus?.shims.contains(where: \.shimInstalled) == true {
                Button(L.t("Uninstall…", "卸载…")) {
                    confirmingUninstall = true
                }
                .buttonStyle(QuietButtonStyle())
                .font(.subheadline)
            }
        }
        .padding(Metrics.cardPad)
    }

    private var uninstallConfirm: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L.t("Remove Switcher's terminal shims?", "移除 Switcher 的终端启动器？"))
                .font(.body.weight(.semibold))
            Text(L.t("Removes the PATH shims and the Switcher block from ~/.zshrc / ~/.bashrc. Your CLI accounts, sessions and sign-ins are never touched.",
                     "会移除 PATH 启动器以及 ~/.zshrc / ~/.bashrc 中由 Switcher 写入的配置段。所有 CLI 账号、会话和登录均不受影响。"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Spacer()
                Button(L.t("Cancel", "取消")) { confirmingUninstall = false }
                    .buttonStyle(SoftButtonStyle(compact: true))
                    .keyboardShortcut(.cancelAction)
                Button(L.t("Uninstall", "确认卸载")) {
                    confirmingUninstall = false
                    model.uninstallCLIShims()
                }
                .buttonStyle(SoftButtonStyle(kind: .destructive, compact: true))
            }
        }
        .padding(Metrics.cardPad)
    }

    // MARK: Doctor diagnostics

    private var doctorSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader(
                symbol: "stethoscope",
                title: L.t("Diagnostics", "环境诊断"),
                detail: summaryText
            ) {
                HStack(spacing: 6) {
                    Button {
                        model.copyDoctorReport()
                    } label: {
                        Label(L.t("Copy Report", "复制脱敏报告"), systemImage: "doc.on.doc")
                    }
                    .buttonStyle(SoftButtonStyle(compact: true))
                    .disabled(model.doctorFindings.isEmpty)
                    .help(L.t("Copies a redacted diagnostic report (home path replaced with ~, emails masked).",
                              "复制脱敏后的诊断报告（自动将主目录替换为 ~ 并隐藏邮箱）。"))

                    Button {
                        model.runDoctor()
                    } label: {
                        if model.runningDoctor {
                            HStack(spacing: 4) {
                                Spinner(size: 10)
                                Text(L.t("Checking…", "检测中…"))
                            }
                        } else {
                            Label(L.t("Re-run", "重新检测"), systemImage: "arrow.clockwise")
                        }
                    }
                    .buttonStyle(SoftButtonStyle(kind: .tinted, compact: true))
                    .disabled(model.runningDoctor)
                }
            }
            SettingsCard {
                if model.runningDoctor && model.doctorFindings.isEmpty {
                    HStack(spacing: 8) {
                        Spinner(size: 12)
                        Text(L.t("Checking shims, shells, shared links and sign-ins…",
                                 "正在检查启动器、Shell 配置、共享软链与登录状态…"))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .padding(Metrics.cardPad)
                } else if model.doctorFindings.isEmpty {
                    EmptyState(
                        symbol: "stethoscope",
                        title: L.t("No diagnostics run yet", "尚未运行诊断"),
                        text: L.t("Run diagnostics to check shims, PATH precedence, shared links, and sign-in expiry.",
                                  "运行诊断以检查启动器、PATH 优先级、共享软链与登录有效期。"))
                } else {
                    ForEach(Array(model.doctorFindings.enumerated()), id: \.offset) { index, finding in
                        if index > 0 { RowDivider(inset: Metrics.cardPad + 24) }
                        findingRow(finding)
                    }
                }
            }
            if let lastRun = model.doctorLastRun {
                Text(L.t("Last checked \(L.ago(lastRun)). Tokens are never printed or copied.",
                         "上次检测于\(L.ago(lastRun))。诊断过程绝不输出或复制任何令牌。"))
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, Metrics.cardPad)
            }
        }
    }

    private func findingRow(_ finding: DoctorFinding) -> some View {
        let icon: String
        let tint: Color
        switch finding.level {
        case .ok:
            icon = "checkmark.circle.fill"
            tint = .green
        case .note:
            icon = "info.circle"
            tint = .secondary
        case .warn:
            icon = "exclamationmark.triangle.fill"
            tint = .orange
        case .problem:
            icon = "xmark.octagon.fill"
            tint = .red
        }
        let message = model.hideEmails
            ? Privacy.redactDiagnostic(finding.message, home: NSHomeDirectory())
            : finding.message.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon)
                .font(.callout)
                .foregroundStyle(tint)
                .frame(width: 16)
            Text(message)
                .font(.callout)
                .foregroundStyle(finding.level == .note ? .secondary : .primary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Metrics.cardPad)
        .padding(.vertical, 9)
    }
}
