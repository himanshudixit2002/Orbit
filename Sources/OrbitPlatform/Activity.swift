import Foundation
import OrbitCore
import os

/// Orbit's messages in the system log (Console.app, `log show --predicate 'subsystem == "com.himanshudixit.orbit"'`).
public enum OrbitLog {
    public static let changes = Logger(subsystem: "com.himanshudixit.orbit", category: "changes")
    public static let commands = Logger(subsystem: "com.himanshudixit.orbit", category: "commands")
    public static let watchdog = Logger(subsystem: "com.himanshudixit.orbit", category: "watchdog")
}

/// What Orbit did, newest last: kept in memory and in `activity.jsonl` beside Orbit's other state, one
/// JSON line per record, trimmed to the last couple of thousand so it never grows for long.
public final class ActivityLog: Sendable {
    public let file: URL
    private let records: Locked<[ActivityRecord]>
    static let limit = 2_000

    public init(root: URL) {
        file = root.appending(path: "activity.jsonl")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let lines = (try? String(contentsOf: file, encoding: .utf8))?.split(separator: "\n") ?? []
        // A line Orbit can't read (cut short by a crash, say) is just skipped.
        let loaded = lines.compactMap { try? decoder.decode(ActivityRecord.self, from: Data($0.utf8)) }
        records = Locked(Array(loaded.suffix(Self.limit)))
    }

    public func record(_ record: ActivityRecord) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let line = try? encoder.encode(record) else { return }
        records.withLock { all in
            all.append(record)
            if all.count > Self.limit + 200 {
                // Rewritten whole (atomically) with only the newest lines.
                all.removeFirst(all.count - Self.limit)
                let text = all.compactMap { try? encoder.encode($0) }.map { String(decoding: $0, as: UTF8.self) }.joined(separator: "\n")
                try? Data((text + "\n").utf8).write(to: file, options: .atomic)
            } else {
                append(line + Data("\n".utf8))
            }
        }
    }

    private func append(_ data: Data) {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: file) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: file, options: .atomic)
        }
    }

    /// The newest `count` records, newest first.
    public func recent(_ count: Int) -> [ActivityRecord] { Array(records.current.suffix(count).reversed()) }
}

/// Runs commands through `inner`, noting in the activity log every one that changes something, and any
/// that fails or is slow.
public struct LoggingExecutor: CommandExecuting {
    let inner: any CommandExecuting
    let log: ActivityLog

    public init(_ inner: any CommandExecuting, log: ActivityLog) {
        self.inner = inner
        self.log = log
    }

    public func run(_ command: Command) async -> CommandResult {
        let start = ContinuousClock.now
        let result = await inner.run(command)
        let took = ContinuousClock.now - start
        // Looks, and the menu bar's numbers every few seconds, are noted only when they fail or are slow.
        let routine = command.effect == .readOnly || command.effect == .display
        guard !routine || !result.ok || took > .seconds(1) else { return result }
        let detail: String? = result.simulated ? "Practice: not really run" : result.ok ? nil : result.failureMessage
        log.record(ActivityRecord(.command, command.summary, ok: result.ok, detail: detail))
        if !result.ok {
            OrbitLog.commands.error("\(command.summary, privacy: .public) failed: \(result.failureMessage, privacy: .private)")
        }
        return result
    }
}
