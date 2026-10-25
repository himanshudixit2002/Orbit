import Foundation

/// What launchd knows about one job beyond whether it runs: how often it started, how it last ended
/// and where its error messages go. Read from `launchctl print`; only the job's own top-level lines
/// count (nested sections have look-alike keys).
public struct LaunchdJob: Sendable, Equatable {
    public var running = false
    public var runs = 0
    /// nil until it has ended at least once.
    public var lastExit: Int?
    /// Set when a signal ended it: a crash, e.g. "Segmentation fault: 11".
    public var lastSignal: String?
    public var stderrPath: String?

    public init() {}

    /// Ended badly: a crash or a non-zero exit.
    public var endedBadly: Bool { lastSignal != nil || (lastExit ?? 0) != 0 }

    public static func parse(_ text: String) -> LaunchdJob {
        var job = LaunchdJob()
        for raw in text.split(separator: "\n") where raw.hasPrefix("\t") && !raw.hasPrefix("\t\t") {
            let line = raw.dropFirst()
            func value(_ key: String) -> String? { line.hasPrefix(key + " = ") ? String(line.dropFirst(key.count + 3)) : nil }
            if let v = value("state") { job.running = v == "running" }
            else if let v = value("runs") { job.runs = Int(v) ?? 0 }
            else if let v = value("last exit code") { job.lastExit = Int(v) }
            else if let v = value("last terminating signal") { job.lastSignal = v }
            else if let v = value("stderr path") { job.stderrPath = v }
        }
        return job
    }
}

/// How launchd restarts a helper by itself, from the KeepAlive key in its plist.
public struct KeepAlive: Sendable, Equatable {
    /// `KeepAlive = true`: always started again.
    public var always = false
    /// `SuccessfulExit = false`: started again after a non-zero exit.
    public var afterFailure = false
    /// `Crashed = true`: started again after a crash.
    public var afterCrash = false

    public init(always: Bool = false, afterFailure: Bool = false, afterCrash: Bool = false) {
        self.always = always
        self.afterFailure = afterFailure
        self.afterCrash = afterCrash
    }

    public static func read(_ plist: Data?) -> KeepAlive {
        guard let plist, let root = try? PropertyListSerialization.propertyList(from: plist, format: nil) as? [String: Any] else {
            return KeepAlive()
        }
        if let flag = root["KeepAlive"] as? Bool { return KeepAlive(always: flag) }
        guard let rules = root["KeepAlive"] as? [String: Any] else { return KeepAlive() }
        return KeepAlive(afterFailure: (rules["SuccessfulExit"] as? Bool) == false, afterCrash: (rules["Crashed"] as? Bool) == true)
    }

    /// Whether launchd will start the job again after it ended like this.
    public func restarts(_ job: LaunchdJob) -> Bool {
        always || (afterFailure && (job.lastExit ?? 0) != 0) || (afterCrash && job.lastSignal != nil)
    }
}

/// Decides what to do about a background helper that's switched on, from what the last few checks saw.
/// Pure, so every case is tested. It never acts on a helper the user switched off (that one isn't
/// loaded, so it isn't asked about), and a clean exit is left alone: the helper's own messages say why
/// (yabai stops cleanly when it lacks Accessibility, which only the user can give).
public enum WatchdogPolicy {
    /// One check's view of a helper.
    public struct Look: Sendable, Equatable {
        public var at: Date
        public var pid: Int?
        /// From launchd, when it was asked (it is while the helper isn't running).
        public var job: LaunchdJob?

        public init(at: Date, pid: Int?, job: LaunchdJob?) {
            self.at = at
            self.pid = pid
            self.job = job
        }
    }

    public enum Verdict: Sendable, Equatable {
        case fine
        /// It keeps starting and stopping: say so, with why when launchd knows.
        case crashLoop(String)
        /// It stopped badly and launchd won't start it again, so Orbit does, after this many seconds.
        case restart(after: TimeInterval)
        /// Orbit restarted it too often lately: it's the user's turn.
        case gaveUp(String)
    }

    /// Waits before each of Orbit's restarts within half an hour; after that many, it stops trying.
    public static let backoff: [TimeInterval] = [10, 30, 90, 300]

    public static func verdict(_ looks: [Look], keepAlive: KeepAlive, restarts: [Date], now: Date) -> Verdict {
        guard let latest = looks.last else { return .fine }
        let recent = looks.filter { now.timeIntervalSince($0.at) <= 120 }
        // Each new process is a fresh start; three in two minutes is a loop.
        let starts = zip(recent, recent.dropFirst()).filter { $1.pid != nil && $1.pid != $0.pid }.count
        if starts >= 3 { return .crashLoop("It keeps stopping (\(starts) restarts in two minutes)\(reason(latest.job)).") }
        guard latest.pid == nil, let job = latest.job, job.endedBadly, !keepAlive.restarts(job) else { return .fine }
        let lately = restarts.filter { now.timeIntervalSince($0) <= 30 * 60 }.count
        guard lately < backoff.count else {
            return .gaveUp("It stopped\(reason(job)), and starting it again didn't help.")
        }
        return .restart(after: backoff[lately])
    }

    static func reason(_ job: LaunchdJob?) -> String {
        guard let job else { return "" }
        if let signal = job.lastSignal { return " (\(signal))" }
        if let exit = job.lastExit, exit != 0 { return " (exit code \(exit))" }
        return ""
    }
}
