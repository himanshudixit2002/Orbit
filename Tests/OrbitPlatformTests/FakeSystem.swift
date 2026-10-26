import Foundation
import OrbitCore
@testable import OrbitPlatform

/// A stand-in for launchd and the helper tools. It answers the commands Orbit runs from a small model
/// of which helpers are loaded, running or switched off, so starting, stopping and "did it really
/// work?" checks can be tested without touching the Mac. Every command is recorded.
final class FakeSystem: CommandExecuting, @unchecked Sendable {
    struct Service: Equatable {
        var running: Bool
        var pid: Int?
        var lastExit: Int?
        var signal: String?
        var runs = 1
    }

    private struct State {
        var loaded: [String: Service] = [:]
        var disabled: Set<String> = []
        var ran: [Command] = []
        var overrides: [(matches: @Sendable (Command) -> Bool, reply: CommandResult)] = []
        var nextPID = 1000
    }

    private let state = Locked(State())

    // MARK: Arranging

    func load(_ label: String, running: Bool = true, lastExit: Int? = nil, signal: String? = nil) {
        state.withLock { s in
            s.nextPID += 1
            s.loaded[label] = Service(running: running, pid: running ? s.nextPID : nil, lastExit: lastExit, signal: signal)
        }
    }

    /// The helper ends the way given; launchd keeps it loaded.
    func crash(_ label: String, exit: Int? = nil, signal: String? = "Segmentation fault: 11") {
        state.withLock { s in
            guard var service = s.loaded[label] else { return }
            service.running = false
            service.pid = nil
            service.lastExit = exit
            service.signal = signal
            s.loaded[label] = service
        }
    }

    func disable(_ label: String) { state.withLock { _ = $0.disabled.insert(label) } }

    /// Commands matching `matches` get `reply` and change nothing.
    func answer(_ reply: CommandResult, when matches: @escaping @Sendable (Command) -> Bool) {
        state.withLock { $0.overrides.append((matches, reply)) }
    }

    // MARK: Looking

    var commands: [Command] { state.current.ran }
    func service(_ label: String) -> Service? { state.current.loaded[label] }
    func isDisabled(_ label: String) -> Bool { state.current.disabled.contains(label) }

    /// Whether a command for `tool` (by name) ran whose arguments start with `arguments`.
    func ran(_ tool: String, _ arguments: String...) -> Bool {
        commands.contains { Self.name($0) == tool && Array($0.arguments.prefix(arguments.count)) == arguments }
    }

    static func name(_ command: Command) -> String { URL(fileURLWithPath: command.executable).lastPathComponent }

    /// The process table as macOS would show it: each running helper under launchd.
    func processes() -> [RunningProcess] {
        state.current.loaded.compactMap { label, service in
            guard service.running, let pid = service.pid,
                  let name = Helper.allCases.first(where: { $0.label == label })?.processName else { return nil }
            return RunningProcess(name: name, pid: Int32(pid), parent: 1)
        }
    }

    // MARK: Answering

    func run(_ command: Command) async -> CommandResult {
        state.withLock { $0.ran.append(command) }
        if let reply = state.current.overrides.last(where: { $0.matches(command) })?.reply { return reply }
        let args = command.arguments
        let (status, out, err): (Int32, String, String) = switch Self.name(command) {
        case "launchctl": launchctl(args)
        case "yabai" where args.first?.hasSuffix("-service") == true: service(Helper.yabai.label, verb: args[0])
        case "skhd" where args.first?.hasSuffix("-service") == true: service(Helper.skhd.label, verb: args[0])
        case "brew" where args.first == "services" && args.count >= 3: brewService(verb: args[1], formula: args[2])
        case "git" where args.contains("--get"): (1, "", "")
        default: (0, "", "")
        }
        return CommandResult(status: status, stdout: out, stderr: err, ok: command.okStatuses.contains(status))
    }

