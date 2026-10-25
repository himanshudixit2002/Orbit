import Foundation

/// Something on this Mac that isn't quite right, found by the Doctor, with what Orbit can do about it.
public struct DoctorFinding: Identifiable, Sendable, Equatable {
    public enum Severity: Int, Sendable, Comparable {
        /// Something doesn't work.
        case problem
        /// Wasted space or memory.
        case tidy
        /// Worth knowing.
        case tip

        public static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }
    }

    /// Stable, so "Ignore" keeps working as long as the same thing is found.
    public var id: String
    public var severity: Severity
    public var symbol: String
    public var title: String
    public var detail: String
    public var fix: DoctorFix?

    public init(id: String, severity: Severity, symbol: String, title: String, detail: String, fix: DoctorFix?) {
        self.id = id
        self.severity = severity
        self.symbol = symbol
        self.title = title
        self.detail = detail
        self.fix = fix
    }
}

/// What the Fix button does. Every fix goes into the history with Undo.
public enum DoctorFix: Sendable, Equatable {
    /// Take a Caps Lock shortcut out.
    case removeHyperKey(String)
    /// Move these to the Trash (and stop a login item first).
    case trash([String])
    /// Stop a Homebrew service and stop it starting at login.
    case stopService(formula: String)
    /// Let tmux's plugin manager install the plugins tmux.conf lists.
    case installTmuxPlugins
    /// Somewhere in Orbit that deals with it.
    case open(Page)
    /// Write the cheat sheet afresh from the current shortcuts.
    case refreshCheatSheet

    /// The button's words.
    public var label: String {
        switch self {
        case .removeHyperKey: "Remove the shortcut"
        case .trash(let paths): paths.count == 1 ? "Move to Trash" : "Move them to Trash"
        case .stopService: "Start it only when needed"
        case .installTmuxPlugins: "Install them"
        case .open(let page): "Open \(page.title)"
        case .refreshCheatSheet: "Update it"
        }
    }

    /// How the fix shows in the history.
    public var historyTitle: String {
        switch self {
        case .removeHyperKey(let key): "Removed the Caps Lock + \(key.uppercased()) shortcut"
        case .trash(let paths):
            paths.count == 1 ? "Moved \(URL(fileURLWithPath: paths[0]).deletingPathExtension().lastPathComponent) to the Trash"
                             : "Moved \(paths.count) leftover items to the Trash"
        case .stopService(let formula): "Stopped \(Doctor.serviceName(formula)) starting at login"
        case .installTmuxPlugins: "Installed tmux's plugins"
        case .open(let page): "Opened \(page.title)"
        case .refreshCheatSheet: "Updated the cheat sheet"
        }
    }

    /// Fixes that move things or stop things are confirmed first.
    public var asksFirst: Bool {
        switch self {
        case .trash, .stopService, .removeHyperKey: true
        case .installTmuxPlugins, .open, .refreshCheatSheet: false
        }
    }
}

/// What the Doctor looks at, gathered (read-only) by `DoctorProbe`.
public struct DoctorFacts: Sendable, Equatable {
    public struct AppCopy: Sendable, Equatable {
        public var name: String
        public var path: String
        public var bundleID: String
        public var version: String
        public var modified: Date
        public var size: Int64
        public var running: Bool

        public init(name: String, path: String, bundleID: String, version: String, modified: Date, size: Int64 = 0, running: Bool = false) {
            self.name = name
            self.path = path
            self.bundleID = bundleID
            self.version = version
            self.modified = modified
            self.size = size
            self.running = running
        }
    }

    public struct LaunchAgent: Sendable, Equatable {
        public var path: String
        public var label: String?
        /// The program it starts; nil when the file names none.
        public var program: String?
        public var programExists: Bool

        public init(path: String, label: String?, program: String?, programExists: Bool) {
            self.path = path
            self.label = label
            self.program = program
            self.programExists = programExists
        }
    }

    public struct Service: Sendable, Equatable {
        public var formula: String
        /// Memory it uses now, if it's running.
        public var memory: Int64?

        public init(formula: String, memory: Int64?) {
            self.formula = formula
            self.memory = memory
        }
    }

    public var capsLockOn = false
    public var missingHyperApps: [HyperBinding] = []
    public var apps: [AppCopy] = []
    public var launchAgents: [LaunchAgent] = []
    public var servicesAtLogin: [Service] = []
    public var tmuxPluginsMissing: [String] = []
    public var tmuxManagerInstalled = false
    public var projectsNotInGit: [String] = []
    public var cheatSheetStale = false

    public init() {}
}

public enum Doctor {
    /// Homebrew services Orbit runs itself: they're meant to start at login.
    public static let orbitServices: Set<String> = ["borders", "sketchybar"]

