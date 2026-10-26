import Foundation

/// A process's footprint: its program, the memory it holds, and the processor time it has used.
public struct ProcessStat: Sendable, Equatable {
    public let pid: Int32
    public let parent: Int32
    public let name: String
    /// The program's path ("" when macOS won't say).
    public let path: String
    /// Memory it uses now, as Activity Monitor counts it (its footprint), in bytes.
    public let memory: UInt64
    /// Processor time since it started (user and system), in seconds.
    public let cpuTime: Double

    public init(pid: Int32, parent: Int32 = 1, name: String, path: String, memory: UInt64, cpuTime: Double) {
        self.pid = pid
        self.parent = parent
        self.name = name
        self.path = path
        self.memory = memory
        self.cpuTime = cpuTime
    }
}

/// An app and what it holds now, across all its processes (a browser's or an Electron app's helpers
/// count toward it).
public struct AppUsage: Sendable, Equatable, Identifiable {
    public var name: String
    /// The app bundle.
    public var path: String
    public var memory: UInt64
    /// Percent of one processor core over the last interval; nil until there are two readings.
    public var cpuPercent: Double?
    public var processes: Int
    public var isFrontmost = false
    /// Minutes since it was last in front (nil: not known).
    public var idleMinutes: Double?
    /// Playing sound or video: in use even when it isn't in front.
    public var inUse = false

    public init(name: String, path: String, memory: UInt64, cpuPercent: Double? = nil, processes: Int = 1,
                isFrontmost: Bool = false, idleMinutes: Double? = nil, inUse: Bool = false) {
        self.name = name
        self.path = path
        self.memory = memory
        self.cpuPercent = cpuPercent
        self.processes = processes
        self.isFrontmost = isFrontmost
        self.idleMinutes = idleMinutes
        self.inUse = inUse
    }

    public var id: String { path }

    /// Part of macOS: listed, never offered to quit.
    public var isApple: Bool { path.hasPrefix("/System/") || path.hasPrefix("/Library/Apple/") || path.hasPrefix("/usr/") }
}

public enum AppGrouping {
    /// The outermost app bundle a program lives in ("…/Claude.app/Contents/Frameworks/Claude Helper
    /// (Renderer).app/…" → "…/Claude.app"), or nil when it isn't in one.
    public static func bundle(of path: String) -> String? {
        guard let range = path.range(of: ".app/") else { return path.hasSuffix(".app") ? path : nil }
        return String(path[..<range.lowerBound]) + ".app"
    }

    /// An app people open (in an Applications folder), as opposed to a bundle tucked inside one or in
    /// Application Support (a command-line tool shipped as an app, a helper).
    static func isRegularApp(_ bundle: String) -> Bool {
        bundle.contains("/Applications/") && !bundle.contains(".app/")
    }

    /// The app a process belongs to: the regular app it lives in, else the nearest regular app among
    /// the processes that started it (an app's command-line tools and add-ons count toward it), else
    /// whatever bundle it's in.
    static func owner(of stat: ProcessStat, byPID: [Int32: ProcessStat]) -> String? {
        let own = bundle(of: stat.path)
        if let own, isRegularApp(own) { return own }
        var next = byPID[stat.parent]
        for _ in 0..<16 {
            guard let process = next, process.pid > 1 else { break }
            if let bundle = bundle(of: process.path), isRegularApp(bundle) { return bundle }
            next = byPID[process.parent]
        }
        return own
    }

    /// Processes added up into apps, the biggest first. With the previous reading's processor times
    /// (by pid) and the seconds since, each app also gets its processor use over that time.
    public static func apps(_ stats: [ProcessStat], before: [Int32: Double]?, interval: Double, playing: Set<Int32> = []) -> [AppUsage] {
        let byPID = Dictionary(stats.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        var groups: [String: AppUsage] = [:]
        for stat in stats {
            guard let bundle = owner(of: stat, byPID: byPID) else { continue }
            var usage = groups[bundle] ?? AppUsage(name: URL(fileURLWithPath: bundle).deletingPathExtension().lastPathComponent,
                                                   path: bundle, memory: 0, cpuPercent: before == nil ? nil : 0, processes: 0)
            usage.memory += stat.memory
            usage.processes += 1
            if playing.contains(stat.pid) { usage.inUse = true }
            if let before, interval > 0 {
                // A process that wasn't there before counts from now, so a restart can't look like a spike.
                let used = max(0, stat.cpuTime - (before[stat.pid] ?? stat.cpuTime))
                usage.cpuPercent = (usage.cpuPercent ?? 0) + used / interval * 100
            }
            groups[bundle] = usage
        }
        return groups.values.sorted { ($0.memory, $0.path) > ($1.memory, $1.path) }
    }
}

/// A background job (launchd item) and its program.
public struct LaunchItem: Sendable, Equatable {
    public var label: String
    public var plist: String
    public var program: String?
    public var programExists: Bool

