import Foundation
import OrbitCore
@testable import OrbitPlatform
import Testing

@MainActor
@Suite struct ModesV2Tests {
    @Test func aModeChangesTheThemeAndTilingAndPutsBothBack() async throws {
        let system = FakeSystem()
        let ctx = try sandboxContext(system)
        let engine = ModeEngine(ctx: ctx)
        var mode = ModeDefinition.newCustom()
        mode.name = "Study"
        mode.theme = .nord
        mode.tiling = .on
        mode.timerMinutes = 25
        let record = await engine.apply(mode)
        #expect(ctx.store.settings.theme == .nord)
        #expect(system.service(Helper.yabai.label)?.running == true)
        #expect(!record.undo.isEmpty && record.notes.isEmpty)
        #expect(record.endsAt.map { abs($0.timeIntervalSince(record.started) - 1500) < 1 } == true)
        await engine.revert(record)
        #expect(ctx.store.settings.theme == .tokyoNight)
        #expect(system.service(Helper.yabai.label) == nil || system.service(Helper.yabai.label)?.running == false)
    }

    @Test func recordsFromOrbitOneStillLoad() throws {
        let old = #"{"modeID": "focus", "started": "2026-10-25T08:00:00Z", "closedApps": [], "hiddenApps": ["com.tinyspeck.slackmacgap"], "startedTiling": false}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let record = try decoder.decode(ModeRecord.self, from: Data(old.utf8))
        #expect(record.modeID == "focus" && record.hiddenApps.count == 1 && record.undo.isEmpty && !record.bySchedule)
    }
}
