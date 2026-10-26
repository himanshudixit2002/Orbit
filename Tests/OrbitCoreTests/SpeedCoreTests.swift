import Foundation
@testable import OrbitCore
import Testing

@Suite struct SpeedTweakTests {
    @Test func durationsAreDoublesAndSwitchesBooleans() {
        for tweak in SpeedTweak.all {
            switch tweak.value {
            case .double, .bool: break
            default: Issue.record("\(tweak.key) has the wrong type")
            }
        }
        #expect(Set(SpeedTweak.all.map(\.group)) == Set(SpeedTweak.Group.allCases))
        #expect(SpeedTweak.tweaks(in: .finder).map(\.key) == ["DisableAllAnimations"])
    }

    @Test func numbersCompareByValueWhateverTheirType() {
        let quickLook = SpeedTweak.all.first { $0.key == "QLPanelAnimationDuration" }!
        #expect(quickLook.isApplied(.double(0)) && quickLook.isApplied(.int(0)))
        #expect(!quickLook.isApplied(.double(0.2)) && !quickLook.isApplied(nil))
        let windows = SpeedTweak.all.first { $0.group == .windows }!
        #expect(windows.isApplied(.bool(false)) && windows.isApplied(.int(0)) && !windows.isApplied(nil))
    }

    @Test func aGroupIsOnWhenAllItsTweaksAre() {
        var values: [String: PrefValue] = [:]
        for tweak in SpeedTweak.tweaks(in: .dock) { values[Baseline.key(tweak.domain, tweak.key)] = tweak.value }
        #expect(SpeedTweak.groupsOn { values[Baseline.key($0, $1)] } == [.dock])
        values[Baseline.key(WatchedPreferences.dockDomain, "launchanim")] = .bool(true)
        #expect(SpeedTweak.groupsOn { values[Baseline.key($0, $1)] }.isEmpty)
    }

    @Test func theWatchedListGrowsWithoutRepeats() {
        let keys = WatchedPreferences.keys.map { Baseline.key($0.domain, $0.key) }
        #expect(keys.count == Set(keys).count)
        #expect(Array(keys.prefix(WatchedPreferences.first.count)) == WatchedPreferences.first.map { Baseline.key($0.domain, $0.key) })
        for tweak in SpeedTweak.all { #expect(keys.contains(Baseline.key(tweak.domain, tweak.key))) }
    }

    @Test func aSnapshotRemembersSetAndUnsetValues() {
        var snapshot = PreferenceSnapshot()
        snapshot.record("a", .double(0.35))
        snapshot.record("b", nil)
        #expect(snapshot.knows("a") && snapshot.knows("b") && !snapshot.knows("c"))
        #expect(snapshot.value("a") == .double(0.35) && snapshot.value("b") == nil)
        snapshot.forget("b")
        #expect(!snapshot.knows("b"))
    }
}

@Suite struct SpeedCheckTests {
    let claude = "/Applications/Claude.app"
    func stat(_ pid: Int32, _ path: String, parent: Int32 = 1, memory: UInt64 = 100, cpu: Double = 0) -> ProcessStat {
        ProcessStat(pid: pid, parent: parent, name: URL(fileURLWithPath: path).lastPathComponent, path: path, memory: memory, cpuTime: cpu)
    }

    @Test func helpersToolsAndAddOnsCountTowardTheirApp() {
        let stats = [
            stat(10, "\(claude)/Contents/MacOS/Claude", memory: 400),
            stat(11, "\(claude)/Contents/Frameworks/Claude Helper (Renderer).app/Contents/MacOS/Claude Helper (Renderer)", parent: 10, memory: 700),
            stat(12, "\(claude)/Contents/Helpers/disclaimer", parent: 10, memory: 5),
            stat(13, "/Users/me/Library/Application Support/Claude/claude-code/2.1/claude.app/Contents/MacOS/claude", parent: 12, memory: 450),
            stat(14, "/opt/homebrew/bin/node", parent: 13, memory: 200),
            stat(20, "/opt/homebrew/bin/mongod", memory: 90),
            stat(30, "/System/Applications/Siri AI.app/Contents/MacOS/Siri AI", memory: 180)
        ]
        let apps = AppGrouping.apps(stats, before: nil, interval: 0)
        #expect(apps.map(\.name) == ["Claude", "Siri AI"])
        #expect(apps[0].memory == 1755 && apps[0].processes == 5 && apps[0].cpuPercent == nil)
        #expect(apps[1].isApple && !SpeedCheck.quittable(apps[1]))
    }

