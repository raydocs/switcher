import SwiftUI

/// The popover's sizes. Every view takes its spacing, radii and control sizes from here.
enum Metrics {
    static let width: CGFloat = 360
    static let pad: CGFloat = 12
    static let gap: CGFloat = 10
    static let rowH: CGFloat = 8
    static let rowV: CGFloat = 7
    static let rowGap: CGFloat = 2
    static let radius: CGFloat = 8
    static let avatar: CGFloat = 28
    static let avatarGap: CGFloat = 10
    static let meterWidth: CGFloat = 36
    static let meterHeight: CGFloat = 4
    static let percentWidth: CGFloat = 34
    static let control: CGFloat = 28
    static let controlCompact: CGFloat = 22
    static let dot: CGFloat = 7
    /// Rows shown before the list scrolls.
    /// The account list grows with its rows up to this, then scrolls: tall, but leaving room for
    /// the rest of the popover on the screen it opens on.
    static var listMaxHeight: CGFloat {
        let screen = NSScreen.main?.visibleFrame.height ?? 900
        return max(300, min(680, screen - 320))
    }

    // The Settings window.
    static let settingsWidth: CGFloat = 560
    static let settingsMaxHeight: CGFloat = 680
    static let settingsPad: CGFloat = 20
    static let settingsGap: CGFloat = 16
    static let cardPad: CGFloat = 12
    static let appIcon: CGFloat = 56
    static let appIconRadius: CGFloat = 13
    /// The snapshot list once "Show All" makes it scroll.
    static let snapshotListHeight: CGFloat = 200
}

/// Fills layered over the popover's own material. All derive from semantic colors, so they follow
/// light and dark mode and the user's accent color.
enum Fill {
    static let card = Color.primary.opacity(0.06)
    static let hover = Color.primary.opacity(0.08)
    static let pressed = Color.primary.opacity(0.13)
    static let track = Color.primary.opacity(0.12)
    static let tint = Color.accentColor.opacity(0.14)
    static let tintHover = Color.accentColor.opacity(0.22)

    /// The selected tab: a raised surface, like the system segmented control.
    static func raised(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.16) : Color.white
    }

    /// Plan usage: neutral until it matters, then orange, then red.
    static func usage(_ percent: Int) -> Color {
        if percent >= 90 { return .red }
        if percent >= 75 { return .orange }
        return .secondary
    }
}

/// True while the view is drawn into an image (no AppKit-backed controls, no running animations).
private struct StaticRenderKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var staticRender: Bool {
        get { self[StaticRenderKey.self] }
        set { self[StaticRenderKey.self] = newValue }
    }
}

extension View {
    /// Dimmed and inert while a switch runs.
    func inert(_ on: Bool) -> some View {
        opacity(on ? 0.4 : 1).disabled(on).allowsHitTesting(!on)
    }
}

// MARK: Small parts

/// A monogram in a tinted circle. The tint is picked from the account, so it stays the same.
struct Avatar: View {
    let label: String
    let seed: String

    private static let tints: [Color] = [.blue, .purple, .pink, .orange, .teal, .indigo, .green, .brown]

    private var tint: Color {
        var h: UInt32 = 5381
        for b in seed.utf8 { h = (h &* 33) ^ UInt32(b) }
        return Self.tints[Int(h % UInt32(Self.tints.count))]
    }

    private var monogram: String {
        label.first { $0.isLetter || $0.isNumber }.map { String($0).uppercased() } ?? "?"
    }

    var body: some View {
        Text(monogram)
            .font(.callout.weight(.semibold))
            .fontDesign(.rounded)
            .foregroundStyle(tint)
            .frame(width: Metrics.avatar, height: Metrics.avatar)
            .background(tint.opacity(0.18), in: Circle())
            .accessibilityHidden(true)
    }
}

/// Running: a green dot. Not running: a hollow one.
struct StatusDot: View {
    let running: Bool

    var body: some View {
        Circle()
            .fill(running ? Color.green : Color.clear)
            .overlay { if !running { Circle().strokeBorder(.tertiary, lineWidth: 1.5) } }
            .frame(width: Metrics.dot, height: Metrics.dot)
            .accessibilityHidden(true)
    }
}

struct Spinner: View {
    var size: CGFloat = 14
    @State private var turning = false
    @Environment(\.staticRender) private var staticRender

    var body: some View {
        Circle()
            .trim(from: 0.08, to: 0.78)
            .stroke(.secondary, style: StrokeStyle(lineWidth: 2, lineCap: .round))
            .frame(width: size, height: size)
            .rotationEffect(.degrees(turning ? 360 : 0))
            .animation(.linear(duration: 0.9).repeatForever(autoreverses: false), value: turning)
            .onAppear { if !staticRender { turning = true } }
            .accessibilityHidden(true)
    }
}

