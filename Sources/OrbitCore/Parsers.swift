import Foundation

/// `launchctl print gui/<uid>/<label>`
public enum LaunchctlParser {
    public static func run(_ result: CommandResult) -> HelperRun {
        let text = result.stdout + result.stderr
        if result.status == 113 || text.contains("Could not find service") { return .notLoaded }
        guard result.ok else { return .notLoaded }
        // Only the service's own top-level lines count: nested sections (endpoints, event
        // triggers) have their own "state = active" lines further down.
        var state: String?
        var pid: Int?
        var lastExit: Int?
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if state == nil, line.hasPrefix("state = ") { state = String(line.dropFirst(8)) }
            else if pid == nil, line.hasPrefix("pid = ") { pid = Int(line.dropFirst(6)) }
            else if lastExit == nil, line.hasPrefix("last exit code = ") { lastExit = Int(line.dropFirst(17)) }
        }
        return .loaded(running: state == "running", pid: pid, lastExit: lastExit)
    }

    /// `launchctl print-disabled gui/<uid>`: the labels switched off, true meaning disabled.
    public static func disabled(_ text: String) -> [String: Bool] {
        var out: [String: Bool] = [:]
        for raw in text.split(separator: "\n") {
            let parts = raw.components(separatedBy: "=>")
            guard parts.count == 2 else { continue }
            let label = parts[0].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            out[label] = value == "disabled" || value == "true"
        }
        return out
    }
}

/// `brew services info --all --json`
public struct BrewServiceInfo: Sendable, Decodable, Equatable {
    public let name: String
    public let running: Bool
    public let loaded: Bool
    public let status: String?
    public let serviceName: String?
    public let file: String?
    public let pid: Int?
    /// Set to start at login.
    public let registered: Bool?

    enum CodingKeys: String, CodingKey {
        case name, running, loaded, status, file, pid, registered
        case serviceName = "service_name"
    }

    public static func parse(_ data: Data) -> [BrewServiceInfo] {
        (try? JSONDecoder().decode([BrewServiceInfo].self, from: data)) ?? []
    }
}

/// The Downloads sorter's log: "2026-10-25 14:06:19  name -> Folder/name" or a "cannot read" line.
public struct SorterLog: Sendable, Equatable {
    public struct Entry: Sendable, Equatable {
        public let date: Date
        public let file: String
        public let folder: String
        /// Where it went, inside Downloads: "Documents/report (2).pdf".
        public var destination: String

        public init(date: Date, file: String, folder: String, destination: String? = nil) {
            self.date = date
            self.file = file
            self.folder = folder
            self.destination = destination ?? "\(folder)/\(file)"
        }
    }

    public struct Failure: Sendable, Equatable {
        public let date: Date
        public let message: String

        public init(date: Date, message: String) {
            self.date = date
            self.message = message
        }
    }

    public var entries: [Entry] = []
    public var lastError: Failure?
    public var lastActivity: Date?

    public init() {}

    public static func parse(_ text: String) -> SorterLog {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        var log = SorterLog()
        for raw in text.split(separator: "\n") {
            let line = String(raw)
            guard line.count > 21, let date = formatter.date(from: String(line.prefix(19))) else { continue }
            let rest = line.dropFirst(19).trimmingCharacters(in: .whitespaces)
            log.lastActivity = date
            if rest.hasPrefix("cannot read") {
                log.lastError = Failure(date: date, message: rest)
            } else if let arrow = rest.range(of: " -> ", options: .backwards) {
                let destination = rest[arrow.upperBound...]
                let folder = destination.split(separator: "/").first.map(String.init) ?? "Other"
                log.entries.append(Entry(date: date, file: String(rest[..<arrow.lowerBound]), folder: folder, destination: String(destination)))
            }
        }
        return log
    }

    /// True when the last permission error is still the latest news: since then nothing was sorted and
    /// the sorter hasn't got into Downloads (`checkedAt`: when it last did, sorted anything or not).
    public func isBlocked(checkedAt: Date? = nil) -> Bool {
        guard let error = lastError else { return false }
        let lastGood = [entries.last?.date, checkedAt].compactMap { $0 }.max()
        return lastGood.map { $0 < error.date } ?? true
    }

    public func sorted(since date: Date) -> [Entry] { entries.filter { $0.date >= date } }
}

/// `systemextensionsctl list`: is Karabiner's keyboard driver approved?
public enum DriverState: Sendable, Equatable {
    case missing, waitingForApproval, enabled
}

public enum SystemExtensionsParser {
    public static let karabinerDriver = "org.pqrs.Karabiner-DriverKit-VirtualHIDDevice"

    public static func karabiner(_ text: String) -> DriverState {
        let lines = text.split(separator: "\n").filter { $0.contains(karabinerDriver) }
        if lines.contains(where: { $0.contains("[activated enabled]") }) { return .enabled }
        return lines.isEmpty ? .missing : .waitingForApproval
    }
}

/// `pluginkit -m -i <id>`: a leading + means on, - means off, nothing printed means not registered yet.
public enum QuickLookState: Sendable, Equatable {
    case notRegistered, enabled, disabled
}

public enum PluginKitParser {
    public static func parse(_ text: String) -> QuickLookState {
        guard let line = text.split(separator: "\n").first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else {
            return .notRegistered
        }
        return line.hasPrefix("-") ? .disabled : .enabled
    }
}

/// Reads a helper's own error messages (yabai and skhd log why they stopped).
public enum HelperLogClassifier {
    public static func classify(_ text: String) -> HelperProblem? {
        let lower = text.lowercased()
        if lower.contains("secure keyboard entry") {
            let app = text.range(of: #"'([^']+)'"#, options: .regularExpression).map {
                String(text[$0]).trimmingCharacters(in: CharacterSet(charactersIn: "'"))
            }
            return .secureInput(app: app)
        }
        if lower.contains("accessibility") { return .needsAccessibility }
        if lower.contains("separate spaces") { return .separateSpacesOff }
        if lower.contains("lock-file") || lower.contains("lock file") { return .duplicate }
        return nil
    }
}
