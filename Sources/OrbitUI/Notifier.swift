import AppKit
import OrbitCore
import UserNotifications

/// macOS notifications for what happens while Orbit's window isn't in front: a change that didn't work,
/// a helper that keeps stopping. Rare by design (see `NoticePolicy`) and quiet at first: they land in
/// Notification Center without asking; banners only once the user turns them on from the Health page.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    enum Kind: String {
        case failed, keepsStopping
    }

    weak var model: AppModel?
    private var sent: [NoticePolicy.Sent] = []
    /// "Try Again" for the last few failed changes, by notification.
    private var retries: [(id: String, retry: () -> Void)] = []
    private var center: UNUserNotificationCenter { .current() }

    func start() {
        center.delegate = self
        let open = UNNotificationAction(identifier: "open", title: "Open Orbit", options: [.foreground])
        let retry = UNNotificationAction(identifier: "retry", title: "Try Again", options: [])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Kind.failed.rawValue, actions: [retry, open], intentIdentifiers: []),
            UNNotificationCategory(identifier: Kind.keepsStopping.rawValue, actions: [open], intentIdentifiers: [])
        ])
    }

    /// Sends a notice, unless Orbit's window is in front (its toast says it there) or the same one went
    /// out lately. Returns whether it went.
    @discardableResult
    func send(_ kind: Kind, key: String, title: String, body: String, page: Page? = nil, retry: (() -> Void)? = nil) -> Bool {
        if NSApp.isActive, NSApp.keyWindow?.isVisible == true { return false }
        let now = Date()
        guard NoticePolicy.allows(key: key, kind: kind.rawValue, sent: sent, now: now) else { return false }
        sent.removeAll { now.timeIntervalSince($0.at) > 3600 }
        sent.append(.init(key: key, kind: kind.rawValue, at: now))
        let id = UUID().uuidString
        if let retry {
            retries.append((id, retry))
            if retries.count > 10 { retries.removeFirst() }
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.categoryIdentifier = kind.rawValue
        if let page { content.userInfo = ["page": page.rawValue] }
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        Task {
            // Quiet ("provisional") permission is granted without a question.
            _ = try? await center.requestAuthorization(options: [.provisional, .alert, .sound])
            try? await center.add(request)
        }
        return true
    }

    /// Asks macOS (it shows its own question) to show Orbit's notices as banners.
    func askForBanners() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let id = response.notification.request.identifier
        let action = response.actionIdentifier
        let page = response.notification.request.content.userInfo["page"] as? String
        await MainActor.run { handle(id: id, action: action, page: page) }
    }

    func handle(id: String, action: String, page: String?) {
        if action == "retry", let index = retries.firstIndex(where: { $0.id == id }) {
            retries.remove(at: index).retry()
            return
        }
        model?.openMainWindow()
        if let page, let destination = Page(rawValue: page) { model?.page = destination }
    }
}
