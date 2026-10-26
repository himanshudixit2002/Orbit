import Foundation
import OrbitCore
@testable import OrbitPlatform
import Testing

@Suite struct ChangeLaneTests {
    @Test func changesRunOneAtATimeInOrder() async {
        let lane = ChangeLane()
        let log = Locked<[String]>([])
        // The lane is held while the changes queue up, each asked for only once the one before is
        // queued: their order doesn't depend on how quickly a busy Mac wakes anything up.
        let gate = AsyncStream<Void>.makeStream()
        let holder = Task { await lane.run("hold") { for await _ in gate.stream { break } } }
        while lane.currentTitle != "hold" { await Task.yield() }
        var changes: [Task<Void, Never>] = []
        for n in 0..<8 {
            changes.append(Task {
                await lane.run("change \(n)") {
                    log.withLock { $0.append("start \(n)") }
                    try? await Task.sleep(for: .milliseconds(5))
                    log.withLock { $0.append("end \(n)") }
                }
            })
            while lane.waiting < n + 1 { await Task.yield() }
        }
        gate.continuation.yield()
        gate.continuation.finish()
        await holder.value
        for change in changes { await change.value }
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