    public static func findings(_ facts: DoctorFacts, ignored: Set<String> = []) -> [DoctorFinding] {
        var found: [DoctorFinding] = []

        if facts.capsLockOn {
            for binding in facts.missingHyperApps {
                found.append(DoctorFinding(
                    id: "hyper-\(binding.key)", severity: .problem, symbol: "capslock.fill",
                    title: "Caps Lock + \(binding.key.uppercased()) opens \(binding.appName), which isn't installed",
                    detail: "Pressing it does nothing. Remove the shortcut, or give the key another app on the Keyboard page.",
                    fix: .removeHyperKey(binding.key)))
            }
        }

        // The same app twice (a "Name 2.app" left by a copy, say): the older copies are spare.
        for copies in Dictionary(grouping: facts.apps, by: \.bundleID).values where copies.count > 1 {
            let newest = copies.max { newer($1, than: $0) }!
            for spare in copies where spare != newest && !spare.running {
                found.append(DoctorFinding(
                    id: "duplicate-\(spare.path)", severity: .tidy, symbol: "square.on.square",
                    title: "\(spare.name) is an older copy of \(newest.name)",
                    detail: "Version \(spare.version), next to \(newest.version)\(spare.size > 0 ? ", taking \(bytes(spare.size))" : ""). Opening it by mistake gives you the old one.",
                    fix: .trash([spare.path])))
            }
        }

        let empty = facts.launchAgents.filter { $0.program == nil }
        if !empty.isEmpty {
            found.append(DoctorFinding(
                id: "empty-agents-" + empty.map(\.path).sorted().joined(separator: ","), severity: .tidy, symbol: "doc.badge.ellipsis",
                title: empty.count == 1 ? "An empty login item is left over" : "\(empty.count) empty login items are left over",
                detail: "\(names(empty)) start nothing: an updater left them behind. macOS tries them at every login.",
                fix: .trash(empty.map(\.path))))
        }
        for agent in facts.launchAgents where agent.program != nil && !agent.programExists {
            found.append(DoctorFinding(
                id: "broken-agent-\(agent.path)", severity: .problem, symbol: "exclamationmark.arrow.triangle.2.circlepath",
                title: "A login item starts a program that's gone",
                detail: "\(names([agent])) starts \(agent.program ?? ""), which isn't there any more, so it fails at every login.",
                fix: .trash([agent.path])))
        }

        for service in facts.servicesAtLogin where !orbitServices.contains(service.formula) {
            let name = serviceName(service.formula)
            found.append(DoctorFinding(
                id: "service-\(service.formula)", severity: .tip, symbol: "server.rack",
                title: "\(name) starts at every login",
                detail: "It runs all the time\(service.memory.map { ", using \(bytes($0)) of memory now" } ?? ""). If you only need it for some projects, start it from the Developer page when you do.",
                fix: .stopService(formula: service.formula)))
        }

        if !facts.tmuxPluginsMissing.isEmpty, facts.tmuxManagerInstalled {
            found.append(DoctorFinding(
                id: "tmux-plugins", severity: .problem, symbol: "terminal",
                title: "tmux's plugins were never installed",
                detail: "tmux.conf asks for \(facts.tmuxPluginsMissing.joined(separator: ", ")), but they aren't there, so sessions aren't saved and restored.",
                fix: .installTmuxPlugins))
        }

        if !facts.projectsNotInGit.isEmpty {
            let count = facts.projectsNotInGit.count
            found.append(DoctorFinding(
                id: "not-in-git", severity: .tip, symbol: "point.3.connected.trianglepath.dotted",
                title: count == 1 ? "A project isn't in git" : "\(count) projects aren't in git",
                detail: "\(facts.projectsNotInGit.prefix(4).joined(separator: ", "))\(count > 4 ? " and \(count - 4) more" : ""): without git there's no history to go back to.",
                fix: .open(.developer)))
        }

        if facts.cheatSheetStale {
            found.append(DoctorFinding(
                id: "cheat-sheet", severity: .tip, symbol: "list.bullet.rectangle",
                title: "The shortcut cheat sheet is out of date",
                detail: "CHEATSHEET.md doesn't match the shortcuts you have now.",
                fix: .refreshCheatSheet))
        }

        return found.filter { !ignored.contains($0.id) }.sorted { ($0.severity, $0.title) < ($1.severity, $1.title) }
    }

    /// The newer of two copies: the higher version, then the more recently changed.
    static func newer(_ a: DoctorFacts.AppCopy, than b: DoctorFacts.AppCopy) -> Bool {
        let order = a.version.compare(b.version, options: .numeric)
        return order == .orderedSame ? a.modified > b.modified : order == .orderedDescending
    }

    static func names(_ agents: [DoctorFacts.LaunchAgent]) -> String {
        agents.map { URL(fileURLWithPath: $0.path).lastPathComponent }.joined(separator: " and ")
    }

    /// "mongodb-community" → "MongoDB".
    public static func serviceName(_ formula: String) -> String {
        let known = ["mongodb-community": "MongoDB", "postgresql": "PostgreSQL", "mysql": "MySQL", "redis": "Redis",
                     "elasticsearch": "Elasticsearch", "rabbitmq": "RabbitMQ", "kafka": "Kafka", "nginx": "nginx", "colima": "Colima"]
        let base = formula.split(separator: "@").first.map(String.init) ?? formula
        return known[base] ?? base
    }

    static func bytes(_ count: Int64) -> String { ByteCountFormatter.string(fromByteCount: count, countStyle: .file) }
}
