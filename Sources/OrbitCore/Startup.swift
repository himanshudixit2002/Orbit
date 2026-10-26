import Foundation

/// How one restart went: when macOS started, when you were logged in, when the Mac went calm, and what
/// kept it busy until then. Orbit opens at login, so it times every restart it starts with.
public struct StartupRecord: Codable, Sendable, Equatable, Identifiable {
    /// When macOS started (the kernel's boot time).
    public var bootedAt: Date
    /// When you were logged in.
    public var loginAt: Date
    /// When the Mac went calm after login; nil if it hadn't by the time Orbit stopped watching.
    public var calmAt: Date?
    /// What used the processor most from startup until then (your own processes: macOS's own, such
    /// as Spotlight's indexing, can't be seen into).
    public var busiest: [Use]

    public struct Use: Codable, Sendable, Equatable {
        public var name: String
        /// Seconds of processor time.
        public var seconds: Double

        public init(name: String, seconds: Double) {
            self.name = name
            self.seconds = seconds
        }
    }

    public init(bootedAt: Date, loginAt: Date, calmAt: Date?, busiest: [Use]) {
        // Whole seconds, as they're saved: read back, it's the same restart.
        func whole(_ date: Date) -> Date { Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down)) }
        self.bootedAt = whole(bootedAt)
        self.loginAt = whole(loginAt)
        self.calmAt = calmAt.map(whole)
        self.busiest = busiest
    }

    public var id: Date { bootedAt }

    /// Seconds from macOS starting until you were logged in.
    public var toLogin: Double { max(0, loginAt.timeIntervalSince(bootedAt)) }
    /// Seconds from login until the Mac went calm.
    public var toCalm: Double? { calmAt.map { max(0, $0.timeIntervalSince(loginAt)) } }
}

public enum StartupTimer {
    /// Seconds between looks at the processor.
    public static let every = 10.0
    /// How long after login Orbit watches for the Mac to go calm.
    public static let watchFor = 15.0 * 60
    /// Calm: under a fifth of the processor in use, across all cores, for three looks in a row (30 s).
    public static let calmBelow = 0.2
    public static let calmLooks = 3
    /// Restarts kept for comparing.
    public static let kept = 10

    /// When the Mac went calm: the first look of the first run of `calmLooks` looks whose average use is
    /// under `calmBelow`. Each look is the processor's use since the one before.
    public static func calm(_ looks: [(at: Date, cpu: Double)]) -> Date? {
        guard looks.count >= calmLooks else { return nil }
        for end in (calmLooks - 1)..<looks.count {
            let window = looks[(end - calmLooks + 1)...end]
            if window.reduce(0, { $0 + $1.cpu }) / Double(calmLooks) < calmBelow { return window.first?.at }
        }
        return nil
    }

    /// macOS's own background work that runs as you, by what people know it as.
    static let knownWork: [String: String] = [
        "corespotlightd": "Spotlight", "mds": "Spotlight", "mdworker": "Spotlight", "mdworker_shared": "Spotlight",
        "spotlightknowledged": "Spotlight", "mediaanalysisd": "Photo and video analysis", "photoanalysisd": "Photo and video analysis",
        "photolibraryd": "Photo and video analysis", "cloudd": "iCloud", "bird": "iCloud", "fileproviderd": "iCloud"
    ]

    /// What used the processor most, biggest first: processes added up by the app they belong to,
    /// Siri's many processes as one, macOS's known background work by name, the rest as themselves.
    public static func busiest(_ stats: [ProcessStat], top: Int = 5) -> [StartupRecord.Use] {
        let byPID = Dictionary(stats.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        var totals: [String: Double] = [:]
        for stat in stats where stat.cpuTime > 0 {
            let name = SpeedCheck.siriProcesses.contains(stat.name) ? "Siri"
                : knownWork[stat.name]
                ?? AppGrouping.owner(of: stat, byPID: byPID).map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent } ?? stat.name
            totals[name, default: 0] += stat.cpuTime
        }
        return totals.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.prefix(top).map { StartupRecord.Use(name: $0.key, seconds: $0.value) }
    }

    /// "macOS took 23 s to start and log you in, and the Mac was calm 2 min 10 s after that."
    public static func summary(_ record: StartupRecord) -> String {
        let started = "macOS took \(SpeedCheck.duration(record.toLogin)) to start and log you in"
        guard let calm = record.toCalm else {
            return started + ", and the Mac was still busy \(SpeedCheck.duration(watchFor)) after that."
        }
        return started + (calm < every ? ", and the Mac was calm straight away." : ", and the Mac was calm \(SpeedCheck.duration(calm)) after that.")
    }

    /// From power-on to calm, against the restart before: "1 min 5 s quicker than the restart before".
    /// Nil when either never went calm.
    public static func comparison(_ record: StartupRecord, before: StartupRecord?) -> String? {
        guard let before, let now = total(record), let then = total(before) else { return nil }
        let gap = then - now
        if abs(gap) < 10 { return "About as quick as the restart before." }
        return "\(SpeedCheck.duration(abs(gap))) \(gap > 0 ? "quicker" : "slower") than the restart before."
    }

    /// Seconds from macOS starting until the Mac was calm.
    public static func total(_ record: StartupRecord) -> Double? {
        record.toCalm.map { record.toLogin + $0 }
    }

    /// The list with `record` added (in place of one for the same restart), oldest first, the newest `kept`.
    public static func adding(_ record: StartupRecord, to list: [StartupRecord]) -> [StartupRecord] {
        let others = list.filter { abs($0.bootedAt.timeIntervalSince(record.bootedAt)) >= 1 }
        return Array((others + [record]).sorted { $0.bootedAt < $1.bootedAt }.suffix(kept))
    }
}
