import Foundation
import OrbitCore
@testable import OrbitPlatform
import Testing

@Suite struct WatcherTests {
    @Test func aChangedConfigFileIsNoticed() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "orbit-watch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let seen = Locked<[String]>([])
        let watcher = FileWatcher(folders: [folder], latency: 0.1) { changed in seen.withLock { $0 += changed } }
        try await Task.sleep(for: .milliseconds(300))
        try Data("yabai -m config layout bsp\n".utf8).write(to: folder.appending(path: "yabairc"))
        let noticed = { seen.current.contains { $0.hasSuffix("/yabairc") } }
        for _ in 0..<60 where !noticed() { try await Task.sleep(for: .milliseconds(50)) }
        #expect(noticed(), "saw only \(seen.current)")
        withExtendedLifetime(watcher) {}
    }

    @Test func aStoppedHelperIsNoticedAtOnce() async throws {
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sleep")
        helper.arguments = ["0.3"]
        try helper.run()
        let stopped = Locked<[Int32]>([])
        let watcher = ExitWatcher { pid in stopped.withLock { $0.append(pid) } }
        watcher.watch([helper.processIdentifier])
        for _ in 0..<60 where stopped.current.isEmpty { try await Task.sleep(for: .milliseconds(50)) }
        #expect(stopped.current == [helper.processIdentifier])
        withExtendedLifetime(watcher) {}
    }
}
