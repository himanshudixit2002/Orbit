import Foundation
import OrbitCore
@testable import OrbitPlatform
import Testing

@Suite struct ActivityLogTests {
    func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "orbit-activity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func theLogSurvivesARestartAndStaysShort() throws {
        let root = try folder()
        let log = ActivityLog(root: root)
        for n in 1...(ActivityLog.limit + 250) { log.record(ActivityRecord(.command, "command \(n)")) }
        let reopened = ActivityLog(root: root)
        let newest = reopened.recent(3).map(\.title)
        #expect(newest == ["command \(ActivityLog.limit + 250)", "command \(ActivityLog.limit + 249)", "command \(ActivityLog.limit + 248)"])
        let lines = try String(contentsOf: log.file, encoding: .utf8).split(separator: "\n").count
        #expect(lines <= ActivityLog.limit + 200)
    }

    @Test func changesAndFailuresAreLoggedButQuietReadsAreNot() async throws {
        let system = FakeSystem()
        system.answer(CommandResult(status: 1, stderr: "boom", ok: false)) { FakeSystem.name($0) == "pluginkit" }
        let log = ActivityLog(root: try folder())
        let executor = LoggingExecutor(system, log: log)
        _ = await executor.run(Commands.launchctlPrintDisabled(uid: 501))
        _ = await executor.run(Commands.launchctlKickstart(Helper.borders.label, uid: 501))
        _ = await executor.run(Commands.pluginkitMatch("org.example.quicklook"))
        let titles = log.recent(10).map(\.title)
        #expect(titles.count == 2)
        #expect(titles.contains { $0.hasPrefix("Start ") })
        #expect(log.recent(10).contains { !$0.ok && $0.detail == "boom" })
    }

    @Test func aSaveThatFailsIsReported() throws {
        // A file where the state folder should be: nothing can be saved inside it.
        let blocked = try folder().appending(path: "not-a-folder")
        try Data("x".utf8).write(to: blocked)
        let store = StateStore(root: blocked)
        store.updateSettings { $0.themeTmux = true }
        #expect(store.saveProblem?.hasPrefix("Couldn't save settings.json") == true)
    }
}
