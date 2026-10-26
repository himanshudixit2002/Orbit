import AppKit
import Darwin
import Foundation
import IOKit.pwr_mgt
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

extension ProcessStat {
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
            // Memory as Activity Monitor counts it: shared pages aren't counted once per helper.
            var usage = rusage_info_v4()
            let footprint = withUnsafeMutablePointer(to: &usage) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(process.pid, RUSAGE_INFO_V4, $0) }
            } == 0 ? usage.ri_phys_footprint : info.pti_resident_size
            return ProcessStat(pid: process.pid, parent: process.parent, name: process.name, path: path, memory: footprint,
                               cpuTime: Double(info.pti_total_user + info.pti_total_system) * seconds)
        }
    }
}

/// What Orbit reads straight from macOS rather than through commands. Tests swap in their own.
public struct SystemReadings: Sendable {
    public var processes: @Sendable () -> [RunningProcess] = { RunningProcess.all() }
    /// Each process's program, memory and processor time (the Speed check and heavy-app notices).
    public var processStats: @Sendable () -> [ProcessStat] = { ProcessStat.all() }
    /// Processes in use without being in front: playing sound or video, in a call, or keeping the Mac
    /// awake for work they're doing (a download, an agent's task).
    public var busyPIDs: @Sendable () -> Set<Int32> = { PowerAssertions.busyPIDs() }
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
    /// Whether Orbit has Full Disk Access, so looking into other apps' data and your folders never
    /// brings up macOS's questions.
    public var fullDiskAccess: @Sendable () -> Bool = { FullDiskAccess.granted() }

    public init() {}
}

/// Full Disk Access, checked by opening a file only it opens (macOS's privacy database). Without it the
/// open just fails: nothing is asked.
public enum FullDiskAccess {
    public static func granted() -> Bool {
        let fd = open("/Library/Application Support/com.apple.TCC/TCC.db", O_RDONLY)
        guard fd >= 0 else { return false }
        close(fd)
        return true
    }
}

/// Who is busy on purpose, from macOS's power assertions (what `pmset -g assertions` lists): playing
/// sound or video, or asking the Mac not to sleep while it works.
enum PowerAssertions {
    static let keepAwake: Set<String> = ["PreventUserIdleDisplaySleep", "PreventUserIdleSystemSleep", "PreventSystemSleep",
                                         "NoIdleSleepAssertion", "NoDisplaySleepAssertion"]

    static func busyPIDs() -> Set<Int32> {
        var byProcess: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&byProcess) == kIOReturnSuccess,
              let all = byProcess?.takeRetainedValue() as? [NSNumber: [[String: Any]]] else { return [] }
        var pids = Set<Int32>()
        for (pid, assertions) in all {
            for assertion in assertions {
                let name = (assertion["AssertName"] as? String ?? "").lowercased()
                let type = assertion["AssertType"] as? String ?? ""
                guard name.contains("playback") || name.contains("audio") || name.contains("video") || keepAwake.contains(type) else { continue }
                pids.insert(pid.int32Value)
                // Sound is often held by coreaudiod on behalf of the app that plays it.
                if let onBehalf = assertion["AssertionOnBehalfOfPID"] as? NSNumber { pids.insert(onBehalf.int32Value) }
            }
        }
        return pids
    }
}