/// One plan window: its name, a small meter and the percent ("–" when unknown).
struct UsageMeter: View {
    let title: String
    let name: String
    let percent: Int?

    var body: some View {
        HStack(spacing: 5) {
            Text(title)
                .foregroundStyle(.secondary)
                .fixedSize()
            Capsule()
                .fill(Fill.track)
                .overlay(alignment: .leading) {
                    if let percent, percent > 0 {
                        Capsule()
                            .fill(Fill.usage(percent))
                            .frame(width: max(Metrics.meterHeight, Metrics.meterWidth * CGFloat(min(percent, 100)) / 100))
                    }
                }
                .frame(width: Metrics.meterWidth, height: Metrics.meterHeight)
            Text(percent.map { "\($0)%" } ?? "–")
                .monospacedDigit()
                .lineLimit(1)
                .foregroundStyle(percent.map { $0 >= 90 ? AnyShapeStyle(Color.red) : AnyShapeStyle(.secondary) } ?? AnyShapeStyle(.tertiary))
                .frame(width: Metrics.percentWidth, alignment: .leading)
        }
        .font(.subheadline)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(name)
        .accessibilityValue(percent.map { "\($0)%" } ?? L.t("unknown", "未知"))
    }
}

/// A small secondary line with a symbol: explanations under a row, hints, status.
struct Note: View {
    let symbol: String
    let text: String
    var tint: Color?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Image(systemName: symbol)
                .foregroundStyle(tint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.secondary))
            Text(text)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)
        }
        .font(.subheadline)
    }
}

// MARK: Button styles

/// The popover's buttons: a soft rounded fill, tinted for the main action, red for a destructive one.
struct SoftButtonStyle: ButtonStyle {
    enum Kind { case plain, tinted, destructive }
    var kind: Kind = .plain
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        Content(configuration: configuration, kind: kind, compact: compact)
    }

    private struct Content: View {
        let configuration: Configuration
        let kind: Kind
        let compact: Bool
        @State private var hovering = false
        @Environment(\.isEnabled) private var enabled

        private var fill: Color {
            let active = enabled && (hovering || configuration.isPressed)
            switch kind {
            case .plain: return configuration.isPressed ? Fill.pressed : (active ? Fill.pressed.opacity(0.85) : Fill.hover)
            case .tinted: return active ? Fill.tintHover : Fill.tint
            case .destructive: return Color.red.opacity(active ? 0.22 : 0.14)
            }
        }

        private var ink: AnyShapeStyle {
            switch kind {
            case .plain: AnyShapeStyle(.primary)
            case .tinted: AnyShapeStyle(Color.accentColor)
            case .destructive: AnyShapeStyle(Color.red)
            }
        }

        var body: some View {
            configuration.label
                .font(compact ? .callout.weight(.medium) : .body.weight(.medium))
                .foregroundStyle(ink)
                .lineLimit(1)
                .padding(.horizontal, compact ? 10 : 12)
                .frame(height: compact ? Metrics.controlCompact : Metrics.control)
                .frame(maxWidth: compact ? nil : .infinity)
                .background(fill, in: RoundedRectangle(cornerRadius: compact ? 6 : Metrics.radius, style: .continuous))
                .opacity(enabled ? 1 : 0.4)
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
        }
    }
}

/// Text that brightens on hover: the footer, dismiss marks.
struct QuietButtonStyle: ButtonStyle {
    var tinted = false

    func makeBody(configuration: Configuration) -> some View {
        Content(configuration: configuration, tinted: tinted)
    }

    private struct Content: View {
        let configuration: Configuration
        let tinted: Bool
        @State private var hovering = false
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            configuration.label
                .foregroundStyle(tinted ? AnyShapeStyle(Color.accentColor) : (hovering ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary)))
                .opacity(!enabled ? 0.4 : (configuration.isPressed ? 0.6 : 1))
                .underline(tinted && hovering)
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
        }
    }
}

/// An account row: flat until it is hovered, focused or pressed.
struct RowButtonStyle: ButtonStyle {
    var highlighted: Bool
    var current: Bool
    var focused: Bool

    func makeBody(configuration: Configuration) -> some View {
        let fill: Color = configuration.isPressed ? Fill.pressed : (highlighted ? Fill.hover : (current ? Fill.card : .clear))
        return configuration.label
            .background(fill, in: RoundedRectangle(cornerRadius: Metrics.radius, style: .continuous))
            .overlay {
                if focused {
                    RoundedRectangle(cornerRadius: Metrics.radius, style: .continuous)
                        .strokeBorder(Color.accentColor.opacity(0.7), lineWidth: 2)
                }
            }
            .contentShape(Rectangle())
    }
}
