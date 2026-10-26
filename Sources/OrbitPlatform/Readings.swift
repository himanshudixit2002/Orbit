import AppKit
import Darwin
import Foundation
import OrbitCore
import ServiceManagement

/// One process in the kernel's table.
public struct RunningProcess: Sendable, Equatable {
    public let name: String
    public let pid: Int32
    /// launchd is 1: background helpers it started have it as their parent, while the same tool run by
    /// hand (`sketchybar --set …`) has a shell.
    public let parent: Int32

    public init(name: String, pid: Int32, parent: Int32) {
        self.name = name
        self.pid = pid
        self.parent = parent
    }

    /// Every process, read in one call (no helper processes).
    public static func all() -> [RunningProcess] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0 else { return [] }
        // Room for processes that start between asking for the size and reading.
        size += size / 8
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride)
        guard sysctl(&mib, 3, &procs, &size, nil, 0) == 0 else { return [] }
        return procs.prefix(size / MemoryLayout<kinfo_proc>.stride).map { proc in
            var p = proc
            let name = withUnsafePointer(to: &p.kp_proc.p_comm) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN) + 1) { String(cString: $0) }
            }
            return RunningProcess(name: name, pid: proc.kp_proc.p_pid, parent: proc.kp_eproc.e_ppid)
        }
    }
}

/// A process's footprint: its program, the memory it holds, and the processor time it has used.
public struct ProcessStat: Sendable, Equatable {
    public let pid: Int32
    public let name: String
    /// The program's path ("" when macOS won't say).
    public let path: String
    /// Memory it holds now (resident), in bytes.
    public let memory: UInt64
    /// Processor time since it started (user and system), in seconds.
    public let cpuTime: Double

    public init(pid: Int32, name: String, path: String, memory: UInt64, cpuTime: Double) {
        self.pid = pid
        self.name = name
        self.path = path
        self.memory = memory
        self.cpuTime = cpuTime
    }

    /// Every process macOS lets Orbit look at (as `ps` sees them), read without helper processes.
    public static func all() -> [ProcessStat] {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        // Task times come in Mach time units (ticks on Apple silicon).
        let seconds = Double(timebase.numer) / Double(max(timebase.denom, 1)) / 1_000_000_000
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        return RunningProcess.all().compactMap { process in
            var info = proc_taskinfo()
            let size = Int32(MemoryLayout<proc_taskinfo>.size)
            guard process.pid > 0, proc_pidinfo(process.pid, PROC_PIDTASKINFO, 0, &info, size) == size else { return nil }
            let length = proc_pidpath(process.pid, &buffer, UInt32(buffer.count))
            let path = length > 0 ? String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self) : ""
            return ProcessStat(pid: process.pid, name: process.name, path: path, memory: info.pti_resident_size,
                               cpuTime: Double(info.pti_total_user + info.pti_total_system) * seconds)
        }
    }
}

/// What Orbit reads straight from macOS rather than through commands. Tests swap in their own.
public struct SystemReadings: Sendable {
    public var processes: @Sendable () -> [RunningProcess] = { RunningProcess.all() }
    /// Each process's program, memory and processor time (the Speed check and heavy-app notices).
    public var processStats: @Sendable () -> [ProcessStat] = { ProcessStat.all() }
    /// A preference as macOS has it now (what `defaults read` shows).
    public var preference: @Sendable (_ domain: String, _ key: String) -> PrefValue? = { Preferences.read($0, $1) }
    /// Bundle ids of the apps running now.
    public var runningApps: @Sendable () -> Set<String> = {
        Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
    }
    /// Whether "Allow in the Background" is off for this launch agent, so macOS won't start it at login.
    /// ServiceManagement answers in a millisecond and, unlike `sfltool dumpbtm`, never asks for a password.
    public var backgroundBlocked: @Sendable (URL) -> Bool = { SMAppService.statusForLegacyPlist(at: $0) == .requiresApproval }
    /// Whether a tool or app is installed at this path.
    public var installed: @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }

    public init() {}
}
