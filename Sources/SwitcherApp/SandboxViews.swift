import AppKit
import SwiftUI
import SwitcherCore

/// Parallel Antigravity sandboxes section inside the Antigravity tab: run extra Antigravity
/// desktop windows and `agy` CLI sessions side-by-side on separate Google accounts.
struct AntigravitySandboxesSection: View {
    let model: AppModel
    @Binding var creating: Bool
    @Binding var removing: String?
    @Binding var renaming: String?
    var forcedHover: String?

    private var runningCount: Int { model.runningSandboxCount }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Text(L.t("Parallel Sandboxes", "并行分身"))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                if runningCount > 0 {
                    Text("· \(L.t("\(runningCount) running", "\(runningCount) 个运行中"))")
                        .font(.subheadline)
                        .foregroundStyle(.green)
                }
                Spacer()
                if !creating {
                    Button {
                        removing = nil
                        renaming = nil
                        creating = true
                    } label: {
                        Label(L.t("New", "新建"), systemImage: "plus")
                    }
                    .buttonStyle(QuietButtonStyle())
                    .font(.subheadline)
                    .help(L.t(
                        "Create an isolated sandbox for running another Antigravity window & `agy` CLI at the same time",
                        "创建独立分身，同时运行另一个账号的 Antigravity 窗口与 agy 终端"))
                }
            }
            .padding(.horizontal, Metrics.rowH)
            .padding(.top, 6)

            if creating {
                NewSandboxCard(model: model, creating: $creating)
            }

            if model.sandboxes.isEmpty && !creating {
                HStack(alignment: .center, spacing: 8) {
                    Image(systemName: "square.on.square")
                        .font(.body)
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L.t("Run multiple accounts at once", "同时多开多个账号"))
                            .font(.subheadline.weight(.medium))
                        Text(L.t(
                            "Each sandbox runs its own Antigravity window & `agy` CLI without touching your main login.",
                            "每个分身可独立运行 Antigravity 窗口和 agy 终端，不影响主号登录。"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 4)
                    Button(L.t("New…", "新建…")) {
                        creating = true
                    }
                    .buttonStyle(SoftButtonStyle(compact: true))
                }
                .padding(.horizontal, Metrics.rowH)
                .padding(.vertical, Metrics.rowV)
                .background(Fill.card, in: RoundedRectangle(cornerRadius: Metrics.radius, style: .continuous))
            } else {
                VStack(spacing: Metrics.rowGap) {
                    ForEach(model.sandboxes) { sandbox in
                        SandboxRowView(
                            model: model,
                            sandbox: sandbox,
                            removing: $removing,
                            renaming: $renaming,
                            forcedHover: forcedHover == Self.rowKey(sandbox)
                        )
                    }
                }
            }
        }
    }

    static func rowKey(_ sandbox: AntigravitySandbox) -> String { "sandbox/\(sandbox.name)" }
}

/// One parallel Antigravity sandbox row: 1-click Open/Stop window, 1-click `agy` terminal,
/// live quota meters, and right-click / ellipsis actions.
struct SandboxRowView: View {
    let model: AppModel
    let sandbox: AntigravitySandbox
    @Binding var removing: String?
    @Binding var renaming: String?
    var forcedHover = false

    @State private var hovering = false
    @State private var draftAlias = ""
    @FocusState private var aliasFocused: Bool
    @Environment(\.staticRender) private var staticRender

    private var rowKey: String { AntigravitySandboxesSection.rowKey(sandbox) }
    private var display: (title: String, subtitle: String?) { model.displaySandboxLabel(sandbox) }
    private var isBusy: Bool { model.sandboxBusy.contains(sandbox.name) }
    private var highlighted: Bool { hovering || forcedHover }

    var body: some View {
        Group {
            if removing == rowKey {
                removeConfirm
            } else if renaming == rowKey {
                renameForm
            } else {
                normal
            }
        }
        .opacity(model.isBusy ? 0.4 : 1)
    }

