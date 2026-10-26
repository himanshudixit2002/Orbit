import Foundation
import OrbitCore
@testable import OrbitPlatform
import Testing

@Suite struct LatePreferenceKeyTests {
    let global = WatchedPreferences.globalDomain

    @Test func aSettingYouHadBeforeOrbitComesBackInsteadOfBeingCleared() async throws {
        // Your own NSWindowResizeTime, from before Orbit watched it; an old baseline that never looked.
        let prefs = FakePreferences([Baseline.key(global, "NSWindowResizeTime"): .double(0.2)])
        let ctx = try sandboxContext(prefs: prefs)
        ctx.store.setBaseline(Baseline(wallpaper: nil))
        let actions = Actions(ctx)
        actions.topUpBaseline()
        let baseline = try #require(ctx.store.baseline)
        #expect(baseline.preferences[Baseline.key(global, "NSWindowResizeTime")] == .double(0.2))
        #expect(baseline.preferencesLookedAt?.contains(Baseline.key(global, "NSWindowResizeTime")) == true)

        _ = await actions.setPreferences([.init(global, "NSWindowResizeTime", .double(0.001))], message: "Faster")
        _ = await actions.restoreBaseline()
        #expect(prefs.read(global, "NSWindowResizeTime") == .double(0.2))
    }

    @Test func whatOrbitChangedFirstIsReadFromTheHistory() async throws {
        let prefs = FakePreferences()
        let ctx = try sandboxContext(prefs: prefs)
        ctx.store.setBaseline(Baseline(wallpaper: nil))
        let actions = Actions(ctx)
        // Orbit set it before the baseline learned about the key: the history knows it wasn't set.
        let outcome = await actions.setPreferences([.init(global, "QLPanelAnimationDuration", .double(0))], message: "Faster")
        ctx.store.append(JournalEntry(title: "Faster", actions: outcome.undo))
        actions.topUpBaseline()
        #expect(ctx.store.baseline?.preferences[Baseline.key(global, "QLPanelAnimationDuration")] == nil)
        _ = await actions.restoreBaseline()
        #expect(prefs.read(global, "QLPanelAnimationDuration") == nil)
    }

    @Test func aKeyNothingKnowsAboutIsLeftAlone() async throws {
        let prefs = FakePreferences([Baseline.key(global, "NSAutomaticWindowAnimationsEnabled"): .bool(false)])
        let ctx = try sandboxContext(prefs: prefs)
        ctx.store.setBaseline(Baseline(wallpaper: nil))   // looked at the first keys only; no top-up yet
        _ = await Actions(ctx).restoreBaseline()
        #expect(prefs.read(global, "NSAutomaticWindowAnimationsEnabled") == .bool(false))
    }
}

@Suite struct ProcessReadingTests {
    @Test func thisProcessHasItsPathMemoryAndTime() {
        let me = ProcessStat.all().first { $0.pid == getpid() }
        #expect(me != nil)
        #expect(me.map { !$0.path.isEmpty && $0.memory > 0 && $0.cpuTime > 0 } == true)
        _ = StatsSampler.swapUsed()
    }
}

@Suite struct InstantMacTests {
    let dock = WatchedPreferences.dockDomain

