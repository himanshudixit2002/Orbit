import Foundation
@testable import OrbitCore
import Testing

@Suite struct StartupTimerTests {
    let boot = Date(timeIntervalSince1970: 1_800_000_000)

    func looks(_ cpus: [Double], from start: Date) -> [(at: Date, cpu: Double)] {
        cpus.enumerated().map { (start.addingTimeInterval(Double($0.offset + 1) * StartupTimer.every), $0.element) }
    }

    @Test func calmIsThreeQuietLooksInARow() {
        let login = boot.addingTimeInterval(23)
        // Busy, one quiet moment, busy again, then quiet for good.
        let seen = looks([0.7, 0.6, 0.1, 0.5, 0.4, 0.15, 0.1, 0.12, 0.08], from: login)
        #expect(StartupTimer.calm(seen) == seen[5].at)
        #expect(StartupTimer.calm(looks([0.9, 0.8, 0.1, 0.1], from: login)) == nil)
        #expect(StartupTimer.calm([]) == nil)
    }

    @Test func busiestAddsUpAppsAndSiri() {
        let stats = [
            ProcessStat(pid: 10, name: "Claude", path: "/Applications/Claude.app/Contents/MacOS/Claude", memory: 1, cpuTime: 20),
            ProcessStat(pid: 11, parent: 10, name: "node", path: "/opt/homebrew/bin/node", memory: 1, cpuTime: 15),
            ProcessStat(pid: 20, name: "Siri AI", path: "/System/Applications/Siri AI.app/Contents/MacOS/Siri AI", memory: 1, cpuTime: 60),
            ProcessStat(pid: 21, name: "sirittsd", path: "/System/Library/PrivateFrameworks/TextToSpeech.framework/sirittsd", memory: 1, cpuTime: 50),
            ProcessStat(pid: 30, name: "photoanalysisd", path: "/System/Library/PrivateFrameworks/PhotoAnalysis.framework/photoanalysisd", memory: 1, cpuTime: 30),
            ProcessStat(pid: 31, name: "mediaanalysisd", path: "/System/Library/PrivateFrameworks/MediaAnalysis.framework/mediaanalysisd", memory: 1, cpuTime: 12),
            ProcessStat(pid: 32, name: "cfprefsd", path: "/usr/sbin/cfprefsd", memory: 1, cpuTime: 3),
            ProcessStat(pid: 40, name: "quiet", path: "/usr/libexec/quiet", memory: 1, cpuTime: 0)
        ]
        #expect(StartupTimer.busiest(stats) == [.init(name: "Siri", seconds: 110), .init(name: "Photo and video analysis", seconds: 42),
                                                .init(name: "Claude", seconds: 35), .init(name: "cfprefsd", seconds: 3)])
        #expect(StartupTimer.busiest(stats, top: 1).map(\.name) == ["Siri"])
    }

    @Test func whatTheSpeedPageSays() {
        let record = StartupRecord(bootedAt: boot, loginAt: boot.addingTimeInterval(23.4), calmAt: boot.addingTimeInterval(153.9), busiest: [])
        #expect(record.toLogin == 23 && record.toCalm == 130)
        #expect(StartupTimer.summary(record) == "macOS took 23 s to start and log you in, and the Mac was calm 2 min 10 s after that.")
        let before = StartupRecord(bootedAt: boot.addingTimeInterval(-86_400), loginAt: boot.addingTimeInterval(-86_377),
                                   calmAt: boot.addingTimeInterval(-86_100), busiest: [])
        #expect(StartupTimer.comparison(record, before: before) == "2 min 27 s quicker than the restart before.")
        #expect(StartupTimer.comparison(before, before: record) == "2 min 27 s slower than the restart before.")
        let similar = StartupRecord(bootedAt: boot.addingTimeInterval(86_400), loginAt: boot.addingTimeInterval(86_420),
                                    calmAt: boot.addingTimeInterval(86_558), busiest: [])
        #expect(StartupTimer.comparison(similar, before: record) == "About as quick as the restart before.")
        // Never calm while Orbit watched: said so, and nothing to compare.
        let busy = StartupRecord(bootedAt: boot, loginAt: boot.addingTimeInterval(25), calmAt: nil, busiest: [])
        #expect(StartupTimer.summary(busy) == "macOS took 25 s to start and log you in, and the Mac was still busy 15 min after that.")
        #expect(StartupTimer.comparison(busy, before: record) == nil && StartupTimer.comparison(record, before: busy) == nil)
        let quick = StartupRecord(bootedAt: boot, loginAt: boot.addingTimeInterval(20), calmAt: boot.addingTimeInterval(25), busiest: [])
        #expect(StartupTimer.summary(quick) == "macOS took 20 s to start and log you in, and the Mac was calm straight away.")
    }

    @Test func theNewestTenAreKeptOncePerRestart() {
        var list: [StartupRecord] = []
        for day in 0..<12 {
            let booted = boot.addingTimeInterval(Double(day) * 86_400)
            list = StartupTimer.adding(StartupRecord(bootedAt: booted, loginAt: booted.addingTimeInterval(20), calmAt: nil, busiest: []), to: list)
        }
        #expect(list.count == 10 && list.first?.bootedAt == boot.addingTimeInterval(2 * 86_400))
        // The same restart timed again (Orbit opened twice) takes the place of the first time.
        let again = StartupRecord(bootedAt: boot.addingTimeInterval(11 * 86_400), loginAt: boot.addingTimeInterval(11 * 86_400 + 21),
                                  calmAt: nil, busiest: [])
        list = StartupTimer.adding(again, to: list)
        #expect(list.count == 10 && list.last == again)
    }

    @Test func aRecordReadsBackTheSame() throws {
        let record = StartupRecord(bootedAt: boot.addingTimeInterval(0.4), loginAt: boot.addingTimeInterval(23.7), calmAt: nil,
                                   busiest: [.init(name: "Siri", seconds: 110.5)])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        #expect(try decoder.decode(StartupRecord.self, from: encoder.encode(record)) == record)
    }
}
