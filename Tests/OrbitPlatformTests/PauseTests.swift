import Foundation
import OrbitCore
@testable import OrbitPlatform
import Testing

@Suite struct PauseTests {
    func runningEverything(_ system: FakeSystem) {
        for helper in [Helper.yabai, .skhd, .borders, .sketchybar, .sorter] { system.load(helper.label) }
    }

    @Test func pausingSwitchesOffWhatWasOnAndResumeBringsItBack() async throws {
        let system = FakeSystem()
        runningEverything(system)
        let ctx = try sandboxContext(system, prefs: FakePreferences())
        let actions = Actions(ctx)
        _ = await actions.setInstant([.dock], on: true)
        let state = PausedState(features: [.tiling, .glow, .menuBar, .downloads], instant: [.dock])

        let paused = try await actions.pause(state)
        #expect(paused.ok, "\(paused.message)")
        for helper in [Helper.yabai, .skhd, .borders, .sketchybar, .sorter] { #expect(system.service(helper.label) == nil, "\(helper)") }
        #expect(actions.instantGroupsOn().isEmpty)
        #expect(ctx.store.paused == state)
        // It lasts: Orbit opening again (or the Mac restarting) still knows it's paused, and what comes back.
        #expect(StateStore(root: ctx.store.root).paused == state)

        let resumed = try await actions.resume(state)
        #expect(resumed.ok, "\(resumed.message)")
        for helper in [Helper.yabai, .skhd, .borders, .sketchybar, .sorter] { #expect(system.service(helper.label) != nil, "\(helper)") }
        #expect(actions.instantGroupsOn() == [.dock])
        #expect(ctx.store.paused == nil)
    }

    @Test func resumingStartsTheMenuBarBeforeTiling() async throws {
        // Tiling reads its config as it starts: the bar's room has to be in it by then, or tiling's own
        // start undoes the room the bar claims a moment later and windows slide under the bar.
        let system = FakeSystem()
        runningEverything(system)
        let ctx = try sandboxContext(system, prefs: FakePreferences())
        let actions = Actions(ctx)
        let state = PausedState(features: [.tiling, .menuBar])
        _ = try await actions.pause(state)
        _ = try await actions.resume(state)
        let commands = system.commands
        let bar = try #require(commands.firstIndex { FakeSystem.name($0) == "brew" && $0.arguments == ["services", "start", Helper.sketchybar.brewFormula!] })
        let tiling = try #require(commands.firstIndex { FakeSystem.name($0) == "yabai" && $0.arguments.first == "--start-service" })
        #expect(bar < tiling)
        #expect(try String(contentsOf: ctx.paths.yabairc, encoding: .utf8).contains(ctx.store.settings.bar.externalBar(on: true)))
    }

    @Test func tilingKeepsRoomForABarThatIsStillStarting() async throws {
        let system = FakeSystem()
        system.load(Helper.sketchybar.label, running: false)
        let ctx = try sandboxContext(system, prefs: FakePreferences())
        _ = try await Actions(ctx).setTiling(true)
        #expect(try String(contentsOf: ctx.paths.yabairc, encoding: .utf8).contains(ctx.store.settings.bar.externalBar(on: true)))
    }

    @Test func undoingAPauseBringsItAllBack() async throws {
        let system = FakeSystem()
        runningEverything(system)
        let ctx = try sandboxContext(system, prefs: FakePreferences())
        let actions = Actions(ctx)
        // What was off stays off: only what the pause switched off comes back.
        let paused = try await actions.pause(PausedState(features: [.tiling, .glow]))
        #expect(system.service(Helper.sketchybar.label) != nil)
        _ = await actions.undo(paused.undo)
        #expect(system.service(Helper.yabai.label) != nil && system.service(Helper.borders.label) != nil)
        #expect(ctx.store.paused == nil)
        // Pausing what's already off changes nothing but the record.
        let again = try await actions.pause(PausedState(features: []))
        #expect(again.undo == [.pausedState(nil)])
    }

    @Test func aHandEditedTilingConfigIsAskedAboutOnceTheRestArePaused() async throws {
        let system = FakeSystem()
        runningEverything(system)
        let ctx = try sandboxContext(system, prefs: FakePreferences())
        try FileManager.default.createDirectory(at: ctx.paths.yabairc.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("# my own yabairc\n".utf8).write(to: ctx.paths.yabairc)
        let state = PausedState(features: [.glow, .menuBar])
        await #expect(throws: EditedByHand.self) { try await Actions(ctx).pause(state) }
        #expect(system.service(Helper.borders.label) == nil)
        #expect(system.service(Helper.sketchybar.label) != nil)
        #expect(ctx.store.paused == state)
        // With the user's OK the pause runs again and finishes; the glow, already off, is left alone.
        let approved = try await Actions(ctx).pause(state, policy: .overwrite([.yabairc]))
        #expect(approved.ok && system.service(Helper.sketchybar.label) == nil)
    }

    @Test func practicePausesOnlyOnPaper() async throws {
        let ctx = SystemContext.make(mode: .practice, paths: try tempHome())
        let outcome = try await Actions(ctx).pause(PausedState(features: [.glow]))
        #expect(outcome.ok)
        #expect(ctx.practiceLog.all.contains { $0.summary.lowercased().contains("stop") })
        #expect(ctx.store.paused?.features == [.glow])
    }
}
