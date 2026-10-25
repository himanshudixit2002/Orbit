import Foundation
import OrbitCore
@testable import OrbitPlatform
import Testing

@Suite struct HelperLifecycleTests {
    @Test func turningTheGlowOnStartsItAndCanBeUndone() async throws {
        let system = FakeSystem()
        let actions = Actions(try sandboxContext(system))
        let outcome = try await actions.setGlow(true)
        #expect(outcome.ok)
        #expect(system.service(Helper.borders.label)?.running == true)
        #expect(outcome.undo.contains(.helper(.borders, wasOn: false)))
        _ = await actions.undo(outcome.undo)
        #expect(system.service(Helper.borders.label) == nil)
    }

    @Test func aHelperThatWontStartSaysWhyAndKeepsItsUndo() async throws {
        let system = FakeSystem()
        system.answer(CommandResult(status: 1, stderr: "Error: Formula `borders` is not installed.", ok: false)) {
            FakeSystem.name($0) == "brew" && $0.arguments.starts(with: ["services", "start"])
        }
        let outcome = try await Actions(try sandboxContext(system)).setGlow(true)
        #expect(!outcome.ok)
        #expect(outcome.message.hasPrefix("Couldn't start the window glow: Error: Formula `borders` is not installed."))
        #expect(outcome.undo.contains { if case .restoreFile = $0 { true } else { false } })
    }

    @Test func aStartThatMacOSIgnoredIsCaught() async throws {
        let system = FakeSystem()
        // The tool says it worked, but launchd never loads the helper.
        system.answer(CommandResult(status: 0, ok: true)) { FakeSystem.name($0) == "brew" }
        let outcome = try await Actions(try sandboxContext(system)).setGlow(true)
        #expect(!outcome.ok)
        #expect(outcome.message.hasPrefix("macOS didn't start the window glow."))
    }

    @Test func turningTilingOffStopsAHelperThatKeepsCrashing() async throws {
        let system = FakeSystem()
        system.load(Helper.yabai.label, running: false, lastExit: 0)
        system.load(Helper.skhd.label)
        let outcome = try await Actions(try sandboxContext(system)).setTiling(false)
        #expect(outcome.ok)
        #expect(system.service(Helper.yabai.label) == nil)
        #expect(system.isDisabled(Helper.yabai.label))
        #expect(system.isDisabled(Helper.skhd.label))
    }

    @Test func tilingSwitchedOffReadsAsOffNotAsAnOldProblem() async throws {
        let system = FakeSystem()
        let ctx = try sandboxContext(system)
        try FileManager.default.createDirectory(at: ctx.paths.launchAgents, withIntermediateDirectories: true)
        try Data("<plist/>".utf8).write(to: ctx.paths.launchAgent(Helper.yabai.label))
        system.disable(Helper.yabai.label)
        system.disable(Helper.skhd.label)
        let status = await Probes(ctx).tiling()
        #expect(status.state == .off)
    }

    @Test func aFullCheckWithTheFakeIsQuick() async throws {
        let system = FakeSystem()
        for helper in Helper.allCases { system.load(helper.label) }
        let probes = Probes(try sandboxContext(system))
        _ = await probes.all()
        let start = ContinuousClock.now
        for _ in 0..<10 { _ = await probes.all() }
        let each = (ContinuousClock.now - start) / 10
        #expect(each < .milliseconds(30), "a full status check took \(each)")
    }
}

@Suite struct WatchdogTests {
    @Test func aCrashedHelperLaunchdWontRestartIsBroughtBack() async throws {
        let system = FakeSystem()
        system.load(Helper.borders.label)
        let ctx = try sandboxContext(system)
        let probes = Probes(ctx)
        let watchdog = Watchdog()
        _ = watchdog.observe(await probes.all(), keepAlive: { _ in KeepAlive() })
        system.crash(Helper.borders.label)
        let verdicts = watchdog.observe(await probes.all(), keepAlive: { _ in KeepAlive() })
        #expect(verdicts[.borders] == .restart(after: 10))
        #expect(await Actions(ctx).kickstart(.borders))
        #expect(system.service(Helper.borders.label)?.running == true)
    }

    @Test func aHelperTheUserSwitchedOffIsNeverTouched() async throws {
        let system = FakeSystem()
        let probes = Probes(try sandboxContext(system))
        let verdicts = Watchdog().observe(await probes.all(), keepAlive: { _ in KeepAlive() })
        #expect(verdicts.isEmpty)
    }
}
