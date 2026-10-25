import Foundation

/// What kind of project a folder is, from the files in it.
public enum ProjectKind: String, Sendable, Equatable, CaseIterable {
    case xcode, swift, flutter, node, python, go, rust, android, other

    public static func detect(_ files: Set<String>) -> ProjectKind {
        if files.contains(where: { $0.hasSuffix(".xcodeproj") || $0.hasSuffix(".xcworkspace") }) { return .xcode }
        if files.contains("pubspec.yaml") { return .flutter }
        if files.contains("Package.swift") { return .swift }
        if files.contains("package.json") { return .node }
        if files.contains("pyproject.toml") || files.contains("requirements.txt") || files.contains("setup.py") { return .python }
        if files.contains("go.mod") { return .go }
        if files.contains("Cargo.toml") { return .rust }
        if files.contains("build.gradle") || files.contains("build.gradle.kts") { return .android }
        return .other
    }

    public var title: String {
        switch self {
        case .xcode: "Xcode"
        case .swift: "Swift"
        case .flutter: "Flutter"
        case .node: "JavaScript"
        case .python: "Python"
        case .go: "Go"
        case .rust: "Rust"
        case .android: "Android"
        case .other: "Project"
        }
    }

    public var symbol: String {
        switch self {
        case .xcode, .swift: "swift"
        case .flutter: "bird"
        case .node: "curlybraces"
        case .python: "chevron.left.forwardslash.chevron.right"
        case .go: "hare"
        case .rust: "gearshape"
        case .android: "smartphone"
        case .other: "folder"
        }
    }

    /// What a new .gitignore holds: the folders the project builds or downloads, and macOS's own files.
    public var gitignore: String {
        let common = [".DS_Store", ".env", ".env.*"]
        let specific: [String] = switch self {
        case .xcode, .swift: [".build/", "DerivedData/", "xcuserdata/", "*.xcuserstate", ".swiftpm/"]
        case .flutter: [".dart_tool/", "build/", ".flutter-plugins", ".flutter-plugins-dependencies", "ios/Pods/", "macos/Pods/"]
        case .node: ["node_modules/", "dist/", ".next/", "coverage/", "*.log"]
        case .python: [".venv/", "venv/", "__pycache__/", "*.pyc", ".pytest_cache/", "dist/", "*.egg-info/"]
        case .go: ["bin/", "*.test", "*.out"]
        case .rust: ["target/"]
        case .android: [".gradle/", "build/", "local.properties", "*.iml", ".idea/"]
        case .other: []
        }
        return "# Made by Orbit for a \(title) project. Add your own lines anywhere.\n" + (specific + common).joined(separator: "\n") + "\n"
    }
}

/// A project's git state, from `git status --porcelain=v2 --branch`.
public struct GitStatus: Sendable, Equatable {
    public var branch: String
    public var upstream: String?
    /// Commits here not on the upstream yet, and there not here yet.
    public var ahead = 0
    public var behind = 0
    /// Files changed, added or not in git yet.
    public var changes = 0

    public static func parse(_ text: String) -> GitStatus {
        var status = GitStatus(branch: "?")
        for line in text.split(separator: "\n") {
            if line.hasPrefix("# branch.head ") {
                status.branch = String(line.dropFirst("# branch.head ".count))
            } else if line.hasPrefix("# branch.upstream ") {
                status.upstream = String(line.dropFirst("# branch.upstream ".count))
            } else if line.hasPrefix("# branch.ab ") {
                let parts = line.dropFirst("# branch.ab ".count).split(separator: " ")
                status.ahead = parts.first.flatMap { Int($0.dropFirst()) } ?? 0
                status.behind = parts.dropFirst().first.flatMap { Int($0.dropFirst()) } ?? 0
            } else if !line.hasPrefix("#") {
                status.changes += 1
            }
        }
        return status
    }
}

/// A process listening for connections (a dev server, a database), from `lsof -F pcn`.
public struct ListeningPort: Sendable, Equatable, Identifiable {
    public var pid: Int32
    public var command: String
    public var port: Int

    public init(pid: Int32, command: String, port: Int) {
        self.pid = pid
        self.command = command
        self.port = port
    }

    public var id: String { "\(pid):\(port)" }

    public static func parse(_ text: String) -> [ListeningPort] {
        var found: [ListeningPort] = []
        var pid: Int32?
        var command = ""
        for line in text.split(separator: "\n") {
            guard let kind = line.first else { continue }
            let value = line.dropFirst()
            switch kind {
            case "p": pid = Int32(value)
            case "c": command = String(value)
            case "n":
                guard let pid, let colon = value.lastIndex(of: ":"), let port = Int(value[value.index(after: colon)...]) else { continue }
                let entry = ListeningPort(pid: pid, command: command, port: port)
                if !found.contains(entry) { found.append(entry) }
            default: continue
            }
        }
        return found.sorted { ($0.port, $0.pid) < ($1.port, $1.pid) }
    }
}

extension ListeningPort {
    /// What a well-known port is for, when macOS itself holds it.
    public var knownUse: String? {
        switch (command, port) {
        case ("ControlCenter", 5000), ("ControlCenter", 7000): "AirPlay Receiver"
        case ("rapportd", _): "Handoff and AirDrop"
        default: nil
        }
    }
}

/// Who a listening process belongs to, which decides whether Orbit offers to stop it.
public enum PortOwner: Sendable, Equatable {
    /// Part of macOS (AirPlay Receiver on 5000 and 7000, say): never stopped.
    case macOS
    /// An app, or a helper inside one: quit the app itself.
    case app(String)
    /// Started in the background (a Homebrew service or a login item), or not readable: left alone.
    case background
    /// Something you started from a terminal or an editor: Orbit can ask it to quit.
    case yours

    /// From the program's path and its parent process (1 is launchd, which starts services and apps).
    public static func of(executable: String?, parent: Int32?) -> PortOwner {
        guard let executable, let parent else { return .background }
        if ["/System/", "/usr/libexec/", "/usr/sbin/", "/sbin/"].contains(where: executable.hasPrefix) { return .macOS }
        // Xcode's and the Command Line Tools' python, ruby and friends are command-line tools, not the app.
        if !executable.contains(".app/Contents/Developer/"), let bundle = executable.range(of: ".app/") {
            return .app(String(executable[..<bundle.lowerBound].split(separator: "/").last ?? "an app"))
        }
        return parent == 1 ? .background : .yours
    }

    /// A few words after the process's name; nil for your own.
    public var label: String? {
        switch self {
        case .macOS: "part of macOS"
        case .app(let name): name
        case .background: "runs in the background"
        case .yours: nil
        }
    }
}
