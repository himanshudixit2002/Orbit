import Foundation
import OrbitCore
@testable import OrbitPlatform
import Testing

@Suite struct ProbeCostTests {
    /// A Mac with every helper running and Karabiner's driver and Quick Look already approved.
    func settledSystem() -> FakeSystem {
        let system = FakeSystem()
        for helper in Helper.allCases where helper != .sorter { system.load(helper.label) }
        system.answer(CommandResult(status: 0, stdout: "*\t*\tG43BCU2T37\torg.pqrs.Karabiner-DriverKit-VirtualHIDDevice (1.8.0/1.8.0)\tKarabiner\t[activated enabled]\n", ok: true)) {
            FakeSystem.name($0) == "systemextensionsctl"
        }
        system.answer(CommandResult(status: 0, stdout: "    org.sbarex.SourceCodeSyntaxHighlight.QuickLookExtension(2.1.32)\n", ok: true)) {
            FakeSystem.name($0) == "pluginkit"
        }
        return system
    }

    @Test func aSettledMacIsCheckedWithOneQuestionToLaunchd() async throws {
        let system = settledSystem()
        let probes = Probes(try sandboxContext(system))
        let first = await probes.all()
        let before = system.commands.count
        let second = await probes.all()
        let asked = system.commands.dropFirst(before).map { FakeSystem.name($0) + " " + $0.arguments.joined(separator: " ") }
        #expect(asked == ["launchctl print-disabled gui/501"])
        #expect(second.sameReadings(as: first))
        #expect(first.state(.glow) == .on && first.state(.menuBar) == .on)
    }

    @Test func helpersThatArentInstalledCostNothing() async throws {
        let system = FakeSystem()
        let ctx = try sandboxContext(system)
        var readings = ctx.readings
        readings.installed = { _ in false }
        var bare = ctx
        bare.readings = readings
        let status = await Probes(bare).all()
        #expect(!system.ran("launchctl", "print", "gui/501/\(Helper.borders.label)"))
        #expect(!system.ran("launchctl", "print", "gui/501/\(Helper.sketchybar.label)"))
        #expect(status.state(.glow) == .notInstalled)
    }

    @Test func aDeepCheckAsksAgain() async throws {
        let system = settledSystem()
        let probes = Probes(try sandboxContext(system))
        _ = await probes.all()
        let before = system.commands.count
        _ = await probes.all(deep: true)
        #expect(system.commands.dropFirst(before).contains { FakeSystem.name($0) == "systemextensionsctl" })
    }
}
