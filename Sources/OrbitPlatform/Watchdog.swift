import Foundation
import OrbitCore

/// Keeps an eye on the background helpers between checks: remembers what each check saw and when Orbit
/// last restarted each one, and turns that into verdicts (see `WatchdogPolicy`).
public final class Watchdog: Sendable {
    private struct Memory {
        var looks: [Helper: [WatchdogPolicy.Look]] = [:]
        var restarts: [Helper: [Date]] = [:]
        var quietUntil = Date.distantPast
    }

    private let memory = Locked(Memory())
    /// The long-running helpers (the Downloads sorter runs once an hour and is meant to stop).
    public static let watched: [Helper] = [.yabai, .skhd, .borders, .sketchybar]

    public init() {}

    /// Records what a check saw and returns a verdict for each helper launchd has loaded.
    public func observe(_ status: SystemStatus, keepAlive: (Helper) -> KeepAlive, now: Date = Date()) -> [Helper: WatchdogPolicy.Verdict] {
        memory.withLock { memory in
            var verdicts: [Helper: WatchdogPolicy.Verdict] = [:]
            for helper in Self.watched {
                let run = status.run(of: helper)
                // Not loaded means switched off: forget it, never fight the user.
                guard run.isLoaded else {
                    memory.looks[helper] = nil
                    continue
                }
                let pid: Int? = if case .loaded(true, let pid, _) = run { pid } else { nil }
                var looks = memory.looks[helper, default: []]
                looks.append(WatchdogPolicy.Look(at: now, pid: pid, job: status.jobs[helper]))
                looks.removeAll { now.timeIntervalSince($0.at) > 600 }
                memory.looks[helper] = looks
                guard now >= memory.quietUntil else { continue }
                verdicts[helper] = WatchdogPolicy.verdict(looks, keepAlive: keepAlive(helper),
                                                          restarts: memory.restarts[helper, default: []], now: now)
            }
            return verdicts
        }
    }

    public func restarted(_ helper: Helper, at date: Date = Date()) {
        memory.withLock { $0.restarts[helper, default: []].append(date) }
    }

    /// Judges nothing for a while (just after waking, helpers are often still starting).
    public func hold(for seconds: TimeInterval, from now: Date = Date()) {
        memory.withLock { $0.quietUntil = now.addingTimeInterval(seconds) }
    }
}
