import Foundation
import UserNotifications

/// Local notifications. They need a real app bundle; when running the bare executable (tests,
/// `--render-menu`) every call is a no-op.
@MainActor
enum Notifier {
    struct Message: Equatable {
        var title: String
        var body: String
    }

    static var isAvailable: Bool { Bundle.main.bundleIdentifier != nil }

    static func requestAuthorization() async -> Bool {
        guard isAvailable else { return false }
        return (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }

    static func post(_ message: Message) {
        guard isAvailable else { return }
        let content = UNMutableNotificationContent()
        content.title = message.title
        content.body = message.body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