    @Test func processorUseComesFromTwoReadings() {
        let before: [Int32: Double] = [10: 100, 11: 50]
        let stats = [stat(10, "\(claude)/Contents/MacOS/Claude", cpu: 101), stat(11, "\(claude)/Contents/Frameworks/H.app/Contents/MacOS/H", parent: 10, cpu: 50.5),
                     stat(12, "\(claude)/Contents/Frameworks/New.app/Contents/MacOS/New", parent: 10, cpu: 7)]
        let app = AppGrouping.apps(stats, before: before, interval: 5, busy: [11]).first!
        #expect(abs((app.cpuPercent ?? 0) - 30) < 0.001)   // (1 + 0.5) s over 5 s; the new helper counts from now
        #expect(app.inUse)
    }

    @Test func aBusyCommandInATerminalIsTheOneToStopNotTheTerminal() throws {
        let warp = "/Applications/Warp.app"
        let before: [Int32: Double] = [10: 5, 11: 1, 12: 100, 13: 50]
        let stats = [
            stat(10, "\(warp)/Contents/MacOS/stable", memory: 300, cpu: 5.5),
            stat(11, "/bin/zsh", parent: 10, cpu: 1),
            stat(12, "/opt/homebrew/bin/node", parent: 11, memory: 400, cpu: 157),
            stat(13, "/opt/homebrew/bin/esbuild", parent: 12, cpu: 53)
        ]
        var terminal = try #require(AppGrouping.apps(stats, before: before, interval: 60).first)
        #expect(terminal.name == "Warp" && terminal.processes == 4)
        let command = try #require(terminal.busiestCommand)
        #expect(command.pid == 12 && command.name == "node" && command.path == "/opt/homebrew/bin/node")
        #expect(abs(command.cpuPercent - 95) < 0.001)   // 57 s of processor over 60 s
        terminal.idleMinutes = 45
        #expect(SpeedCheck.heavy([terminal], memoryTight: false) == [terminal])
        let finding = SpeedCheck.heavyFinding(terminal)
        #expect(finding.title == "node, running in Warp, keeps the processor busy")
        #expect(finding.fix == .stopCommand(pid: 12, name: "node", path: "/opt/homebrew/bin/node"))
        // Busy by itself, or big: a terminal is never offered Quit (that would end every session in it).
        terminal.busiestCommand = nil
        terminal.cpuPercent = 60
        terminal.memory = 3_000_000_000
        #expect(SpeedCheck.heavy([terminal], memoryTight: true).isEmpty)
    }

