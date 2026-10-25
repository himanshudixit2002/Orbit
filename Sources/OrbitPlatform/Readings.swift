import AppKit
import Darwin
import Foundation
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

/// What Orbit reads straight from macOS rather than through commands. Tests swap in their own.
public struct SystemReadings: Sendable {
    public var processes: @Sendable () -> [RunningProcess] = { RunningProcess.all() }
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