    private var normal: some View {
        HStack(alignment: (sandbox.quota != nil || display.subtitle != nil || !sandbox.signedIn) ? .top : .center, spacing: Metrics.avatarGap) {
            Avatar(label: display.title, seed: "sandbox:\(sandbox.name)")
            VStack(alignment: .leading, spacing: 5) {
                VStack(alignment: .leading, spacing: 1) {
                    titleLine
                    if let subtitle = display.subtitle {
                        Text(subtitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } else if !sandbox.signedIn {
                        Text(L.t("Not signed in — open to sign in", "未登录 — 打开窗口或 agy 登录"))
                            .font(.subheadline)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
                if let quota = sandbox.quota {
                    AntigravityQuotaLines(quota: quota, mode: model.quotaDisplayMode)
                }
            }
        }
        .padding(.horizontal, Metrics.rowH)
        .padding(.vertical, Metrics.rowV)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if sandbox.running {
                RoundedRectangle(cornerRadius: Metrics.radius, style: .continuous)
                    .fill(Fill.tint.opacity(0.65))
            } else if highlighted {
                RoundedRectangle(cornerRadius: Metrics.radius, style: .continuous)
                    .fill(Fill.hover)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu { if !model.isBusy { menuItems } }
    }

    private var titleLine: some View {
        HStack(spacing: 5) {
            StatusDot(running: sandbox.running)
            Text(display.title)
                .font(.body.weight(sandbox.running ? .semibold : .medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(1)
            if let plan = sandbox.quota?.plan {
                Tag(text: plan.replacingOccurrences(of: "Google AI ", with: ""))
                    .help(plan)
            }
            Spacer(minLength: 4)
            controls
        }
    }

    @ViewBuilder private var controls: some View {
        if isBusy {
            Spinner(size: 12)
        } else {
            HStack(spacing: 4) {
                Button {
                    model.openSandboxAgyInTerminal(sandbox)
                } label: {
                    Image(systemName: "terminal")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(QuietButtonStyle())
                .help(L.t("Open `agy` CLI in Terminal for \(display.title)", "在终端里用 \(display.title) 启动 agy"))
                .accessibilityLabel(L.t("Open agy in Terminal", "在终端启动 agy"))

                Button {
                    if sandbox.running {
                        model.stopSandbox(sandbox)
                    } else {
                        model.launchSandbox(sandbox)
                    }
                } label: {
                    Text(sandbox.running ? L.t("Stop", "停止") : L.t("Open", "打开"))
                        .font(.subheadline.weight(.medium))
                }
                .buttonStyle(SoftButtonStyle(kind: sandbox.running ? .plain : .tinted, compact: true))
                .help(sandbox.running
                    ? L.t("Stop this sandbox's Antigravity window", "停止此分身的 Antigravity 窗口")
                    : L.t("Launch an independent Antigravity window for \(display.title)", "为 \(display.title) 启动独立 Antigravity 窗口"))

                if highlighted && !model.isBusy {
                    moreMenu
                }
            }
            .fixedSize()
        }
    }

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
        if sandbox.running {
            Button(L.t("Stop Antigravity Window", "停止 Antigravity 窗口")) {
                model.stopSandbox(sandbox)
            }
            Button(L.t("Force Stop Window", "强制停止窗口")) {
                model.stopSandbox(sandbox, force: true)
            }
        } else {
            Button(L.t("Open Antigravity Window", "启动 Antigravity 窗口")) {
                model.launchSandbox(sandbox)
            }
            Button(L.t("Open Folder in Window…", "选择项目文件夹打开…")) {
                model.openSandboxFolderPicker(sandbox)
            }
        }
        Divider()
        Button(L.t("Open agy in Terminal", "在终端启动 agy")) {
            model.openSandboxAgyInTerminal(sandbox)
        }
        Button(L.t("Copy agy Launch Command", "复制 agy 启动命令")) {
            model.copySandboxAgyCommand(sandbox)
        }
        Divider()
        Button(L.t("Rename…", "设别名…")) {
            draftAlias = sandbox.alias ?? ""
            removing = nil
            renaming = rowKey
        }
        Menu(L.t("Host File Links (\(L.sandboxLinkPolicyName(sandbox.linkPolicy)))",
                 "宿主文件软链（\(L.sandboxLinkPolicyName(sandbox.linkPolicy))）")) {
            ForEach(SandboxLinkPolicy.allCases) { policy in
                Button {
                    model.setSandboxLinkPolicy(sandbox, policy: policy)
                } label: {
                    let check = policy == sandbox.linkPolicy ? "✓ " : ""
                    switch policy {
                    case .minimal:
                        Text(check + L.t("Minimal (Recommended — hides ~/.ssh)", "精简（推荐 — 不暴露 ~/.ssh）"))
                    case .full:
                        Text(check + L.t("Full (includes ~/.ssh & ~/.config)", "完整（含 ~/.ssh 与 ~/.config）"))
                    case .none:
                        Text(check + L.t("None (strict isolation)", "无（严格隔离）"))
                    }
                }
            }
        }
        Button(L.t("Heal & Clean Stale Locks", "自愈与清理过期锁")) {
            model.healSandbox(sandbox, force: true)
        }
        .disabled(sandbox.running)
        Button(L.t("Reveal in Finder", "在访达中显示")) {
            model.revealSandboxInFinder(sandbox)
        }
        Divider()
        Button(L.t("Remove…", "删除…"), role: .destructive) {
            renaming = nil
            removing = rowKey
        }
    }

    private var renameForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: Metrics.avatarGap) {
                Avatar(label: display.title, seed: "sandbox:\(sandbox.name)")
                VStack(alignment: .leading, spacing: 2) {
                    Text(L.t("Set alias", "设置别名"))
                        .font(.body.weight(.semibold))
                    Text(sandbox.name)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            if staticRender {
                Text(draftAlias.isEmpty ? L.t("e.g. Work, Account 2", "例如：工作号、小号 2") : draftAlias)
                    .font(.body)
                    .foregroundStyle(draftAlias.isEmpty ? .tertiary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Fill.hover, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            } else {
                TextField(L.t("e.g. Work, Account 2", "例如：工作号、小号 2"), text: $draftAlias)
                    .textFieldStyle(.roundedBorder)
                    .focused($aliasFocused)
                    .onSubmit { saveAlias() }
            }
            HStack(spacing: 6) {
                if sandbox.alias != nil {
                    Button(L.t("Clear", "清除")) {
                        model.renameSandbox(sandbox, alias: nil)
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
            if draftAlias.isEmpty { draftAlias = sandbox.alias ?? "" }
            if !staticRender { aliasFocused = true }
        }
    }

    private func saveAlias() {
        let trimmed = draftAlias.trimmingCharacters(in: .whitespacesAndNewlines)
        model.renameSandbox(sandbox, alias: trimmed.isEmpty ? nil : trimmed)
        renaming = nil
    }

    private var removeConfirm: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: Metrics.avatarGap) {
                Avatar(label: display.title, seed: "sandbox:\(sandbox.name)")
                VStack(alignment: .leading, spacing: 3) {
                    Text(L.t("Remove sandbox \(display.title)?", "删除并行分身 \(display.title)？"))
                        .font(.body.weight(.semibold))
                        .lineLimit(2)
                    Text(L.t(
                        "Stops its window if running and moves ~/.antigravity-sandboxes/\(sandbox.name) to the Trash. Your main Antigravity login is not touched.",
                        "如果正在运行会先停止窗口，再将 ~/.antigravity-sandboxes/\(sandbox.name) 移入废纸篓，不影响主号登录。"))
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
                Button(L.t("Remove", "删除")) {
                    model.removeSandbox(sandbox)
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

/// Inline card for creating a new parallel Antigravity sandbox (no modal sheets).
struct NewSandboxCard: View {
    let model: AppModel
    @Binding var creating: Bool

    @State private var name = ""
    @State private var alias = ""
    @State private var linkPolicy: SandboxLinkPolicy = .minimal
    @State private var inheritHostConfig = true
    @FocusState private var nameFocused: Bool
    @Environment(\.staticRender) private var staticRender

    private var cleanName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? model.suggestedSandboxName() : trimmed
    }

    private var isNameValid: Bool {
        AntigravitySandboxes.isValidName(cleanName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L.t("New parallel Antigravity sandbox", "新建 Antigravity 并行分身"))
                .font(.body.weight(.semibold))

            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L.t("Folder name", "目录名"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if staticRender {
                        Text(cleanName)
                            .font(.subheadline)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 4)
                            .background(Fill.hover, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    } else {
                        TextField(model.suggestedSandboxName(), text: $name)
                            .textFieldStyle(.roundedBorder)
                            .focused($nameFocused)
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(L.t("Alias (optional)", "别名（可选）"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if staticRender {
                        Text(L.t("e.g. Work", "例如：小号 2"))
                            .font(.subheadline)
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 4)
                            .background(Fill.hover, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    } else {
                        TextField(L.t("e.g. Work", "例如：小号 2"), text: $alias)
                            .textFieldStyle(.roundedBorder)
                    }
                }
            }

            if !isNameValid {
                Note(symbol: "exclamationmark.circle", text: L.t(
                    "Use letters, digits, '.', '_' or '-' (starting with a letter or digit).",
                    "请仅使用字母、数字、.、_ 或 -，且以字母或数字开头。"), tint: .orange)
            }

            HStack(spacing: 8) {
                Text(L.t("Host links", "宿主软链"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("", selection: $linkPolicy) {
                    Text(L.t("Minimal", "精简")).tag(SandboxLinkPolicy.minimal)
                    Text(L.t("Full", "完整")).tag(SandboxLinkPolicy.full)
                    Text(L.t("None", "无")).tag(SandboxLinkPolicy.none)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 190)
            }

            Text(policyHint)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle(isOn: $inheritHostConfig) {
                Text(L.t("Inherit editor settings & skills (never tokens)", "继承编辑器配置与 skills（绝不复制登录凭据）"))
                    .font(.subheadline)
            }
            .toggleStyle(.checkbox)

            HStack(spacing: 6) {
                Spacer()
                Button(L.t("Cancel", "取消")) { creating = false }
                    .buttonStyle(SoftButtonStyle(compact: true))
                    .keyboardShortcut(.cancelAction)
                Button(L.t("Create", "仅创建")) {
                    submit(launch: false)
                }
                .buttonStyle(SoftButtonStyle(compact: true))
                .disabled(!isNameValid)
                Button(L.t("Create & Open", "创建并打开")) {
                    submit(launch: true)
                }
                .buttonStyle(SoftButtonStyle(kind: .tinted, compact: true))
                .disabled(!isNameValid)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Metrics.gap)
        .background(Fill.card, in: RoundedRectangle(cornerRadius: Metrics.radius, style: .continuous))
        .onAppear {
            if name.isEmpty { name = model.suggestedSandboxName() }
            if !staticRender { nameFocused = true }
        }
    }

    private var policyHint: String {
        switch linkPolicy {
        case .minimal:
            L.t("Links shell/git configs & project folders; keeps ~/.ssh and ~/.config hidden.",
                "软链 shell/git 配置和项目目录；隐藏 ~/.ssh 与 ~/.config，更安全。")
        case .full:
            L.t("Also links ~/.ssh, ~/.config, ~/.npmrc so agents can push over SSH.",
                "额外软链 ~/.ssh、~/.config 等，便于分身内直接执行 git push。")
        case .none:
            L.t("Strict isolation: links nothing from your home directory.",
                "严格隔离：不软链主目录里的任何配置或文件夹。")
        }
    }

    private func submit(launch: Bool) {
        guard isNameValid else { return }
        let targetName = cleanName
        let targetAlias = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        creating = false
        model.createSandbox(
            name: targetName,
            alias: targetAlias.isEmpty ? nil : targetAlias,
            linkPolicy: linkPolicy,
            inheritHostConfig: inheritHostConfig,
            launchImmediately: launch
        )
    }
}