    @Test func leftoversAreHelpersWhoseAppIsGone() {
        let items = [
            LaunchItem(label: "com.docker.vmnetd", plist: "/Library/LaunchDaemons/com.docker.vmnetd.plist", program: "/Library/PrivilegedHelperTools/com.docker.vmnetd", programExists: true),
            LaunchItem(label: "com.docker.socket", plist: "/Library/LaunchDaemons/com.docker.socket.plist", program: "/Library/PrivilegedHelperTools/com.docker.socket", programExists: true),
            LaunchItem(label: "com.microsoft.update.agent", plist: "/Library/LaunchAgents/com.microsoft.update.agent.plist",
                       program: "/Library/Application Support/Microsoft/MAU2.0/Microsoft AutoUpdate.app/Contents/MacOS/Microsoft Update Assistant.app/Contents/MacOS/Microsoft Update Assistant", programExists: true),
            LaunchItem(label: "org.example.gone", plist: "/Library/LaunchAgents/org.example.gone.plist", program: "/opt/gone/tool", programExists: false),
            LaunchItem(label: "com.example.fine", plist: "/Library/LaunchAgents/com.example.fine.plist", program: "/usr/local/bin/fine", programExists: true)
        ]
        let found = Leftovers.find(items, installedApps: ["Safari.app"])
        #expect(found.map(\.owner) == ["Docker", "Microsoft AutoUpdate", "org.example.gone"])
        #expect(found[0].paths == ["/Library/LaunchDaemons/com.docker.socket.plist", "/Library/PrivilegedHelperTools/com.docker.socket",
                                   "/Library/LaunchDaemons/com.docker.vmnetd.plist", "/Library/PrivilegedHelperTools/com.docker.vmnetd"])
        #expect(found[1].paths.last == "/Library/Application Support/Microsoft/MAU2.0/Microsoft AutoUpdate.app")
        #expect(Leftovers.find(items, installedApps: ["Docker.app", "Microsoft Word.app"]).map(\.owner) == ["org.example.gone"])
    }

    @Test func busyIdleAppsAreFlaggedBigOnesOnlyWhenMemoryIsTight() {
        var facts = SpeedFacts()
        facts.instantOn = Set(SpeedTweak.Group.allCases)
        facts.apps = [
            AppUsage(name: "Busy", path: "/Applications/Busy.app", memory: 300_000_000, cpuPercent: 25, idleMinutes: 45),
            AppUsage(name: "Big", path: "/Applications/Big.app", memory: 3_000_000_000, cpuPercent: 0, idleMinutes: 90),
            AppUsage(name: "Front", path: "/Applications/Front.app", memory: 3_000_000_000, cpuPercent: 80, isFrontmost: true, idleMinutes: 0),
            AppUsage(name: "Movie", path: "/Applications/Movie.app", memory: 2_000_000_000, cpuPercent: 40, idleMinutes: 100, inUse: true)
        ]
        #expect(SpeedCheck.findings(facts).map(\.id) == ["speed-heavy-/Applications/Busy.app"])
        facts.memoryPressure = 2
        let tight = SpeedCheck.findings(facts)
        #expect(tight.first?.id == "speed-memory")
        #expect(Set(tight.map(\.id)).isSuperset(of: ["speed-heavy-/Applications/Busy.app", "speed-heavy-/Applications/Big.app"]))
        #expect(tight.first { $0.id == "speed-heavy-/Applications/Big.app" }?.fix == .quitApp(path: "/Applications/Big.app", name: "Big"))
    }

    @Test func aNoticeNeedsTwoHeavyLooksInARow() {
        let busy = AppUsage(name: "Busy", path: "/Applications/Busy.app", memory: 300_000_000, cpuPercent: 25, idleMinutes: 45)
        let first = SpeedCheck.toNotify([busy], memoryTight: false, heavyBefore: [])
        #expect(first.notify.isEmpty && first.heavyNow == ["/Applications/Busy.app"])
        #expect(SpeedCheck.toNotify([busy], memoryTight: false, heavyBefore: first.heavyNow).notify == [busy])
        // A burst that settles down, an app you've told it to ignore, one in front, one playing or working: no notice.
        var calm = busy
        calm.cpuPercent = 2
        #expect(SpeedCheck.toNotify([calm], memoryTight: false, heavyBefore: first.heavyNow) == ([], []))
        #expect(SpeedCheck.toNotify([busy], memoryTight: false, heavyBefore: first.heavyNow,
                                    ignored: ["speed-heavy-/Applications/Busy.app"]).notify.isEmpty)
        var front = busy
        front.isFrontmost = true
        var working = busy
        working.inUse = true
        #expect(SpeedCheck.toNotify([front, working], memoryTight: true, heavyBefore: first.heavyNow).notify.isEmpty)
        #expect(SpeedCheck.heavyFinding(busy).title == "Busy keeps the processor busy while you're not using it")
        #expect(SpeedCheck.heavyFinding(busy).detail.hasPrefix("It hasn't been in front for 45 minutes, yet it uses 25% of a core."))
    }

    @Test func siriInstantDiskAndIgnoring() {
        var facts = SpeedFacts()
        facts.siriOn = true
        facts.siriSeconds = 100
        facts.diskFree = 5
        facts.diskTotal = 100
        let ids = SpeedCheck.findings(facts).map(\.id)
        #expect(ids == ["speed-disk", "speed-instant", "speed-siri"] || Set(ids) == ["speed-disk", "speed-instant", "speed-siri"])
        #expect(SpeedCheck.findings(facts).first { $0.id == "speed-siri" }?.title == "Siri used 1 min 40 s of processor time")
        #expect(SpeedCheck.findings(facts, ignored: ["speed-siri", "speed-disk"]).map(\.id) == ["speed-instant"])
        facts.siriOn = false
        #expect(!SpeedCheck.findings(facts).contains { $0.id == "speed-siri" })
    }

    @Test func preferencesCompareByMeaning() {
        #expect(PrefValue.same(.double(0.30000001192092896), .double(0.3)))
        #expect(PrefValue.same(.int(44), .double(44)))
        #expect(PrefValue.same(.int(1), .bool(true)) && !PrefValue.same(.int(0), .bool(true)))
        #expect(PrefValue.same(nil, nil) && !PrefValue.same(nil, .bool(false)))
        #expect(SpeedCheck.duration(45) == "45 s" && SpeedCheck.duration(120) == "2 min" && SpeedCheck.duration(3725) == "1 h 2 min")
    }
}
