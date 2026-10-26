import Foundation
@testable import OrbitCore
import Testing

@Suite struct StorageCoreTests {
    let gb: Int64 = 1_000_000_000

    @Test func theRestOfWhatsUsedIsMacOSAndHiddenAreasStayApart() {
        let areas = StorageMap.areas(measured: [.apps: 18 * gb, .developer: 11 * gb, .projects: 5 * gb, .files: 9 * gb, .trash: 0],
                                     hidden: [.files, .media], used: 150 * gb, free: 68 * gb)
        #expect(areas.map(\.kind) == [.apps, .developer, .projects, .system, .files, .media, .free])
        // What Orbit couldn't see (the hidden folders' 9 GB too) is part of macOS and the rest.
        #expect(areas.first { $0.kind == .system }?.size == 116 * gb)
        #expect(areas.filter(\.hidden).map(\.kind) == [.files, .media])
        #expect(areas.last == StorageArea(kind: .free, size: 68 * gb))
        // Measuring more than macOS counts as used (purgeable space) never makes the rest negative.
        #expect(StorageMap.areas(measured: [.apps: 20 * gb], hidden: [], used: 10 * gb, free: 0).first { $0.kind == .system }?.size == 0)
    }

    @Test func whenAnAppWasLastOpened() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Asia/Kolkata"))
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 26, hour: 16)))
        func app(_ days: Double?) -> InstalledAppSize {
            InstalledAppSize(name: "App", path: "/Applications/App.app", bundleID: nil, size: 1,
                             lastUsed: days.map { now.addingTimeInterval(-$0 * 86_400) }, removable: true, running: false)
        }
        #expect(app(0.1).lastUsedText(now: now, calendar: calendar) == "Opened today")
        #expect(app(1).lastUsedText(now: now, calendar: calendar) == "Opened yesterday")
        #expect(app(5).lastUsedText(now: now, calendar: calendar) == "Last opened 5 days ago")
        #expect(app(25).lastUsedText(now: now, calendar: calendar) == "Last opened 3 weeks ago")
        #expect(app(113).lastUsedText(now: now, calendar: calendar) == "Not opened since July")
        #expect(app(400).lastUsedText(now: now, calendar: calendar) == "Not opened since September 2025")
        #expect(app(nil).lastUsedText(now: now, calendar: calendar) == "Never opened")
        #expect(app(113).unused(now: now) && app(nil).unused(now: now) && !app(25).unused(now: now))
    }

    @Test func onlyYourOwnLooseFilesCanBeMoved() {
        let home = "/Users/me"
        func file(_ path: String) -> LargeFile { LargeFile(path: home + path, size: 2 * gb, modified: nil) }
        #expect(file("/Movies/trip.mov").movable(home: home))
        #expect(file("/Downloads/Xcode_27.xip").movable(home: home))
        // Part of the Photos library, an app's own data, a tool's hidden folder, or outside your home: never on its own.
        let photo = file("/Pictures/Photos Library.photoslibrary/originals/A/clip.mov")
        #expect(photo.package == home + "/Pictures/Photos Library.photoslibrary" && !photo.movable(home: home))
        #expect(!file("/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw").movable(home: home))
        #expect(!file("/.ollama/models/blobs/sha256-1").movable(home: home))
        #expect(!LargeFile(path: "/opt/big.bin", size: gb, modified: nil).movable(home: home))
        #expect(file("/Movies/trip.mov").name == "trip.mov")
    }

    @Test func memoryIsSaidPlainly() {
        var memory = MemoryBreakdown()
        memory.total = 16 * 1_073_741_824
        memory.free = 2 * 1_073_741_824
        memory.cached = 4 * 1_073_741_824
        #expect(memory.summary == "Memory is fine: 6 GB of 16 GB is free or can be freed at once.")
        memory.swap = 1_073_741_824
        #expect(memory.summary == "Memory is fine: 6 GB of 16 GB is free or can be freed at once, though 1 GB was moved to disk earlier.")
        // A lot moved to disk counts as tight, as the Speed check has it.
        memory.swap = 3 * 1_073_741_824
        #expect(memory.tight && memory.summary == "Memory has been tight: 3 GB was moved to disk, and getting it back is slow. Quitting an app you're not using helps.")
        memory.swap = 1_073_741_824
        memory.pressure = 2
        #expect(memory.summary.hasPrefix("Memory is getting tight"))
        memory.pressure = 4
        #expect(memory.summary.hasPrefix("Memory is very tight: the Mac is moving memory to disk (1 GB so far)"))
    }

    @Test func virtualMachinesAreFoundAndColimasIsNamed() {
        let vm = "/System/Library/Frameworks/Virtualization.framework/Versions/A/XPCServices/com.apple.Virtualization.VirtualMachine.xpc/Contents/MacOS/com.apple.Virtualization.VirtualMachine"
        // macOS hands process names over cut short.
        let stats = [ProcessStat(pid: 5, name: "com.apple.Virtu", path: vm, memory: 6_000, cpuTime: 1),
                     ProcessStat(pid: 6, name: "com.apple.Virtu", path: vm, memory: 2_000, cpuTime: 1),
                     ProcessStat(pid: 7, name: "limactl", path: "/opt/homebrew/bin/limactl", memory: 30, cpuTime: 1)]
        let found = VirtualMachines.find(stats, colimaInstalled: true)
        #expect(found.map(\.name) == ["Colima's Linux machine", "A virtual machine"] && found.map(\.memory) == [6_000, 2_000])
        // Without Colima installed, or without its limactl running, none is taken for Colima's.
        #expect(VirtualMachines.find(stats, colimaInstalled: false).allSatisfy { !$0.isColima })
        #expect(VirtualMachines.find(Array(stats.prefix(2)), colimaInstalled: true).allSatisfy { !$0.isColima })
    }

    @Test func appsWorthQuittingAreIdleBigAndYours() {
        let mb: UInt64 = 1_048_576
        let apps = [
            AppUsage(name: "Big", path: "/Applications/Big.app", memory: 900 * mb, idleMinutes: 90),
            AppUsage(name: "Bigger", path: "/Applications/Bigger.app", memory: 1_500 * mb, idleMinutes: 300),
            AppUsage(name: "Recent", path: "/Applications/Recent.app", memory: 900 * mb, idleMinutes: 20),
            AppUsage(name: "Small", path: "/Applications/Small.app", memory: 50 * mb, idleMinutes: 300),
            AppUsage(name: "Playing", path: "/Applications/Playing.app", memory: 900 * mb, idleMinutes: 300, inUse: true),
            AppUsage(name: "Warp", path: "/Applications/Warp.app", memory: 900 * mb, idleMinutes: 300),
            AppUsage(name: "Photos", path: "/System/Applications/Photos.app", memory: 900 * mb, idleMinutes: 300)
        ]
        #expect(IdleApps.toQuit(apps).map(\.name) == ["Bigger", "Big"])
    }
}
