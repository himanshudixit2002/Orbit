import Foundation
import OrbitCore
@testable import OrbitPlatform
import Testing

@Suite struct CleanupV2Tests {
    func make(_ url: URL, bytes: Int = 1, age days: Double = 0) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 1, count: bytes).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-days * 86_400)], ofItemAtPath: url.path(percentEncoded: false))
    }

    func age(_ url: URL, days: Double) throws {
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-days * 86_400)], ofItemAtPath: url.path(percentEncoded: false))
    }

    @Test func onlyProjectsLeftAloneForAMonthOfferTheirBuildFolders() throws {
        let ctx = try sandboxContext()
        let developer = ctx.paths.developer
        try make(developer.appending(path: "Products/Old/package.json"), age: 40)
        try make(developer.appending(path: "Products/Old/node_modules/x/index.js"), bytes: 4096)
        try make(developer.appending(path: "Products/Old/ios/Pods/Manifest.lock"), bytes: 4096)
        try age(developer.appending(path: "Products/Old/ios"), days: 40)
        try make(developer.appending(path: "Products/Fresh/package.json"))
        try make(developer.appending(path: "Products/Fresh/node_modules/x/index.js"), bytes: 4096)
        let items = CleanupScanner(ctx).idleBuildFolders()
        #expect(Set(items.map(\.title)) == ["Products/Old: node_modules", "Products/Old: Pods"])
        #expect(items.allSatisfy { $0.kind == .projects && $0.safety == .rebuilds })
    }

    @Test func gradleVersionsNoProjectWantsAreOffered() throws {
        let ctx = try sandboxContext()
        let dists = ctx.paths.at(".gradle/wrapper/dists")
        try make(dists.appending(path: "gradle-8.12-all/x/gradle.zip"))
        try make(dists.appending(path: "gradle-7.0-all/x/gradle.zip"))
        try make(ctx.paths.developer.appending(path: "Products/App/android/gradle/wrapper/gradle-wrapper.properties"))
        try Data(#"distributionUrl=https\://services.gradle.org/distributions/gradle-8.12-all.zip"#.utf8)
            .write(to: ctx.paths.developer.appending(path: "Products/App/android/gradle/wrapper/gradle-wrapper.properties"))
        #expect(CleanupScanner(ctx).gradleVersions().map(\.title) == ["Gradle 7.0-all"])
    }

    @Test func androidAndDockerAndTaggedCachesAreFoundWithTheRightSafety() throws {
        let ctx = try sandboxContext()
        try make(ctx.paths.at("Library/Android/sdk/emulator/emulator"))
        try make(ctx.paths.at("Library/Android/sdk/ndk/27.0.1/source.properties"))
        try make(ctx.paths.at("Library/Containers/com.docker.docker/Data/vms/disk.raw"))
        try make(ctx.paths.at(".cargo/registry/CACHEDIR.TAG"))
        try make(ctx.paths.at("Desktop/.build/CACHEDIR.TAG"))
        let scanner = CleanupScanner(ctx)
        let android = scanner.androidTools()
        #expect(android.map(\.title) == ["Android emulator", "Android NDK 27.0.1"])
        #expect(android.map(\.safety) == [.downloadsAgain, .yourCall])
        if !FileManager.default.fileExists(atPath: "/Applications/Docker.app") {
            #expect(scanner.dockerLeftovers().first?.safety == .yourCall)
        }
        #expect(scanner.taggedCaches().map(\.title) == [".cargo/registry cache"])
        // A virtual device means the emulator is in use.
        try make(ctx.paths.at(".android/avd/Pixel.avd/config.ini"))
        #expect(!scanner.androidTools().contains { $0.title == "Android emulator" })
    }

    @Test func clearingWaitsForAnOpenAppAndUndoesInOneGo() async throws {
        var ctx = try sandboxContext()
        ctx.readings.runningApps = { ["com.google.Chrome"] }
        let cache = ctx.paths.at("Library/Caches/Google/Chrome")
        let other = ctx.paths.at(".npm/_cacache")
        try make(cache.appending(path: "data"))
        try make(other.appending(path: "data"))
        var chrome = CleanupItem(id: cache.path(percentEncoded: false), title: "Chrome cache", detail: "", kind: .caches, urls: [cache], size: 1, symbol: "globe")
        chrome.appMustBeQuit = "com.google.Chrome"
        let npm = CleanupItem(id: other.path(percentEncoded: false), title: "npm download cache", detail: "", kind: .developer, urls: [other], size: 1, symbol: "x")
        let outcome = CleanupScanner(ctx).trash([chrome, npm])
        #expect(outcome.message.hasPrefix("Quit Chrome cache first"))
        #expect(FileManager.default.fileExists(atPath: cache.path(percentEncoded: false)))
        #expect(!FileManager.default.fileExists(atPath: other.path(percentEncoded: false)))
        _ = await Actions(ctx).undo(outcome.undo)
        #expect(FileManager.default.fileExists(atPath: other.path(percentEncoded: false)))
    }
}
