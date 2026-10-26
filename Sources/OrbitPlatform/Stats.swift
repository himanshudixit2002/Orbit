import Darwin
import Foundation

/// One reading of how busy the Mac is.
public struct SystemSample: Sendable, Equatable {
    public var date = Date()
    /// 0…1 across all cores.
    public var cpu: Double = 0
    public var perCore: [Double] = []
    public var memoryUsed: UInt64 = 0
    public var memoryTotal: UInt64 = 0
    /// 1 normal, 2 warning, 4 critical (what Activity Monitor's pressure graph shows).
    public var memoryPressure = 1
    public var diskFree: Int64 = 0
    public var diskTotal: Int64 = 0
    /// Bytes per second.
    public var download: Double = 0
    public var upload: Double = 0

    public init() {}

    public var memoryFraction: Double { memoryTotal == 0 ? 0 : Double(memoryUsed) / Double(memoryTotal) }
    public var diskUsedFraction: Double { diskTotal == 0 ? 0 : 1 - Double(diskFree) / Double(diskTotal) }
}

/// Reads CPU, memory, disk and network counters straight from the kernel, with no helper processes.
public final class StatsSampler: Sendable {
    private struct Previous {
        var ticks: [[UInt32]] = []
        var rx: UInt64 = 0
        var tx: UInt64 = 0
        var at: Date?
    }
    private let previous = Locked(Previous())
    /// Asking macOS for free space takes ~4 ms (the rest of a sample takes ~0.1 ms) and it barely
    /// changes, so it's read again at most every 30 seconds.
    private let diskCache = Locked<(free: Int64, total: Int64, at: Date)?>(nil)
    private let host = mach_host_self()

    public init() {}

    public func sample() -> SystemSample {
        var sample = SystemSample()
        let ticks = cpuTicks()
        let (rx, tx) = networkBytes()
        let now = Date()
        previous.withLock { prev in
            if let load = Self.load(ticks, since: prev.ticks) { (sample.cpu, sample.perCore) = load }
            if let at = prev.at {
                let seconds = max(now.timeIntervalSince(at), 0.001)
                sample.download = rx >= prev.rx ? Double(rx - prev.rx) / seconds : 0
                sample.upload = tx >= prev.tx ? Double(tx - prev.tx) / seconds : 0
            }
            prev = Previous(ticks: ticks, rx: rx, tx: tx, at: now)
        }
        (sample.memoryUsed, sample.memoryPressure) = memory()
        sample.memoryTotal = ProcessInfo.processInfo.physicalMemory
        (sample.diskFree, sample.diskTotal) = cachedDisk(now: now)
        sample.date = now
        return sample
    }

    /// Just CPU use (0…1 across all cores, since the last call; nil the first time) and memory in use:
    /// what the menu bar shows, without the rest of a sample.
    public func cpuAndMemory() -> (cpu: Double?, memoryUsed: UInt64) {
        let ticks = cpuTicks()
        let load = previous.withLock { prev in
            defer { prev.ticks = ticks }
            return Self.load(ticks, since: prev.ticks)
        }
        return (load?.total, memory().used)
    }

    /// How busy the cores were between two tick readings, overall and each.
    static func load(_ ticks: [[UInt32]], since old: [[UInt32]]) -> (total: Double, perCore: [Double])? {
        guard old.count == ticks.count, !ticks.isEmpty else { return nil }
        var totalBusy = 0.0, totalAll = 0.0
        let perCore = zip(ticks, old).map { new, old in
            let d = (0..<4).map { Double(new[$0] &- old[$0]) }
            let busy = d[0] + d[1] + d[3]   // user + system + nice
            let all = busy + d[2]           // + idle
            totalBusy += busy
            totalAll += all
            return all > 0 ? busy / all : 0
        }
        return (totalAll > 0 ? totalBusy / totalAll : 0, perCore)
    }

    func cachedDisk(now: Date) -> (free: Int64, total: Int64) {
        if let cached = diskCache.current, now.timeIntervalSince(cached.at) < 30 { return (cached.free, cached.total) }
        let fresh = disk()
        if fresh.total > 0 { diskCache.withLock { $0 = (fresh.free, fresh.total, now) } }
        return fresh
    }

    /// user, system, idle, nice ticks for each core.
    func cpuTicks() -> [[UInt32]] {
        var count: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(host, PROCESSOR_CPU_LOAD_INFO, &count, &info, &infoCount) == KERN_SUCCESS,
              let info else { return [] }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }
        return (0..<Int(count)).map { cpu in
            (0..<Int(CPU_STATE_MAX)).map { UInt32(bitPattern: info[cpu * Int(CPU_STATE_MAX) + $0]) }
        }
    }

    func memory() -> (used: UInt64, pressure: Int) {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(host, HOST_VM_INFO64, $0, &count) }
        }
        var pressure: Int32 = 1
        var size = MemoryLayout<Int32>.size
        sysctlbyname("kern.memorystatus_vm_pressure_level", &pressure, &size, nil, 0)
        guard result == KERN_SUCCESS else { return (0, Int(pressure)) }
        let page = UInt64(sysconf(_SC_PAGESIZE))
        let app = UInt64(stats.internal_page_count) - min(UInt64(stats.purgeable_count), UInt64(stats.internal_page_count))
        let used = (app + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)) * page
        return (used, Int(pressure))
    }

    /// Memory moved out to disk because it didn't fit (swap), in bytes.
    public static func swapUsed() -> UInt64 {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return 0 }
        return usage.xsu_used
    }

    /// Free space as Finder counts it (purgeable space counts as free).
    func disk() -> (free: Int64, total: Int64) {
        let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey])
        return (values?.volumeAvailableCapacityForImportantUsage ?? 0, Int64(values?.volumeTotalCapacity ?? 0))
    }

    /// Total bytes received and sent on every interface except loopback (64-bit counters, no wrap at 4 GB).
    func networkBytes() -> (rx: UInt64, tx: UInt64) {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var length = 0
        guard sysctl(&mib, 6, nil, &length, nil, 0) == 0, length > 0 else { return (0, 0) }
        var buffer = [UInt8](repeating: 0, count: length)
        guard sysctl(&mib, 6, &buffer, &length, nil, 0) == 0 else { return (0, 0) }
        var rx: UInt64 = 0, tx: UInt64 = 0, offset = 0
        buffer.withUnsafeBytes { raw in
            while offset + MemoryLayout<if_msghdr>.size <= length {
                let header = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
                guard header.ifm_msglen > 0 else { break }
                if Int32(header.ifm_type) == RTM_IFINFO2, offset + MemoryLayout<if_msghdr2>.size <= length {
                    let info = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    if info.ifm_flags & IFF_LOOPBACK == 0 {
                        rx &+= info.ifm_data.ifi_ibytes
                        tx &+= info.ifm_data.ifi_obytes
                    }
                }
                offset += Int(header.ifm_msglen)
            }
        }
        return (rx, tx)
    }
}