    public init(label: String, plist: String, program: String?, programExists: Bool) {
        self.label = label
        self.plist = plist
        self.program = program
        self.programExists = programExists
    }
}

/// Software that left background helpers behind when it was removed, and the files to delete.
public struct Leftover: Sendable, Equatable {
    public var owner: String
    public var paths: [String]

    public init(owner: String, paths: [String]) {
        self.owner = owner
        self.paths = paths
    }
}

public enum Leftovers {
    static let microsoftApps = ["Microsoft Word.app", "Microsoft Excel.app", "Microsoft PowerPoint.app", "Microsoft Outlook.app",
                                "Microsoft OneNote.app", "Microsoft Teams.app", "Microsoft Teams (work or school).app",
                                "Microsoft Edge.app", "OneDrive.app", "Windows App.app", "Microsoft Remote Desktop.app",
                                "Company Portal.app", "Microsoft Defender.app"]

    /// Helpers that outlive their app: label prefix → whose they are and the apps they serve.
    public static let owners: [(prefix: String, name: String, apps: [String])] = [
        ("com.docker.", "Docker", ["Docker.app"]),
        ("com.microsoft.update.", "Microsoft AutoUpdate", microsoftApps),
        ("com.microsoft.autoupdate.", "Microsoft AutoUpdate", microsoftApps)
    ]

    /// Background jobs whose app is gone (or whose program is), with the files that make them start.
    public static func find(_ items: [LaunchItem], installedApps: Set<String>) -> [Leftover] {
        var found: [String: [String]] = [:]
        for item in items.sorted(by: { $0.plist < $1.plist }) {
            let owner = owners.first { item.label.hasPrefix($0.prefix) }
            let appGone = owner.map { !$0.apps.contains(where: installedApps.contains) } ?? false
            guard appGone || (item.program != nil && !item.programExists) else { continue }
            let name = owner?.name ?? item.label
            var paths = found[name] ?? []
            paths.append(item.plist)
            if let program = item.program, item.programExists { paths.append(AppGrouping.bundle(of: program) ?? program) }
            found[name] = paths
        }
        return found.keys.sorted { $0.lowercased() < $1.lowercased() }
            .map { Leftover(owner: $0, paths: Array(NSOrderedSet(array: found[$0]!)) as! [String]) }
    }
}

/// What the Speed check looks at, gathered (read-only) by `SpeedProbe`.
public struct SpeedFacts: Sendable, Equatable {
    public var siriOn = false
    /// Processor time Siri's processes have used since they started, in seconds.
    public var siriSeconds: Double = 0
    /// 1 normal, 2 warning, 4 critical.
    public var memoryPressure = 1
    public var swapUsed: UInt64 = 0
    public var apps: [AppUsage] = []
    public var leftovers: [Leftover] = []
    public var instantOn: Set<SpeedTweak.Group> = []
    public var diskFree: Int64 = 0
    public var diskTotal: Int64 = 0

    public init() {}
}

public enum SpeedCheck {
    /// A lot of memory: only worth freeing when memory is actually tight.
    public static let heavyMemory: UInt64 = 1_536 * 1_048_576
    /// Percent of one core that counts as keeping the processor busy.
    public static let heavyCPU = 10.0
    /// How long an app has to have been out of use (minutes): busy, or holding a lot of memory.
    public static let busyIdleMinutes = 30.0
    public static let bigIdleMinutes = 60.0
    public static let siriSeconds = 30.0
    public static let tightSwap: UInt64 = 2_048 * 1_048_576

    /// Apps Orbit may offer to quit: not part of macOS, not Orbit or Finder, not in front or playing.
    public static func quittable(_ app: AppUsage) -> Bool {
        !app.isApple && !app.isFrontmost && !app.inUse && !["Orbit", "Orbit Dev", "Finder"].contains(app.name)
    }

    public static func memoryTight(pressure: Int, swapUsed: UInt64) -> Bool {
        pressure >= 2 || swapUsed >= tightSwap
    }

