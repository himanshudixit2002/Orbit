import Foundation
import OrbitCore
@testable import OrbitPlatform
import Testing

@Suite struct StorageTests {
    func make(_ url: URL, bytes: Int = 4096) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 1, count: bytes).write(to: url)
    }

    @Test func areasAreMeasuredAndPrivateFoldersLeftAloneWithoutFullDiskAccess() async throws {
        let ctx = try sandboxContext()
        let system = ctx.paths.home.appending(path: "system-root")
        try make(system.appending(path: "Applications/Big.app/Contents/MacOS/Big"), bytes: 400_000)
        try make(ctx.paths.at("Developer/Products/App/main.swift"), bytes: 200_000)
        try make(ctx.paths.at(".gradle/caches/x.jar"), bytes: 100_000)
        try make(ctx.paths.at("Library/Caches/com.example/cache.db"), bytes: 50_000)
        try make(ctx.paths.at("Library/Containers/com.example.app/Data/secret.db"), bytes: 300_000)
        try make(ctx.paths.at("Desktop/notes.txt"), bytes: 300_000)
        try make(ctx.paths.at("Models/model.bin"), bytes: 150_000)
        let probe = StorageProbe(ctx, systemRoot: system)
        let areas = await probe.measure(fullAccess: false).areas
        func size(_ kind: StorageArea.Kind) -> Int64 { areas.first { $0.kind == kind }?.size ?? -1 }
        #expect(size(.apps) >= 400_000 && size(.projects) >= 200_000 && size(.developer) >= 100_000 && size(.home) >= 150_000)
        // Apps' data without other apps' containers, and your own folders not looked into at all.
        #expect(size(.appData) >= 50_000 && size(.appData) < 300_000)
        #expect(areas.first { $0.kind == .files }?.hidden == true)
        let open = await probe.measure(fullAccess: true).areas
        #expect(open.first { $0.kind == .files }?.size ?? 0 >= 300_000)
        #expect(open.first { $0.kind == .appData }?.size ?? 0 >= 350_000)
    }

    @Test func bigFilesAreFoundOnTheWay() throws {
        let folder = try tempHome().home.appending(path: "Movies")
        try make(folder.appending(path: "trip.mov"), bytes: 300_000)
        try make(folder.appending(path: "note.txt"), bytes: 1_000)
        let walked = StorageProbe.walk(folder, collectingFrom: 100_000)
        #expect(walked.size >= 301_000)
        #expect(walked.large.map(\.name) == ["trip.mov"])
        #expect(StorageProbe.walk(folder, collectingFrom: nil).large.isEmpty)
    }

    @Test func appsAreListedWithTheirSizeAndWhoCanRemoveThem() async throws {
        let ctx = try sandboxContext()
        let system = ctx.paths.home.appending(path: "system-root")
        try make(system.appending(path: "Applications/Mine.app/Contents/MacOS/Mine"), bytes: 500_000)
        try make(ctx.paths.at("Applications/Tool.app/Contents/MacOS/Tool"), bytes: 100_000)
        let probe = StorageProbe(ctx, systemRoot: system)
        let apps = await probe.apps()
        #expect(apps.map(\.name) == ["Mine", "Tool"])
        #expect(apps[0].size >= 500_000 && apps[0].removable && !apps[0].running)
        // A scan measures each app on its way, and the list takes those sizes.
        let scan = await probe.measure(fullAccess: false)
        let mine = system.appending(path: "Applications/Mine.app").path(percentEncoded: false)
        #expect(scan.appSizes[mine] == apps[0].size)
        #expect(await probe.apps(sizes: [mine: 42]).first { $0.name == "Mine" }?.size == 42)
    }

    @Test func anAppOrAFileGoesToTheTrashWithUndo() async throws {
        let ctx = try sandboxContext()
        let app = ctx.paths.at("Applications/Old.app")
        try make(app.appending(path: "Contents/MacOS/Old"))
        let file = ctx.paths.at("Movies/trip.mov")
        try make(file)
        let scanner = CleanupScanner(ctx)
        let gone = scanner.trash([.app(InstalledAppSize(name: "Old", path: app.path(percentEncoded: false), bundleID: "com.example.old",
                                                        size: 4096, lastUsed: nil, removable: true, running: false)),
                                  .file(LargeFile(path: file.path(percentEncoded: false), size: 4096, modified: nil))])
        #expect(gone.ok)
        #expect(!FileManager.default.fileExists(atPath: app.path(percentEncoded: false)) && !FileManager.default.fileExists(atPath: file.path(percentEncoded: false)))
        #expect(gone.undo.count == 2)
        _ = await Actions(ctx).undo(gone.undo)
        #expect(FileManager.default.fileExists(atPath: app.path(percentEncoded: false)) && FileManager.default.fileExists(atPath: file.path(percentEncoded: false)))
    }

    @Test func dockersDataIsOnlyMeasuredWithFullDiskAccess() throws {
        guard !FileManager.default.fileExists(atPath: "/Applications/Docker.app") else { return }
        var readings = try sandboxContext().readings
        readings.fullDiskAccess = { false }
        let paths = try tempHome()
        try make(paths.at("Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw"), bytes: 200_000)
        try make(paths.at("Library/Group Containers/group.com.docker/settings.json"))
        let store = StateStore(root: paths.support)
        let log = PracticeLog()
        let closed = SystemContext(mode: .live, paths: paths, uid: 501, executor: FakeSystem(), files: SandboxFileStore(paths: paths),
                                   prefs: PracticePreferences(log: log), practiceLog: log, store: store,
                                   activity: ActivityLog(root: store.root), readings: readings)
        let unseen = try #require(CleanupScanner(closed).dockerLeftovers().first)
        #expect(unseen.safety == .guideOnly && unseen.size == 0 && unseen.urls.count == 2)
        readings.fullDiskAccess = { true }
        let open = SystemContext(mode: .live, paths: paths, uid: 501, executor: FakeSystem(), files: SandboxFileStore(paths: paths),
                                 prefs: PracticePreferences(log: log), practiceLog: log, store: store,
                                 activity: ActivityLog(root: store.root), readings: readings)
        let seen = try #require(CleanupScanner(open).dockerLeftovers().first)
        #expect(seen.safety == .yourCall && seen.size >= 200_000)
    }

    @Test func downloadedBrowsersAndRuntimesAreOffered() async throws {
        let ctx = try sandboxContext()
        try make(ctx.paths.at(".cache/codex-runtimes/node/bin/node"), bytes: 11_000_000)
        try make(ctx.paths.at(".cache/puppeteer/chrome/Chrome"), bytes: 11_000_000)
        let items = await CleanupScanner(ctx).scan(includeDownloads: false)
        let found = items.filter { ["Codex runtimes", "Puppeteer's browsers"].contains($0.title) }
        #expect(found.count == 2 && found.allSatisfy { $0.safety == .downloadsAgain && $0.suggested })
        #expect(found.first { $0.title == "Codex runtimes" }?.appMustBeQuit == "com.openai.codex")
    }

    @Test func stoppingColimaCanBeUndone() async throws {
        let system = FakeSystem()
        let ctx = try sandboxContext(system)
        let stopped = await Actions(ctx).stopColima()
        #expect(stopped.ok && stopped.undo == [.colima(wasRunning: true)])
        #expect(system.ran("colima", "stop"))
        _ = await Actions(ctx).undo(stopped.undo)
        #expect(system.ran("colima", "start"))
    }

    @Test func memoryIsReadOnThisMac() {
        let memory = StatsSampler.memoryBreakdown()
        #expect(memory.total > 0 && [1, 2, 4].contains(memory.pressure))
        #expect(memory.apps + memory.wired + memory.compressed + memory.cached + memory.free <= memory.total + memory.total / 10)
    }
}
