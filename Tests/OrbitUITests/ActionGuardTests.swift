import Foundation
import OrbitCore
@testable import OrbitPlatform
@testable import OrbitUI
import Testing

/// A practice-mode model in a throwaway home folder that never checks the real Mac.
@MainActor
func practiceModel() throws -> AppModel {
    let home = FileManager.default.temporaryDirectory.appending(path: "orbit-ui-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    let model = AppModel(ctx: SystemContext.make(mode: .practice, paths: Paths(home: home)))
    model.isSnapshot = true
    return model
}

@MainActor
@Suite struct ActionGuardTests {
    @Test func aDoubleClickRunsTheChangeOnce() async throws {
        let model = try practiceModel()
        let runs = Locked(0)
        let work: @Sendable (WritePolicy) async throws -> ActionOutcome = { _ in
            runs.withLock { $0 += 1 }
            try await Task.sleep(for: .milliseconds(200))
            return ActionOutcome(ok: true, message: "Done.", undo: [.gitConfig(key: "delta.syntax-theme", value: nil)])
        }
        async let first = model.performNow("menuBar", "Turned off the new menu bar", quiet: true, work)
        async let second = model.performNow("menuBar", "Turned off the new menu bar", quiet: true, work)
        let worked = await [first, second].filter { $0.ok }.count
        #expect(runs.current == 1)
        #expect(worked == 1)
        #expect(model.ctx.store.journal.count == 1)
        #expect(!model.isBusy("menuBar"))
    }

    @Test func anEditedFileFreesTheChangeAsSoonAsOrbitAsks() async throws {
        let model = try practiceModel()
        let policies = Locked<[WritePolicy]>([])
        model.perform("tiling", "Turned on window tiling") { policy in
            policies.withLock { $0.append(policy) }
            if policy == .askIfEdited { throw EditedByHand(file: .yabairc, proposed: "# Orbit's version\n") }
            return ActionOutcome(ok: true, message: "Done.")
        }
        for _ in 0..<400 where model.conflict == nil { try await Task.sleep(for: .milliseconds(5)) }
        let conflict = try #require(model.conflict)
        // The user may answer straight away: the change must not still count as running.
        #expect(!model.isBusy("tiling"))
        await conflict.retry()
        #expect(policies.current == [.askIfEdited, .overwrite([.yabairc])])
    }

    @Test func rapidRequestsEndOnTheNewestOne() async throws {
        let model = try practiceModel()
        let applied = Locked<[Int]>([])
        for n in 1...20 {
            model.perform("glow", "Changed the glow") { _ in
                applied.withLock { $0.append(n) }
                try await Task.sleep(for: .milliseconds(100))
                return ActionOutcome(ok: true, message: "Glow updated.")
            }
        }
        for _ in 0..<600 where applied.current.last != 20 || model.isBusy("glow") {
            try await Task.sleep(for: .milliseconds(10))
        }
        // The first ran straight away; of the rest, only the newest (where the drag ended) ran after it.
        #expect(applied.current == [1, 20])
    }
}

@MainActor
@Suite struct FailureRecordTests {
    @Test func aChangeThatFailsShowsUpInTheHistoryWithoutAnUndo() async throws {
        let model = try practiceModel()
        let result = await model.performNow("glow", "Turned on the window glow", quiet: true) { _ in
            ActionOutcome(ok: false, message: "Couldn't start the window glow: Error: Formula not installed.")
        }
        #expect(!result.ok)
        let entry = try #require(model.ctx.store.journal.last)
        #expect(entry.failed && entry.actions.isEmpty)
        #expect(entry.message == "Couldn't start the window glow: Error: Formula not installed.")
        #expect(model.ctx.activity.recent(1).first?.ok == false)
    }
}

@MainActor
@Suite struct InterruptedChangeTests {
    @Test func aChangeUnderWayIsNotedThenCleared() async throws {
        let model = try practiceModel()
        let store = model.ctx.store
        let during = Locked<[InflightChange]>([])
        _ = await model.performNow("glow", "Turned on the window glow", quiet: true) { _ in
            during.withLock { $0 = store.inflight }
            return ActionOutcome(ok: true, message: "Done.", undo: [.gitConfig(key: "delta.syntax-theme", value: nil)])
        }
        #expect(during.current.map(\.title) == ["Turned on the window glow"])
        #expect(store.inflight.isEmpty)
        #expect(store.journal.last?.id == during.current.first?.id)
    }

    @Test func orbitStoppedMidChangeShowsItAsInterruptedNextTime() throws {
        let model = try practiceModel()
        let id = UUID()
        model.ctx.store.beginChange(id, title: "Changed the theme")
        model.ctx.store.noteSteps([.gitConfig(key: "delta.syntax-theme", value: "old")], change: id)
        // Orbit opens again over the same state.
        let next = AppModel(ctx: SystemContext.make(mode: .practice, paths: model.ctx.paths))
        let entry = try #require(next.journal.last)
        #expect(entry.id == id && entry.outcome == .interrupted && entry.actions.count == 1)
        #expect(next.ctx.activity.recent(1).first?.title == "Changed the theme")
        #expect(next.ctx.store.inflight.isEmpty)
    }

    @Test func quittingWaitsForAChangeUnderWay() async throws {
        let model = try practiceModel()
        let lane = model.ctx.lane
        let slow = Task { await lane.run("A slow change") { try? await Task.sleep(for: .milliseconds(400)) } }
        for _ in 0..<100 where !model.isChanging { try await Task.sleep(for: .milliseconds(5)) }
        #expect(model.isChanging)
        #expect(await model.finishChanges(within: .milliseconds(30)) == false)
        #expect(await model.finishChanges(within: .seconds(5)))
        await slow.value
        #expect(!model.isChanging)
    }

    @Test func aModeLeftOnIsStillOnAfterOrbitRestarts() async throws {
        let model = try practiceModel()
        let mode = ModeDefinition(id: "custom-test", name: "Test", symbol: "sparkles", blurb: "", openApps: [], quitApps: [],
                                  hideOthers: false, keepAwake: .display, tilingOn: false)
        model.ctx.store.updateSettings { $0.modes.append(mode) }
        await model.modes.toggle(mode)
        #expect(model.modes.active?.modeID == "custom-test")
        let next = AppModel(ctx: SystemContext.make(mode: .practice, paths: model.ctx.paths))
        #expect(next.modes.active?.modeID == "custom-test")
        // Practice mode only notes the keep-awake hold it would take up again.
        next.modes.resume()
        #expect(next.ctx.practiceLog.all.contains { $0.summary == "Would keep the screen awake" })
        await next.modes.stop()
        #expect(next.modes.active == nil)
        #expect(AppModel(ctx: SystemContext.make(mode: .practice, paths: model.ctx.paths)).modes.active == nil)
    }
}

@MainActor
@Suite struct AppCatalogTests {
    @Test func pickersListAppsInTheHomeApplicationsFolderToo() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "orbit-apps-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home.appending(path: "Applications/Zed Preview.app"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home.appending(path: "Applications/Notes folder"), withIntermediateDirectories: true)
        let apps = AppCatalog.scan(home: home)
        #expect(apps.contains(InstalledApp(name: "Zed Preview", path: home.appending(path: "Applications").path(percentEncoded: false) + "/Zed Preview.app")))
        #expect(!apps.contains { $0.name == "Notes folder" })
        #expect(apps.contains { $0.name == "Finder" })
        #expect(apps.map(\.name) == apps.map(\.name).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending })
    }

    @Test func theListIsFoundOffTheMainThreadAndKept() async throws {
        let catalog = AppCatalog()
        catalog.refresh()
        for _ in 0..<400 where catalog.apps.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        #expect(catalog.apps.contains { $0.name == "Finder" })
    }
}