    @Test func everythingInstantThenBackAsItWas() async throws {
        let system = FakeSystem()
        let prefs = FakePreferences([Baseline.key(dock, "autohide-time-modifier"): .double(0.35),
                                     Baseline.key(dock, "expose-animation-duration"): .double(0.12)])
        let ctx = try sandboxContext(system, prefs: prefs)
        let actions = Actions(ctx)
        let on = await actions.setInstant(Set(SpeedTweak.Group.allCases), on: true)
        #expect(on.ok)
        for tweak in SpeedTweak.all { #expect(tweak.isApplied(prefs.read(tweak.domain, tweak.key)), "\(tweak.key)") }
        #expect(actions.instantGroupsOn() == Set(SpeedTweak.Group.allCases))
        #expect(system.ran("killall", "Dock") && system.ran("killall", "Finder"))
        #expect(ctx.store.settings.speed.before.value(Baseline.key(dock, "autohide-time-modifier")) == .double(0.35))

        // Off: the Dock's own speeds come back, and what wasn't set is unset again.
        #expect(await actions.setInstant([.dock, .finder], on: false).ok)
        #expect(prefs.read(dock, "autohide-time-modifier") == .double(0.35))
        #expect(prefs.read(dock, "expose-animation-duration") == .double(0.12))
        #expect(prefs.read(dock, "launchanim") == nil)
        #expect(prefs.read(WatchedPreferences.finderDomain, "DisableAllAnimations") == nil)
        #expect(actions.instantGroupsOn() == [.windows, .sheets])
    }

    @Test func undoPutsEveryValueBack() async throws {
        let prefs = FakePreferences([Baseline.key(dock, "autohide-time-modifier"): .double(0.35)])
        let ctx = try sandboxContext(prefs: prefs)
        let actions = Actions(ctx)
        let on = await actions.setInstant(Set(SpeedTweak.Group.allCases), on: true)
        _ = await actions.undo(on.undo)
        #expect(prefs.read(dock, "autohide-time-modifier") == .double(0.35))
        #expect(prefs.read(WatchedPreferences.globalDomain, "NSAutomaticWindowAnimationsEnabled") == nil)
        #expect(actions.instantGroupsOn().isEmpty)
        #expect(ctx.store.settings.speed.before == PreferenceSnapshot())
    }
}

@Suite struct StopCommandTests {
    // A number no process can have: should the check ever let a wrong one through, nothing is hit.
    let nobody = Int32.max

    @Test func onlyThatSameProgramIsAskedToStop() throws {
        let node = ProcessStat(pid: nobody, parent: 1, name: "node", path: "/opt/homebrew/bin/node", memory: 1, cpuTime: 1)
        let ctx = try sandboxContext(stats: [node])
        // That number runs something else now (the command ended and the number came round again).
        let other = Actions(ctx).stopCommand(pid: nobody, name: "node", path: "/usr/bin/python3")
        #expect(other.ok && other.message == "node isn't running any more.")
        // The same program: asked. No such process really exists, so macOS says no.
        let asked = Actions(ctx).stopCommand(pid: nobody, name: "node", path: "/opt/homebrew/bin/node")
        #expect(!asked.ok && asked.message.hasPrefix("node couldn't be asked to stop"))
    }

    @Test func practiceOnlyWritesItDown() throws {
        let ctx = SystemContext.make(mode: .practice, paths: try tempHome())
        let me = try #require(ProcessStat.all().first { $0.pid == getpid() })
        let outcome = Actions(ctx).stopCommand(pid: me.pid, name: me.name, path: me.path)
        #expect(outcome.ok && outcome.message.hasPrefix("Practice:"))
        #expect(ctx.practiceLog.all.contains { $0.summary == "Would ask \(me.name) to stop" })
    }
}

@Suite struct StartupStoreTests {
    @Test func restartsAreKeptAcrossLaunches() throws {
        let ctx = try sandboxContext()
        let booted = Date(timeIntervalSince1970: 1_800_000_000)
        ctx.store.addStartup(StartupRecord(bootedAt: booted, loginAt: booted.addingTimeInterval(23), calmAt: booted.addingTimeInterval(150),
                                           busiest: [.init(name: "Siri", seconds: 100)]))
        #expect(ctx.store.startups.count == 1)
        #expect(StateStore(root: ctx.store.root).startups == ctx.store.startups)
    }

