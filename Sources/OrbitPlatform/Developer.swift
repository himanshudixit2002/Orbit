import Darwin
import Foundation
import OrbitCore

/// One project in ~/Developer and its git state.
public struct ProjectInfo: Sendable, Identifiable, Equatable {
    public var name: String
    public var url: URL
    public var kind: ProjectKind
    public var git: GitStatus?

    public var id: String { url.path(percentEncoded: false) }
}

/// A Homebrew service (a database, say) and whether it runs and starts at login.
public struct ServiceInfo: Sendable, Identifiable, Equatable {
    public var formula: String
    public var running: Bool
    public var atLogin: Bool

    public var id: String { formula }
    public var name: String { Doctor.serviceName(formula) }
}

/// A listening process, who it belongs to, and the folder it works in.
public struct PortInfo: Sendable, Identifiable, Equatable {
    public var port: ListeningPort
    public var owner: PortOwner
    public var folder: String?

    public init(port: ListeningPort, owner: PortOwner, folder: String? = nil) {
        self.port = port
        self.owner = owner
        self.folder = folder
    }

    public var id: String { port.id }
}

/// Reads the Developer page's facts: projects, services, listening ports. Read-only.
public struct DeveloperProbe: Sendable {
    let ctx: SystemContext

    public init(_ ctx: SystemContext) { self.ctx = ctx }

    public func projects() async -> [ProjectInfo] {
        let found = DoctorProbe.projects(in: ctx.paths.developer)
        return await withTaskGroup(of: ProjectInfo.self) { group in
            for project in found {
                group.addTask {
                    let files = Set((try? FileManager.default.contentsOfDirectory(atPath: project.url.path(percentEncoded: false))) ?? [])
                    var info = ProjectInfo(name: project.name, url: project.url, kind: ProjectKind.detect(files))
                    if project.inGit {
                        let result = await ctx.run(Commands.gitStatus(project.url.path(percentEncoded: false)))
                        if result.ok { info.git = GitStatus.parse(result.stdout) }
                    }
                    return info
                }
            }
            var all: [ProjectInfo] = []
            for await info in group { all.append(info) }
            return all.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
    }

    /// Homebrew services, except the ones Orbit runs itself (they live on their own pages).
    public func services() async -> [ServiceInfo] {
        let result = await ctx.run(Commands.brewServicesInfo())
        return BrewServiceInfo.parse(Data(result.stdout.utf8))
            .filter { !Doctor.orbitServices.contains($0.name) && $0.name != "yabai" && $0.name != "skhd" }
            .map { ServiceInfo(formula: $0.name, running: $0.running, atLogin: $0.registered ?? $0.loaded) }
    }

    /// What's listening for connections (Orbit itself aside), and whose each one is.
    public func ports() async -> [PortInfo] {
        let result = await ctx.run(Commands.listeningPorts())
        let own = getpid()
        return ListeningPort.parse(result.stdout).filter { $0.pid != own }.map(Self.info)
    }

    public static func info(_ port: ListeningPort) -> PortInfo {
        PortInfo(port: port, owner: PortOwner.of(executable: executable(port.pid), parent: parent(port.pid)), folder: workingFolder(port.pid))
    }

    static func executable(_ pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    }

    static func parent(_ pid: Int32) -> Int32? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return Int32(info.pbi_ppid)
    }

    /// The process's short name (what lsof calls its command), to tell whether a number still means the same process.
    static func name(_ pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 64)
        guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    }

    /// The folder a process works in (a dev server's project), when it's one of yours.
    public static func workingFolder(_ pid: Int32) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        return withUnsafePointer(to: &info.pvi_cdir.vip_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
    }
}

extension Actions {
    /// `git init` and a .gitignore for the project's kind (an existing one is kept). Never commits or
    /// pushes. Undo moves both to the Trash.
    public func gitInit(_ project: ProjectInfo) async -> ActionOutcome {
        await steps { undo in
            let folder = project.url.path(percentEncoded: false)
            let result = await ctx.run(Commands.gitInit(folder))
            guard result.ok else { throw StepFailed(message: "git didn't start: \(result.failureMessage)") }
            undo.append(.restoreFile(path: project.url.appending(path: ".git").path(percentEncoded: false), backup: nil))
            let ignore = project.url.appending(path: ".gitignore")
            if !ctx.files.exists(ignore) {
                undo += try writePlain(ignore, project.kind.gitignore, executable: false, backups: backupFolder("git for \(project.name)"))
            }
            return "\(project.name) is in git now. Nothing is committed or pushed until you do it."
        }
    }

    /// Starts or stops a Homebrew service, now or at login.
    public enum ServiceChange: Sendable {
        case startNow, stop, startAtLogin, stopAtLogin(keepRunning: Bool)
    }

    public func changeService(_ service: ServiceInfo, _ change: ServiceChange) async -> ActionOutcome {
        await steps { undo in
            func brew(_ arguments: [String], _ summary: String) async throws {
                let result = await ctx.run(Command(Tool.brew, ["services"] + arguments + [service.formula], effect: .service, summary: summary, timeout: 40))
                guard result.ok else { throw StepFailed(message: "\(service.name): \(result.failureMessage)") }
            }
            switch change {
            case .startNow:
                try await brew(["run"], "Start \(service.name)")
                undo.append(.brewService(formula: service.formula, wasRunning: false))
                return "\(service.name) is running (until you stop it or log out)."
            case .stop:
                try await brew(["stop"], "Stop \(service.name)")
                undo.append(.brewService(formula: service.formula, wasRunning: true))
                return "\(service.name) is stopped."
            case .startAtLogin:
                try await brew(["start"], "Start \(service.name) now and at login")
                undo.append(.brewService(formula: service.formula, wasRunning: service.running))
                return "\(service.name) runs now and starts at login."
            case .stopAtLogin(let keepRunning):
                try await brew(["stop"], "Stop \(service.name) starting at login")
                if keepRunning { try await brew(["run"], "Keep \(service.name) running") }
                undo.append(.brewService(formula: service.formula, wasRunning: true))
                return keepRunning ? "\(service.name) won't start at login (it keeps running now)." : "\(service.name) won't start at login."
            }
        }
    }

    /// Asks one of your own processes to quit (it can save first). There's no undo: start it again yourself.
    /// Only for what you started: never part of macOS, an app or a background service, and never a
    /// process whose number now belongs to something else.
    public func stopProcess(_ info: PortInfo) -> ActionOutcome {
        let port = info.port
        guard info.owner == .yours else {
            return ActionOutcome(ok: false, message: "Orbit only stops things you started; \(port.command) isn't one of them.")
        }
        guard let name = DeveloperProbe.name(port.pid), name.hasPrefix(port.command) || port.command.hasPrefix(name) else {
            return ActionOutcome(ok: false, message: "\(port.command) isn't running any more.")
        }
        guard ctx.mode == .live else {
            ctx.practiceLog.record("Would ask \(port.command) (listening on \(port.port)) to quit", "kill -TERM \(port.pid)")
            return ActionOutcome(ok: true, message: "Practice: \(port.command) wasn't really asked to quit.")
        }
        guard kill(port.pid, SIGTERM) == 0 else {
            return ActionOutcome(ok: false, message: "\(port.command) couldn't be asked to quit (it may have stopped already).")
        }
        return ActionOutcome(ok: true, message: "Asked \(port.command) to quit; port \(port.port) frees up when it does.")
    }
}
