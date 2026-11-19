import Foundation
import UserNotifications
import SwitcherCore

/// Safe wrapper around `UNUserNotificationCenter`.
/// Never touches `UNUserNotificationCenter.current()` outside a `.app` bundle (which would crash
/// under `swift run` or `--snapshot`).
@MainActor
enum NotificationBridge {
    static var isBundledApp: Bool {
        Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil
    }

    static func requestAuthorizationIfNeeded() {
        guard isBundledApp else { return }
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
    }

    static func deliver(_ events: [AlertEvent]) {
        guard isBundledApp, !events.isEmpty else { return }
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
                return
            }
            for event in events {
                let content = UNMutableNotificationContent()
                content.title = event.title
                content.body = event.body
                content.sound = .default
                let request = UNNotificationRequest(identifier: event.id, content: content, trigger: nil)
                center.add(request)
            }
        }
    }
}