    @Test func thisMacsStartIsKnown() throws {
        let booted = try #require(StartupProbe.bootTime())
        // The clock runs on while the Mac sleeps and uptime doesn't; the kernel notes its start a few seconds in.
        #expect(booted < Date() && Date().timeIntervalSince(booted) >= ProcessInfo.processInfo.systemUptime - 60)
    }
}

@Suite struct SpeedProbeTests {
    @Test func theTrackerKnowsProcessorUseAndIdleTime() throws {
        var readings = SystemReadings()
        let calls = Locked(0)
        readings.processStats = {
            let n = calls.withLock { $0 += 1; return $0 }
            return [ProcessStat(pid: 5, parent: 1, name: "Tool", path: "/Applications/Tool.app/Contents/MacOS/Tool",
                                memory: 1_000, cpuTime: n == 1 ? 10 : 12)]
        }
        readings.busyPIDs = { [] }
        let tracker = AppUsageTracker(readings: readings)
        let start = Date()
        tracker.noteActive("/Applications/Tool.app/", at: start)
        let first = tracker.sample(frontmost: nil, at: start.addingTimeInterval(600))
        #expect(first.first?.cpuPercent == nil)
        #expect(abs((first.first?.idleMinutes ?? 0) - 10) < 0.01)
        let second = tracker.sample(frontmost: "/Applications/Tool.app", at: start.addingTimeInterval(660))
        #expect((second.first?.cpuPercent ?? 0) > 0)
        #expect(second.first?.isFrontmost == true && second.first?.idleMinutes == 0)
    }

    @Test func leftoversAndLoginAgentsAreReadFromTheirFolders() async throws {
        let ctx = try sandboxContext()
        let library = ctx.paths.home.appending(path: "Library-system")
        let daemons = library.appending(path: "LaunchDaemons")
        let tools = library.appending(path: "PrivilegedHelperTools")
        try FileManager.default.createDirectory(at: daemons, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
        let tool = tools.appending(path: "com.docker.vmnetd")
        try Data("x".utf8).write(to: tool)
        let plist: [String: Any] = ["Label": "com.docker.vmnetd", "Program": tool.path(percentEncoded: false), "RunAtLoad": true]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: daemons.appending(path: "com.docker.vmnetd.plist"))
        let apps = ctx.paths.home.appending(path: "Apps")
        try FileManager.default.createDirectory(at: apps.appending(path: "Safari.app"), withIntermediateDirectories: true)

        let probe = SpeedProbe(ctx, library: library, applicationFolders: [apps])
        let facts = probe.facts(apps: [])
        #expect(facts.leftovers.map(\.owner) == ["Docker"])
        #expect(facts.leftovers.first?.paths.contains(tool.path(percentEncoded: false)) == true)

        // Your own login agents (Orbit's helpers aside), and switching one off with Undo.
        try FileManager.default.createDirectory(at: ctx.paths.launchAgents, withIntermediateDirectories: true)
        for (label, program) in [("com.example.thing", "/Applications/Thing.app/Contents/MacOS/Thing"), (Helper.yabai.label, "/opt/homebrew/bin/yabai")] {
            let agent: [String: Any] = ["Label": label, "ProgramArguments": [program], "RunAtLoad": true]
            try PropertyListSerialization.data(fromPropertyList: agent, format: .xml, options: 0)
                .write(to: ctx.paths.launchAgents.appending(path: "\(label).plist"))
        }
        let agents = probe.loginAgents()
        #expect(agents.map(\.name) == ["Thing"])
        let off = await Actions(ctx).setStartsAtLogin(agents[0], false)
        #expect(off.ok)
        #expect(probe.loginAgents().first?.startsAtLogin == false)
        _ = await Actions(ctx).undo(off.undo)
        #expect(probe.loginAgents().first?.startsAtLogin == true)
    }

    @Test func applyingTwiceRestartsNothingTheSecondTime() async throws {
        let system = FakeSystem()
        let ctx = try sandboxContext(system, prefs: FakePreferences())
        let actions = Actions(ctx)
        _ = await actions.setInstant([.dock], on: true)
        let restarts = system.commands.filter { FakeSystem.name($0) == "killall" }.count
        let again = await actions.setInstant([.dock], on: true)
        #expect(again.undo.isEmpty)
        #expect(system.commands.filter { FakeSystem.name($0) == "killall" }.count == restarts)
    }

    @Test func quittingInPracticeOnlyWritesItDown() async throws {
        let ctx = SystemContext.make(mode: .practice, paths: try tempHome())
        let finder = "/System/Library/CoreServices/Finder.app"
        let outcome = await Actions(ctx).quitApp(path: finder, name: "Finder")
        #expect(outcome.ok && outcome.undo.isEmpty)
        #expect(ctx.practiceLog.all.contains { $0.summary == "Would ask Finder to quit" })
    }
}
