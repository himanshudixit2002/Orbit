import Foundation

/// One line in Orbit's activity log: a change, a command it ran, something the watchdog did, or a
/// notification it sent.
public struct ActivityRecord: Codable, Sendable, Equatable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case change, command, watchdog, notice
    }

    public var id: UUID
    public var date: Date
    public var kind: Kind
    public var title: String
    public var ok: Bool
    public var detail: String?

    public init(_ kind: Kind, _ title: String, ok: Bool = true, detail: String? = nil, date: Date = Date()) {
        id = UUID()
        self.date = date
        self.kind = kind
        self.title = title
        self.ok = ok
        self.detail = detail
    }
}

extension String {
    /// The same text starting with a capital ("the window glow" → "The window glow").
    public var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

/// Keeps notifications rare enough to stay useful: the same one at most every ten minutes, and at most
/// three of a kind an hour.
public enum NoticePolicy {
    public struct Sent: Sendable, Equatable {
        public var key: String
        public var kind: String
        public var at: Date

        public init(key: String, kind: String, at: Date) {
            self.key = key
            self.kind = kind
            self.at = at
        }
    }

    public static func allows(key: String, kind: String, sent: [Sent], now: Date) -> Bool {
        if sent.contains(where: { $0.key == key && now.timeIntervalSince($0.at) < 600 }) { return false }
        return sent.filter { $0.kind == kind && now.timeIntervalSince($0.at) < 3600 }.count < 3
    }
}

/// A plain-text report of Orbit's state for when something needs explaining, with the home folder and
/// user name taken out so it can be shared.
public enum DiagnosticsReport {
    public struct Section: Sendable {
        public var title: String
        public var lines: [String]

        public init(_ title: String, _ lines: [String]) {
            self.title = title
            self.lines = lines
        }
    }

    public static func render(_ sections: [Section], home: String, user: String) -> String {
        let text = sections.map { section in
            "## \(section.title)\n" + (section.lines.isEmpty ? "(nothing)" : section.lines.joined(separator: "\n"))
        }
        .joined(separator: "\n\n")
        return redact(text, home: home, user: user) + "\n"
    }

    static func redact(_ text: String, home: String, user: String) -> String {
        var homePath = home
        while homePath.count > 1, homePath.hasSuffix("/") { homePath.removeLast() }
        var out = text.replacingOccurrences(of: homePath, with: "~")
        if user.count >= 3 { out = out.replacingOccurrences(of: user, with: "‹user›") }
        return out
    }
}