    /// Apps you haven't used for a while that keep the processor busy, or (when memory is tight) hold
    /// a lot of it. Plenty of free memory means a big app costs nothing, so it isn't flagged then.
    public static func heavy(_ apps: [AppUsage], memoryTight: Bool) -> [AppUsage] {
        apps.filter { app in
            guard quittable(app) else { return false }
            let idle = app.idleMinutes ?? 0
            let busy = (app.cpuPercent ?? 0) >= heavyCPU && idle >= busyIdleMinutes
            let big = memoryTight && app.memory >= heavyMemory && idle >= bigIdleMinutes
            return busy || big
        }
    }

    public static func findings(_ facts: SpeedFacts, ignored: Set<String> = []) -> [DoctorFinding] {
        var found: [DoctorFinding] = []

        let tight = memoryTight(pressure: facts.memoryPressure, swapUsed: facts.swapUsed)
        if tight {
            let biggest = facts.apps.filter { !$0.isApple }.prefix(3).map { "\($0.name) (\(bytes($0.memory)))" }
            let target = facts.apps.first { quittable($0) && ($0.idleMinutes ?? 0) >= busyIdleMinutes }
            found.append(DoctorFinding(
                id: "speed-memory", severity: .problem, symbol: "memorychip",
                title: "Memory is tight",
                detail: "The Mac is moving memory to disk (\(bytes(Int64(facts.swapUsed))) so far), which slows everything. Using the most: \(biggest.joined(separator: ", ")).",
                fix: target.map { .quitApp(path: $0.path, name: $0.name) }))
        }

        if facts.diskTotal > 0, Double(facts.diskFree) / Double(facts.diskTotal) < 0.1 {
            found.append(DoctorFinding(
                id: "speed-disk", severity: .problem, symbol: "internaldrive",
                title: "The disk is nearly full",
                detail: "\(bytes(facts.diskFree)) free of \(bytes(facts.diskTotal)). macOS slows down when it can't make room.",
                fix: .open(.cleanup)))
        }

        for app in heavy(facts.apps, memoryTight: tight) {
            let busy = (app.cpuPercent ?? 0) >= heavyCPU
            let idle = Int(app.idleMinutes ?? 0)
            found.append(DoctorFinding(
                id: "speed-heavy-\(app.path)", severity: .tidy, symbol: busy ? "cpu" : "memorychip",
                title: busy ? "\(app.name) keeps the processor busy while you're not using it"
                            : "\(app.name) holds \(bytes(Int64(app.memory))) while you're not using it",
                detail: "It hasn't been in front for \(idle >= 120 ? "\(idle / 60) hours" : "\(idle) minutes")\(busy ? ", yet it uses \(Int(app.cpuPercent ?? 0))% of a core" : ""). Quitting it frees that; it can save first.",
                fix: .quitApp(path: app.path, name: app.name)))
        }

        for leftover in facts.leftovers {
            found.append(DoctorFinding(
                id: "speed-leftover-\(leftover.owner)", severity: .tidy, symbol: "shippingbox",
                title: "\(leftover.owner)'s helpers still start with your Mac",
                detail: "\(leftover.owner) isn't installed any more, but its background files still run at every startup. Delete them in Finder: macOS asks for your password.",
                fix: .showInFinder(leftover.paths)))
        }

        if facts.siriOn, facts.siriSeconds >= siriSeconds {
            found.append(DoctorFinding(
                id: "speed-siri", severity: .tip, symbol: "waveform",
                title: "Siri used \(duration(facts.siriSeconds)) of processor time",
                detail: "Siri, Apple Intelligence and listening for “Hey Siri” run in the background all day. If you don't use them, switch them off in Siri settings (only you can).",
                fix: .openSettings(.siri)))
        }

        if facts.instantOn.count < SpeedTweak.Group.allCases.count {
            found.append(DoctorFinding(
                id: "speed-instant", severity: .tip, symbol: "bolt",
                title: "Animations still slow you down",
                detail: "Windows, sheets, Quick Look, the Dock and Finder all wait for animations. Instant Mac takes them out.",
                fix: .makeInstant))
        }

        return found.filter { !ignored.contains($0.id) }.sorted { ($0.severity, $0.title) < ($1.severity, $1.title) }
    }

    /// "1 min 40 s", "45 s", "2 h 5 min".
    public static func duration(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        if s < 60 { return "\(s) s" }
        if s < 3600 { return s % 60 == 0 ? "\(s / 60) min" : "\(s / 60) min \(s % 60) s" }
        return "\(s / 3600) h \(s % 3600 / 60) min"
    }

    static func bytes(_ count: Int64) -> String { ByteCountFormatter.string(fromByteCount: count, countStyle: .memory) }
    static func bytes(_ count: UInt64) -> String { bytes(Int64(count)) }
}
