import AppKit
import OrbitCore
import UserNotifications

/// macOS notifications for what happens while Orbit's window isn't in front: a change that didn't work,
/// a helper that keeps stopping. Rare by design (see `NoticePolicy`) and quiet at first: they land in
/// Notification Center without asking; banners only once the user turns them on from the Health page.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    enum Kind: String, CaseIterable {
        case failed, keepsStopping, attention, changed, edited, lowDisk, modeSchedule

        /// The button that does something about it (Open Orbit is always there too).
        var act: String? {
            switch self {
            case .failed: "Try Again"
            case .attention: "Fix"
            case .changed: "Undo"
            case .edited: "Review"
            case .lowDisk: "Clean Up"
            case .modeSchedule: "Start"
            case .keepsStopping: nil
            }
        }
    }

    weak var model: AppModel?
    private var sent: [NoticePolicy.Sent] = []
    /// What each recent notification's button does, by notification.
    private var acts: [(id: String, act: () -> Void)] = []
    private var center: UNUserNotificationCenter { .current() }

    func start() {
        center.delegate = self
        let open = UNNotificationAction(identifier: "open", title: "Open Orbit", options: [.foreground])
        center.setNotificationCategories(Set(Kind.allCases.map { kind in
            let act = kind.act.map { UNNotificationAction(identifier: "act", title: $0, options: [.edited, .lowDisk].contains(kind) ? [.foreground] : []) }
            return UNNotificationCategory(identifier: kind.rawValue, actions: (act.map { [$0] } ?? []) + [open], intentIdentifiers: [])
        }))
    }

    /// Sends a notice, unless Orbit's window is in front (its toast says it there) or the same one went
    /// out lately. Returns whether it went.
    @discardableResult
    func send(_ kind: Kind, key: String, title: String, body: String, page: Page? = nil, every: TimeInterval = 600,
              act: (() -> Void)? = nil) -> Bool {
        // Orbit's window says it itself, except a schedule asking first: that question is for now.
        if kind != .modeSchedule, NSApp.isActive, NSApp.keyWindow?.isVisible == true { return false }
        let now = Date()
        guard NoticePolicy.allows(key: key, kind: kind.rawValue, sent: sent, now: now, every: every) else { return false }
        sent.removeAll { now.timeIntervalSince($0.at) > max(3600, every) }
        sent.append(.init(key: key, kind: kind.rawValue, at: now))
        let id = UUID().uuidString
        if let act {
            acts.append((id, act))
            if acts.count > 10 { acts.removeFirst() }
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

    /// A schedule's question shows as a banner even with Orbit in front.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        notification.request.content.categoryIdentifier == Kind.modeSchedule.rawValue ? [.banner, .list, .sound] : [.list]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let id = response.notification.request.identifier
        let action = response.actionIdentifier
        let page = response.notification.request.content.userInfo["page"] as? String
        await MainActor.run { handle(id: id, action: action, page: page) }
    }

    func handle(id: String, action: String, page: String?) {
        if action == "act", let index = acts.firstIndex(where: { $0.id == id }) {
            acts.remove(at: index).act()
            return
        }
        model?.openMainWindow()
        if let page, let destination = Page(rawValue: page) { model?.page = destination }
    }
}
