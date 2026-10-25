import Foundation
import OrbitCore
@testable import OrbitPlatform
import OrbitShared
@testable import OrbitUI
import Testing

@MainActor
@Suite struct DispatchTests {
    func model(_ scenario: String = "all-on") throws -> AppModel {
        let model = try practiceModel()
        model.status = SnapshotHarness.status(for: scenario)
        return model
    }

    @Test func aSwitchThatsAlreadyRightIsLeftAlone() async throws {
        let model = try model()
        let reply = await model.run(.setFeature(.glow, on: true), source: .shortcut)
        #expect(reply.ok && reply.message == "Window glow is already on.")
        #expect(model.ctx.store.journal.isEmpty)
    }

    @Test func aToggleRunsTheSameChangeAsTheWindowsSwitch() async throws {
        let model = try model()
        let reply = await model.run(.toggleFeature(.glow), source: .control)
        #expect(reply.ok, "\(reply.message)")
        #expect(model.ctx.store.journal.last?.title == "Turned off the window glow")
    }

    @Test func appsHaveNoSwitchToFlip() async throws {
        let reply = await try model().run(.setFeature(.raycast, on: true), source: .shortcut)
        #expect(!reply.ok && reply.message.contains("no on/off switch"))
    }

    @Test func modesGoOnAndOffByName() async throws {
        let model = try model()
        let mode = ModeDefinition(id: "custom-test", name: "Test", symbol: "sparkles", blurb: "", openApps: [], quitApps: [],
                                  hideOthers: false, keepAwake: .off, tilingOn: false)
        model.ctx.store.updateSettings { $0.modes.append(mode) }
        model.settings = model.ctx.store.settings
        #expect(await model.run(.toggleMode("custom-test"), source: .shortcut).message == "Test mode is on.")
        #expect(await model.run(.startMode("custom-test"), source: .shortcut).message == "Test mode is already on.")
        #expect(await model.run(.stopMode, source: .focus).message == "Test mode is off.")
        #expect(await model.run(.stopMode, source: .focus).message == "No mode is on.")
        let unknown = await model.run(.toggleMode("nope"), source: .link)
        #expect(!unknown.ok && unknown.message.hasPrefix("There's no mode called \"nope\""))
    }

    @Test func showingAPageOpensIt() async throws {
        let model = try model()
        let reply = await model.run(.open(.page(.monitor)), source: .link)
        #expect(reply.ok && model.page == .monitor)
        // No window yet: it opens as soon as Orbit can open windows.
        #expect(model.mainWindowWanted)
    }

    @Test func checkingStatusSaysWhatNeedsAttention() async throws {
        let reply = await try model("fresh").run(.checkStatus, source: .shortcut)
        #expect(reply.message.contains(" of 10 are on."))
    }

    @Test func theSnapshotDescribesWhatTheWindowShows() throws {
        let model = try model()
        let snapshot = model.makeSnapshot()
        #expect(snapshot.practice)
        #expect(snapshot.features.count == FeatureID.allCases.count)
        #expect(snapshot.done == model.doneCount)
        #expect(snapshot.modes.map(\.id) == model.settings.modes.map(\.id))
        #expect(snapshot.theme == model.settings.theme)
    }
}

@MainActor
@Suite struct SnapshotStoreTests {
    func home() -> URL { FileManager.default.temporaryDirectory.appending(path: "orbit-shared-\(UUID().uuidString)") }

    @Test func eachCopyOfOrbitHasItsOwnSharedFolder() {
        let home = home()
        #expect(SharedStore(practice: false, home: home).file.path(percentEncoded: false).hasSuffix("/Library/Application Support/Orbit/Shared/snapshot.json"))
        #expect(SharedStore(practice: true, home: home).file.path(percentEncoded: false).hasSuffix("/Orbit/Practice/Shared/snapshot.json"))
    }

    @Test func publishingWritesOnlyWhatChangedAndSaysGoodbyeOnQuit() async throws {
        let store = SharedStore(practice: true, home: home())
        let reloads = Locked(0)
        let publisher = SnapshotPublisher(store: store) { reloads.withLock { $0 += 1 } }
        var snapshot = OrbitSnapshot(features: [OrbitSnapshot.Feature(id: .tiling, state: .on)], theme: .nord)
        publisher.publish(snapshot)
        snapshot.written = Date()
        publisher.publish(snapshot)   // nothing new, and not due yet
        for _ in 0..<200 where reloads.current == 0 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(store.load()?.theme == .nord)
        #expect(reloads.current == 1)
        publisher.stopped()
        #expect(store.load()?.running == false)
        #expect(reloads.current == 2)
    }
}

@MainActor
@Suite struct FocusFilterTests {
    func model() throws -> AppModel {
        let model = try practiceModel()
        model.status = SnapshotHarness.status(for: "all-on")
        model.focusDefaults = UserDefaults(suiteName: "orbit-focus-\(UUID().uuidString)")!
        for id in ["custom-a", "custom-b"] {
            let mode = ModeDefinition(id: id, name: id.capitalized, symbol: "sparkles", blurb: "", openApps: [], quitApps: [],
                                      hideOthers: false, keepAwake: .off, tilingOn: false)
            model.ctx.store.updateSettings { $0.modes.append(mode) }
        }
        model.settings = model.ctx.store.settings
        return model
    }

    @Test func aFocusStartsItsModeAndStopsItWhenItEnds() async throws {
        let model = try model()
        await model.focusChanged(to: "custom-a")
        #expect(model.modes.active?.modeID == "custom-a")
        await model.focusChanged(to: nil)
        #expect(model.modes.active == nil)
    }

    @Test func aModeTheUserChoseSinceIsLeftOn() async throws {
        let model = try model()
        await model.focusChanged(to: "custom-a")
        await model.modes.toggle(model.settings.modes.first { $0.id == "custom-b" }!)
        await model.focusChanged(to: nil)
        #expect(model.modes.active?.modeID == "custom-b")
    }
}

@MainActor
@Suite struct PaletteTests {
    func model() throws -> AppModel {
        let model = try practiceModel()
        model.status = SnapshotHarness.status(for: "all-on")
        return model
    }

    @Test func switchesSayWhichWayTheyWillGo() throws {
        let model = try model()
        let titles = model.paletteItems().map(\.title)
        #expect(titles.contains("Turn off window tiling"))
        #expect(!titles.contains("Turn on window tiling"))
        #expect(!titles.contains("Switch to \(model.palette.name)"))
        #expect(titles.contains("Start Focus mode"))
        #expect(titles.contains("Open Shortcuts"))
    }

    @Test func typingFindsTheBestMatchFirst() throws {
        let items = try model().paletteItems()
        #expect(PaletteFilter.results("nord", in: items).first?.title == "Switch to Nord")
        #expect(PaletteFilter.results("turn off glow", in: items).first?.title == "Turn off the window glow")
        #expect(PaletteFilter.results("monitor", in: items).first?.title == "Open Monitor")
        #expect(PaletteFilter.results("", in: items).count == 8)
        #expect(PaletteFilter.results("zzzz", in: items).isEmpty)
    }

    @Test func onlyNewProblemsAreNoticed() throws {
        let model = try model()
        #expect(model.noticeNewAttention().isEmpty)   // the first check: nothing is new
        model.status = SnapshotHarness.status(for: "fresh")
        let new = model.noticeNewAttention()
        #expect(Set(new) == Set(model.attention))
        #expect(model.noticeNewAttention().isEmpty)   // already known
    }
}
