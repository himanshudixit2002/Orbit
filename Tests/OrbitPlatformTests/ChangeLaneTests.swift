import Foundation
import OrbitCore
@testable import OrbitPlatform
import Testing

@Suite struct ChangeLaneTests {
    @Test func changesRunOneAtATimeInOrder() async {
        let lane = ChangeLane()
        let log = Locked<[String]>([])
        await withTaskGroup(of: Void.self) { group in
            for n in 0..<8 {
                group.addTask {
                    // Asked for in order, slightly apart, each holding the lane for a while.
                    try? await Task.sleep(for: .milliseconds(n * 3))
                    await lane.run("change \(n)") {
                        log.withLock { $0.append("start \(n)") }
                        try? await Task.sleep(for: .milliseconds(15))
                        log.withLock { $0.append("end \(n)") }
                    }
                }
            }
        }
        let entries = log.current
        // Never two at once: every start is followed by its own end.
        for i in stride(from: 0, to: entries.count, by: 2) {
            #expect(entries[i].dropFirst(6) == entries[i + 1].dropFirst(4))
        }
        #expect(entries.filter { $0.hasPrefix("start") } == (0..<8).map { "start \($0)" })
        #expect(lane.isIdle)
    }

    @Test func aChangeThatAsksForAnotherDoesntWaitForItself() async {
        let lane = ChangeLane()
        let inner = await lane.run("outer") { await lane.run("inner") { 42 } }
        #expect(inner == 42)
    }

    @Test func changesThatShareFilesNoLongerTrampleEachOther() async throws {
        let system = FakeSystem()
        system.load(Helper.borders.label)
        let ctx = try sandboxContext(system)
        let actions = Actions(ctx)
        // A theme change and a glow change at the same moment both rewrite bordersrc.
        var wider = ctx.store.settings.glow
        wider.width = 11
        let glow = wider
        await withTaskGroup(of: Void.self) { group in
            group.addTask { _ = await ctx.lane.run("theme") { try? await actions.applyTheme(.nord, tmux: false) } }
            group.addTask { _ = await ctx.lane.run("glow") { try? await actions.applyGlow(glow) } }
        }
        let final = ctx.store.settings
        let onDisk = try #require(ctx.files.read(ctx.paths.bordersrc))
        #expect(String(decoding: onDisk, as: UTF8.self) == BordersConfig.render(final.glow, palette: final.palette))
        #expect(final.theme == .nord && final.glow.width == 11)
    }
}
