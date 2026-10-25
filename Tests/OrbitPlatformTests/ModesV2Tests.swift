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

@Suite struct DeveloperActionTests {
    @Test func gitInitAddsAGitignoreAndUndoTakesItAway() async throws {
        let system = FakeSystem()
        let ctx = try sandboxContext(system)
        let folder = ctx.paths.developer.appending(path: "Products/App")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: folder.appending(path: "package.json"))
        let project = ProjectInfo(name: "Products/App", url: folder, kind: .node, git: nil)
        let actions = Actions(ctx)
        let outcome = await actions.gitInit(project)
        #expect(outcome.ok)
        #expect(system.ran("git", "-C", folder.path(percentEncoded: false), "init"))
        #expect(try String(contentsOf: folder.appending(path: ".gitignore"), encoding: .utf8).contains("node_modules/"))
        _ = await actions.undo(outcome.undo)
        #expect(!FileManager.default.fileExists(atPath: folder.appending(path: ".gitignore").path(percentEncoded: false)))
        #expect(!system.commands.contains { $0.arguments.contains("commit") || $0.arguments.contains("push") })
    }

    @Test func servicesStartAndStopAtLoginWithUndo() async throws {
        let system = FakeSystem()
        let actions = Actions(try sandboxContext(system))
        let mongo = ServiceInfo(formula: "mongodb-community", running: true, atLogin: true)
        let outcome = await actions.changeService(mongo, .stopAtLogin(keepRunning: true))
        #expect(outcome.ok)
        #expect(system.ran("brew", "services", "stop", "mongodb-community"))
        #expect(system.ran("brew", "services", "run", "mongodb-community"))
        _ = await actions.undo(outcome.undo)
        #expect(system.ran("brew", "services", "start", "mongodb-community"))
    }
}

@Suite struct StopProcessTests {
    func sleeper() throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        try process.run()
        return process
    }

    @Test func onlyYourOwnRunningProcessIsAskedToQuit() async throws {
        let child = try sleeper()
        defer { if child.isRunning { child.terminate() } }
        let actions = Actions(try sandboxContext())
        let port = ListeningPort(pid: child.processIdentifier, command: "sleep", port: 3000)
        #expect(!actions.stopProcess(PortInfo(port: port, owner: .background)).ok)
        #expect(!actions.stopProcess(PortInfo(port: port, owner: .app("Raycast"))).ok)
        #expect(!actions.stopProcess(PortInfo(port: ListeningPort(pid: child.processIdentifier, command: "node", port: 3000), owner: .yours)).ok)
        #expect(child.isRunning)
        #expect(actions.stopProcess(PortInfo(port: port, owner: .yours)).ok)
        for _ in 0..<100 where child.isRunning { try await Task.sleep(for: .milliseconds(20)) }
        #expect(child.terminationReason == .uncaughtSignal && child.terminationStatus == SIGTERM)
    }

    @Test func practiceOnlyWritesItDown() throws {
        let child = try sleeper()
        defer { child.terminate() }
        let ctx = SystemContext.make(mode: .practice, paths: try tempHome())
        let port = ListeningPort(pid: child.processIdentifier, command: "sleep", port: 3000)
        #expect(Actions(ctx).stopProcess(PortInfo(port: port, owner: .yours)).ok)
        #expect(child.isRunning)
        #expect(ctx.practiceLog.all.contains { $0.summary.contains("sleep") })
    }
}

@Suite struct ServiceLoginTests {
    @Test func anOlderLoginFileCountsAsStartingAtLogin() async throws {
        let system = FakeSystem()
        let json = #"[{"name":"mongodb-community","running":true,"loaded":true,"registered":false},{"name":"colima","running":false,"loaded":false,"registered":false}]"#
        system.answer(CommandResult(status: 0, stdout: json, ok: true)) { $0.arguments.starts(with: ["services", "info"]) }
        let ctx = try sandboxContext(system)
        try FileManager.default.createDirectory(at: ctx.paths.launchAgents, withIntermediateDirectories: true)
        try Data("<plist/>".utf8).write(to: ctx.paths.launchAgents.appending(path: "homebrew.mxcl.mongodb-community.plist"))
        let services = await DeveloperProbe(ctx).services()
        #expect(services.first { $0.formula == "mongodb-community" }?.atLogin == true)
        #expect(services.first { $0.formula == "colima" }?.atLogin == false)
    }
}

@Suite struct PracticeRegistryTests {
    @Test func practiceAcceptsWhatTheRealOrbitWrote() throws {
        let paths = try tempHome()
        let live = StateStore(root: paths.support)
        let written = Data("# Orbit's bar\n".utf8)
        live.noteWritten(.sketchybarrc, data: written)
        let practice = StateStore(root: paths.practiceRoot.appending(path: "State"), liveRoot: paths.support)
        #expect(practice.registry.verdict(for: .sketchybarrc, current: written) == .safe)
        #expect(practice.registry.verdict(for: .sketchybarrc, current: Data("# mine\n".utf8)) == .editedByHand)
        // What practice records is its own; the real record is never saved into it.
        practice.noteWritten(.bordersrc, data: Data("x".utf8))
        let saved = try JSONDecoder().decode(FileRegistry.self, from: Data(contentsOf: paths.practiceRoot.appending(path: "State/managed-files.json")))
        #expect(saved.lastWritten.keys.sorted { $0.rawValue < $1.rawValue } == [.bordersrc])
        #expect(saved.alsoWritten.isEmpty)
    }
}
