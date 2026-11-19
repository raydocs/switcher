import AppKit
import Carbon.HIToolbox

/// Curated global shortcut presets that avoid common macOS and editor conflicts.
enum GlobalHotkeyPreset: String, CaseIterable, Identifiable, Sendable {
    case off
    case optionShiftS
    case controlOptionS
    case controlShiftS
    case controlOptionA

    static let settingKey = "globalHotkeyPreset"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .off: L.t("Off", "关闭")
        case .optionShiftS: "⌥⇧S"
        case .controlOptionS: "⌃⌥S"
        case .controlShiftS: "⌃⇧S"
        case .controlOptionA: "⌃⌥A"
        }
    }

    var spec: (keyCode: UInt32, modifiers: UInt32)? {
        switch self {
        case .off: nil
        case .optionShiftS: (UInt32(kVK_ANSI_S), UInt32(optionKey | shiftKey))
        case .controlOptionS: (UInt32(kVK_ANSI_S), UInt32(controlKey | optionKey))
        case .controlShiftS: (UInt32(kVK_ANSI_S), UInt32(controlKey | shiftKey))
        case .controlOptionA: (UInt32(kVK_ANSI_A), UInt32(controlKey | optionKey))
        }
    }
}

/// Registers a native Carbon global hotkey (requires no Accessibility permission) and toggles the
/// menu bar popover via the public `NSStatusBarButton` hierarchy.
@MainActor
final class GlobalHotkeyController {
    private static var onHotKey: (@MainActor () -> Void)?

    nonisolated(unsafe) private var handlerRef: EventHandlerRef?
    nonisolated(unsafe) private var hotKeyRef: EventHotKeyRef?

    init() {
        Self.onHotKey = { Self.toggleMenuBarPopover() }
    }

    func apply(_ preset: GlobalHotkeyPreset) {
        unregister()
        guard let spec = preset.spec else { return }
        installHandlerIfNeeded()
        let hotKeyID = EventHotKeyID(signature: OSType(0x5357_5443), id: 1) // "SWTC"
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(spec.keyCode, spec.modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
        if status == noErr {
            hotKeyRef = ref
        }
    }

    func unregister() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
    }

    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        var ref: EventHandlerRef?
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, _ -> OSStatus in
                Task { @MainActor in GlobalHotkeyController.onHotKey?() }
                return noErr
            },
            1,
            &eventType,
            nil,
            &ref
        )
        if status == noErr {
            handlerRef = ref
        }
    }

    private static func toggleMenuBarPopover() {
        NSApp.activate(ignoringOtherApps: true)
        if let button = NSApp.windows.lazy.compactMap({ findStatusBarButton(in: $0.contentView) }).first {
            button.performClick(nil)
        }
    }

    private static func findStatusBarButton(in view: NSView?) -> NSStatusBarButton? {
        guard let view else { return nil }
        if let button = view as? NSStatusBarButton { return button }
        for sub in view.subviews {
            if let found = findStatusBarButton(in: sub) { return found }
        }
        return nil
    }

    deinit {
        if let ref = hotKeyRef { UnregisterEventHotKey(ref) }
        if let handler = handlerRef { RemoveEventHandler(handler) }
    }
}
