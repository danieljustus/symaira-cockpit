import Foundation
import UserNotifications

/// Posts the AI-usage quota alerts (#450). macOS decides whether they are shown: the
/// permission is asked once when the user turns alerts on, and a denied permission
/// silently drops them. Outside an app bundle (tests, the CLI) nothing is posted,
/// because the notification center needs a bundle identity.
enum AIUsageNotifier {
    static var isAvailable: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
    }

    static func requestPermission() {
        guard isAvailable else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func post(title: String, body: String) {
        guard isAvailable else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "ai-usage.\(UUID().uuidString)", content: content, trigger: nil))
    }
}