@MainActor
@Suite struct QuietLoginTests {
    @Test func orbitAsksToOpenAtLoginOnlyWhenItShould() {
        // Installed, and the user hasn't said no: yes, unless macOS already has it or waits for the user's OK.
        #expect(AppModel.shouldRegisterAtLogin(choice: nil, status: .notRegistered, installed: true))
        #expect(AppModel.shouldRegisterAtLogin(choice: true, status: .notFound, installed: true))
        #expect(!AppModel.shouldRegisterAtLogin(choice: nil, status: .enabled, installed: true))
        #expect(!AppModel.shouldRegisterAtLogin(choice: nil, status: .requiresApproval, installed: true))
        #expect(!AppModel.shouldRegisterAtLogin(choice: false, status: .notRegistered, installed: true))
        // A copy run from anywhere but /Applications (a build folder, say) never registers itself.
        #expect(!AppModel.shouldRegisterAtLogin(choice: nil, status: .notRegistered, installed: false))
    }

    @Test func theUsersChoiceIsKept() throws {
        let model = try practiceModel()
        #expect(model.settings.openAtLogin == nil)
        model.setLaunchAtLogin(false)
        #expect(model.ctx.store.settings.openAtLogin == false)
        #expect(model.practiceLog.contains { $0.summary == "Would stop opening Orbit when you log in" })
    }

    @Test func chartsReadOutWhatTheyShow() {
        #expect(ChartSummary.levels([0.1, 0.3, 0.2], as: percent) == "now 20%, average 20%, highest 30%")
        #expect(ChartSummary.levels([], as: percent) == "No readings yet")
        #expect(ChartSummary.cores([0.55, 0.05, 0.3]) == "3 cores: busiest 55%, quietest 5%")
    }
}