    private func launchctl(_ args: [String]) -> (Int32, String, String) {
        guard let verb = args.first, args.count >= 2 else { return (64, "", "Usage") }
        let label = args.last!.components(separatedBy: "/").last!
        return state.withLock { s -> (Int32, String, String) in
            switch verb {
            case "print":
                guard let service = s.loaded[label] else {
                    return (113, "", "Could not find service \"\(label)\" in domain for user gui: 501")
                }
                var text = "gui/501/\(label) = {\n\tstate = \(service.running ? "running" : "not running")\n"
                if let pid = service.pid { text += "\tpid = \(pid)\n" }
                if let exit = service.lastExit { text += "\tlast exit code = \(exit)\n" }
                if let signal = service.signal { text += "\tlast terminating signal = \(signal)\n" }
                text += "\truns = \(service.runs)\n"
                return (0, text + "}\n", "")
            case "print-disabled":
                let lines = s.disabled.sorted().map { "\t\"\($0)\" => disabled" }
                return (0, "disabled services = {\n" + lines.joined(separator: "\n") + "\n}\n", "")
            case "enable":
                s.disabled.remove(label)
                return (0, "", "")
            case "disable":
                s.disabled.insert(label)
                return (0, "", "")
            case "bootstrap":
                let plistLabel = URL(fileURLWithPath: args.last!).deletingPathExtension().lastPathComponent
                if s.disabled.contains(plistLabel) { return (119, "", "Bootstrap failed: 119: Service is disabled") }
                if s.loaded[plistLabel] != nil { return (5, "", "Bootstrap failed: 5: Input/output error") }
                s.nextPID += 1
                s.loaded[plistLabel] = Service(running: true, pid: s.nextPID, lastExit: nil)
                return (0, "", "")
            case "kickstart":
                guard s.loaded[label] != nil else { return (113, "", "Could not find service") }
                s.nextPID += 1
                s.loaded[label] = Service(running: true, pid: s.nextPID, lastExit: s.loaded[label]?.lastExit)
                return (0, "", "")
            case "bootout":
                return s.loaded.removeValue(forKey: label) == nil ? (113, "", "No such process") : (0, "", "")
            default:
                return (0, "", "")
            }
        }
    }

    private func service(_ label: String, verb: String) -> (Int32, String, String) {
        state.withLock { s -> (Int32, String, String) in
            switch verb {
            case "--start-service", "--restart-service":
                s.nextPID += 1
                s.loaded[label] = Service(running: true, pid: s.nextPID, lastExit: nil)
            case "--stop-service":
                s.loaded.removeValue(forKey: label)
            default:
                break
            }
            return (0, "", "")
        }
    }

    private func brewService(verb: String, formula: String) -> (Int32, String, String) {
        let label = "sh.brew." + (formula.components(separatedBy: "/").last ?? formula)
        return state.withLock { s -> (Int32, String, String) in
            switch verb {
            case "start", "restart":
                s.nextPID += 1
                s.loaded[label] = Service(running: true, pid: s.nextPID, lastExit: nil)
            case "stop":
                s.loaded.removeValue(forKey: label)
            default:
                break
            }
            return (0, "", "")
        }
    }
}

/// Real file operations inside a throwaway home folder, where "the Trash" is that home's own .Trash.
struct SandboxFileStore: FileStore {
    let live = LiveFileStore()
    let paths: Paths

    func read(_ url: URL) -> Data? { live.read(url) }
    func exists(_ url: URL) -> Bool { live.exists(url) }
    func write(_ data: Data, to url: URL, executable: Bool) throws { try live.write(data, to: url, executable: executable) }
    func move(_ from: URL, to: URL) throws { try live.move(from, to: to) }
    func backup(_ url: URL, into folder: URL) throws -> URL? { try live.backup(url, into: folder) }

    func trash(_ url: URL) throws -> URL? {
        var destination = paths.trash.appending(path: url.lastPathComponent)
        var n = 2
        while live.exists(destination) {
            destination = paths.trash.appending(path: "\(url.lastPathComponent) \(n)")
            n += 1
        }
        try live.move(url, to: destination)
        return destination
    }
}

/// Preferences kept in memory: writes land here and reads come back from here, as with macOS's own.
final class FakePreferences: PreferenceWriting {
    private let values: Locked<[String: PrefValue]>

    init(_ initial: [String: PrefValue] = [:]) { values = Locked(initial) }

    func set(_ domain: String, _ key: String, _ value: PrefValue?) {
        values.withLock { $0[Baseline.key(domain, key)] = value }
    }

    func read(_ domain: String, _ key: String) -> PrefValue? { values.current[Baseline.key(domain, key)] }
}

/// A live-mode context shut inside a throwaway home: file changes stay in it, commands go to `system`,
/// and every tool counts as installed. Preference writes are only recorded, unless `prefs` is given:
/// then they go there and are read back from there.
func sandboxContext(_ system: FakeSystem = FakeSystem(), prefs: FakePreferences? = nil) throws -> SystemContext {
    let paths = try tempHome()
    let log = PracticeLog()
    var readings = SystemReadings()
    readings.installed = { _ in true }
    readings.processes = { system.processes() }
    readings.processStats = { [] }
    readings.runningApps = { [] }
    readings.backgroundBlocked = { _ in false }
    if let prefs { readings.preference = { prefs.read($0, $1) } }
    let store = StateStore(root: paths.support)
    return SystemContext(mode: .live, paths: paths, uid: 501, executor: system, files: SandboxFileStore(paths: paths),
                         prefs: prefs ?? PracticePreferences(log: log), practiceLog: log, store: store,
                         activity: ActivityLog(root: store.root), readings: readings)
}
