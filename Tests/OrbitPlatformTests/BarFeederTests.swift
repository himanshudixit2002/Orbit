import Foundation
import OrbitCore
@testable import OrbitPlatform
import Testing

@Suite struct BarFeederTests {
    let palette = OrbitSettings().palette

    func feeder(_ system: FakeSystem) throws -> BarFeeder {
        BarFeeder(ctx: try sandboxContext(system), clock: { Date(timeIntervalSince1970: 1_793_000_000) })
    }

    @Test func feedsOnlyWhileTheBarRunsAndTheScreensAreAwake() async throws {
        let system = FakeSystem()
        let feeder = try feeder(system)
        feeder.update(running: false, barPID: nil, bar: BarSettings(), palette: palette)
        #expect(!feeder.isFeeding)
        feeder.update(running: true, barPID: 42, bar: BarSettings(), palette: palette)
        #expect(feeder.isFeeding)
        feeder.setPaused(true)
        #expect(!feeder.isFeeding)
        feeder.setPaused(false)
        #expect(feeder.isFeeding)
        await feeder.handBack()
        #expect(!feeder.isFeeding)
        #expect(system.ran("sketchybar", "--set", "cpu", "update_freq=3"))
    }

    @Test func practiceModeNeverFeedsTheBar() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "orbit-feed-\(UUID().uuidString)")
        let feeder = BarFeeder(ctx: SystemContext.make(mode: .practice, paths: Paths(home: home)))
        feeder.update(running: true, barPID: 42, bar: BarSettings(), palette: palette)
        #expect(!feeder.isFeeding)
    }

    @Test func eachUpdateSendsWhatChangedInOneCall() async throws {
        let system = FakeSystem()
        let feeder = try feeder(system)
        feeder.setPaused(true)  // ticked by hand below, not by the timer
        feeder.update(running: true, barPID: 42, bar: BarSettings(), palette: palette)
        await feeder.tick()
        let first = try #require(system.commands.last)
        // CPU needs two readings; memory and the clock go straight away, and their scripts slow down.
        #expect(first.arguments.contains("memory") && first.arguments.contains("clock") && !first.arguments.contains("cpu"))
        #expect(first.arguments.filter { $0 == "update_freq=60" }.count == 2)
        try await Task.sleep(for: .milliseconds(20))
        await feeder.tick()
        let second = try #require(system.commands.last)
        #expect(second.arguments.prefix(2) == ["--set", "cpu"])
        #expect(!second.arguments.contains("clock"))
        #expect(system.commands.count == 2)
    }

    @Test func aBarThatStopsAnsweringIsLeftAloneUntilFoundAgain() async throws {
        let system = FakeSystem()
        system.answer(CommandResult(status: 1, stdout: "", stderr: "[!] sketchybar: could not connect", ok: false)) {
            FakeSystem.name($0) == "sketchybar"
        }
        let feeder = try feeder(system)
        feeder.setPaused(true)
        feeder.update(running: true, barPID: 42, bar: BarSettings(), palette: palette)
        for _ in 0..<3 { await feeder.tick() }
        let sent = system.commands.count
        await feeder.tick()
        #expect(system.commands.count == sent)
        feeder.update(running: true, barPID: 43, bar: BarSettings(), palette: palette)
        await feeder.tick()
        #expect(system.commands.count == sent + 1)
    }
}

@Suite struct BarSpaceTests {
    @Test func aTallerBarMovesTheRoomTilingLeavesForIt() async throws {
        let system = FakeSystem()
        system.load(Helper.sketchybar.label)
        system.load(Helper.yabai.label)
        let actions = Actions(try sandboxContext(system))
        var bar = BarSettings()
        bar.height = 40
        #expect(try await actions.applyBar(bar).ok)
        #expect(system.ran("yabai", "-m", "config", "external_bar", "all:46:0"))
        #expect(system.ran("sketchybar", "--reload"))
    }

    @Test func otherBarChangesLeaveTilingAlone() async throws {
        let system = FakeSystem()
        system.load(Helper.sketchybar.label)
        system.load(Helper.yabai.label)
        let actions = Actions(try sandboxContext(system))
        var bar = BarSettings()
        bar.showSpotify = false
        #expect(try await actions.applyBar(bar).ok)
        #expect(!system.commands.contains { FakeSystem.name($0) == "yabai" && $0.arguments.contains("external_bar") })
    }
}

@Suite struct BarV2ActionTests {
    @Test func aBarAtTheBottomKeepsRoomThere() async throws {
        let system = FakeSystem()
        system.load(Helper.sketchybar.label)
        system.load(Helper.yabai.label)
        let ctx = try sandboxContext(system)
        var bar = BarSettings()
        bar.position = .bottom
        #expect(try await Actions(ctx).applyBar(bar).ok)
        #expect(system.ran("yabai", "-m", "config", "external_bar", "all:0:40"))
        #expect(try String(contentsOf: ctx.paths.sketchybarrc, encoding: .utf8).contains("position=bottom"))
    }

    @Test func theGitItemGetsItsScriptAndYabaisNudge() async throws {
        let system = FakeSystem()
        system.load(Helper.sketchybar.label)
        system.load(Helper.yabai.label)
        let ctx = try sandboxContext(system)
        var bar = BarSettings()
        bar.showGit = true
        #expect(try await Actions(ctx).applyBar(bar).ok)
        #expect(system.ran("yabai", "-m", "signal", "--add", "label=orbit-bar-focus", "event=window_focused",
                           "action=\(Tool.sketchybar) --trigger window_focus"))
        let plugin = ctx.paths.sketchybarDir.appending(path: "plugins/git.sh")
        #expect(FileManager.default.isExecutableFile(atPath: plugin.path(percentEncoded: false)))
    }

    @Test func aPluginYouChangedIsNeverReplaced() async throws {
        let system = FakeSystem()
        let ctx = try sandboxContext(system)
        let plugin = ctx.paths.sketchybarDir.appending(path: "plugins/disk.sh")
        try FileManager.default.createDirectory(at: plugin.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/zsh\n# mine\n".utf8).write(to: plugin)
        var bar = BarSettings()
        bar.showDisk = true
        #expect(try await Actions(ctx).applyBar(bar).ok)
        #expect(try String(contentsOf: plugin, encoding: .utf8) == "#!/bin/zsh\n# mine\n")
    }
}

@Suite struct FloatingAppsTests {
    @Test func floatingAppsChangeLiveAndUndoPutsThemBack() async throws {
        let system = FakeSystem()
        system.load(Helper.yabai.label)
        let ctx = try sandboxContext(system)
        let actions = Actions(ctx)
        let before = ctx.store.settings.floatingApps
        let outcome = try await actions.applyFloatingApps(before + ["Preview"])
        #expect(outcome.ok)
        #expect(system.ran("yabai", "-m", "rule", "--remove", "orbit-floating"))
        #expect(system.commands.contains { $0.arguments.contains("label=orbit-floating") && $0.arguments.last == "manage=off" })
        #expect(system.ran("yabai", "-m", "rule", "--apply", "orbit-floating"))
        #expect(try String(contentsOf: ctx.paths.yabairc, encoding: .utf8).contains("|Preview)$"))
        _ = await actions.undo(outcome.undo)
        #expect(ctx.store.settings.floatingApps == before)
    }
}
