import Foundation
import OrbitCore

/// A value guarded by a lock, safe to share between threads.
public final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    public init(_ value: Value) { self.value = value }

    @discardableResult
    public func withLock<R>(_ body: (inout Value) -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }

    public var current: Value { withLock { $0 } }
}

public protocol CommandExecuting: Sendable {
    func run(_ command: Command) async -> CommandResult
}

/// The environment every command gets. yabai and skhd copy it into their launchd files when they
/// start, so PATH must reach Homebrew (their scripts call `jq` and `yabai`) and USER must be set
/// (their sockets live at /tmp/<tool>_$USER.socket).
public enum OrbitEnvironment {
    public static func standard(home: URL) -> [String: String] {
        let user = NSUserName()
        return [
            "PATH": "\(Tool.homebrew)/bin:\(Tool.homebrew)/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": home.path(percentEncoded: false),
            "USER": user,
            "LOGNAME": user,
            "LANG": "en_US.UTF-8",
            "LC_ALL": "en_US.UTF-8",
            "TMPDIR": ProcessInfo.processInfo.environment["TMPDIR"] ?? NSTemporaryDirectory(),
            "HOMEBREW_NO_AUTO_UPDATE": "1",
            "HOMEBREW_NO_INSTALL_CLEANUP": "1",
            "HOMEBREW_NO_ENV_HINTS": "1",
            "NONINTERACTIVE": "1"
        ]
    }
}

/// Runs commands for real, off the main thread, with a timeout (SIGTERM, then SIGKILL two seconds later).
public struct LiveExecutor: CommandExecuting {
    let environment: [String: String]
    static let outputLimit = 4 << 20

    public init(home: URL) {
        environment = OrbitEnvironment.standard(home: home)
    }

    @concurrent public func run(_ command: Command) async -> CommandResult {
        let io = ProcessIO(command: command, environment: environment)
        return await withCheckedContinuation { continuation in
            io.start { continuation.resume(returning: $0) }
        }
    }
}

/// One running process and the output collected from it.
private final class ProcessIO: @unchecked Sendable {
    let command: Command
    let process = Process()
    let out = Pipe()
    let err = Pipe()
    let collected = Locked((out: Data(), err: Data(), timedOut: false, finished: false))

    init(command: Command, environment: [String: String]) {
        self.command = command
        process.executableURL = URL(fileURLWithPath: command.executable)
        process.arguments = command.arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        if command.captureOutput {
            process.standardOutput = out
            process.standardError = err
        } else {
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
        }
    }

    func append(_ data: Data, toError: Bool) {
        guard !data.isEmpty else { return }
        collected.withLock { state in
            if toError {
                if state.err.count < LiveExecutor.outputLimit { state.err.append(data) }
            } else if state.out.count < LiveExecutor.outputLimit {
                state.out.append(data)
            }
        }
    }

    func start(_ done: @escaping @Sendable (CommandResult) -> Void) {
        if command.captureOutput {
            out.fileHandleForReading.readabilityHandler = { [weak self] handle in self?.append(handle.availableData, toError: false) }
            err.fileHandleForReading.readabilityHandler = { [weak self] handle in self?.append(handle.availableData, toError: true) }
        }
        process.terminationHandler = { [self] finished in
            if command.captureOutput {
                out.fileHandleForReading.readabilityHandler = nil
                err.fileHandleForReading.readabilityHandler = nil
                append(out.fileHandleForReading.readDataToEndOfFile(), toError: false)
                append(err.fileHandleForReading.readDataToEndOfFile(), toError: true)
            }
            let status = finished.terminationStatus
            let state = collected.withLock { state -> (Data, Data, Bool, Bool) in
                let first = !state.finished
                state.finished = true
                return (state.out, state.err, state.timedOut, first)
            }
            guard state.3 else { return }
            done(CommandResult(status: status,
                               stdout: String(decoding: state.0, as: UTF8.self),
                               stderr: String(decoding: state.1, as: UTF8.self),
                               timedOut: state.2,
                               ok: !state.2 && command.okStatuses.contains(status)))
        }
        do {
            try process.run()
        } catch {
            // Nothing started, so nothing will ever call these: let go of them (the termination
            // handler holds this object, which holds the process) and close the pipes now.
            process.terminationHandler = nil
            out.fileHandleForReading.readabilityHandler = nil
            err.fileHandleForReading.readabilityHandler = nil
            for pipe in [out, err] {
                try? pipe.fileHandleForReading.close()
                try? pipe.fileHandleForWriting.close()
            }
            collected.withLock { $0.finished = true }
            done(.launchFailure("Couldn't start \(command.executable): \(error.localizedDescription)"))
            return
        }
        let pid = process.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + command.timeout) { [self] in
            guard process.isRunning else { return }
            collected.withLock { $0.timedOut = true }
            kill(pid, SIGTERM)
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [self] in
                if process.isRunning { kill(pid, SIGKILL) }
            }
        }
    }
}

/// What practice mode would have done, in plain English.
public struct PracticeEntry: Sendable, Identifiable, Equatable {
    public let id = UUID()
    public let date: Date
    public let summary: String
    public let detail: String

    public init(summary: String, detail: String, date: Date = Date()) {
        self.date = date
        self.summary = summary
        self.detail = detail
    }
}

public final class PracticeLog: Sendable {
    private let entries = Locked<[PracticeEntry]>([])

    public init() {}

    public func record(_ summary: String, _ detail: String) {
        entries.withLock { $0.append(PracticeEntry(summary: summary, detail: detail)) }
    }

    public var all: [PracticeEntry] { entries.current }

    public func clear() { entries.withLock { $0.removeAll() } }
}

/// Runs only commands that change nothing; logs the rest and reports success.
public struct PracticeExecutor: CommandExecuting {
    let live: LiveExecutor
    let log: PracticeLog

    public init(live: LiveExecutor, log: PracticeLog) {
        self.live = live
        self.log = log
    }

    public func run(_ command: Command) async -> CommandResult {
        if command.effect == .readOnly { return await live.run(command) }
        log.record(command.summary, command.commandLine)
        return .simulatedSuccess
    }
}
