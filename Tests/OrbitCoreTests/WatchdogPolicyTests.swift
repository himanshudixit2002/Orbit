import Foundation
@testable import OrbitCore
import Testing

@Suite struct WatchdogPolicyTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func look(_ secondsAgo: TimeInterval, pid: Int?, job: LaunchdJob? = nil) -> WatchdogPolicy.Look {
        WatchdogPolicy.Look(at: now.addingTimeInterval(-secondsAgo), pid: pid, job: job)
    }
    var crashed: LaunchdJob {
        var job = LaunchdJob()
        job.lastSignal = "Segmentation fault: 11"
        return job
    }

    @Test func aHelperRestartingOverAndOverIsCalledOut() {
        let looks = [look(100, pid: 11), look(70, pid: 12), look(40, pid: 13), look(5, pid: 14)]
        guard case .crashLoop(let detail) = WatchdogPolicy.verdict(looks, keepAlive: KeepAlive(always: true), restarts: [], now: now) else {
            Issue.record("expected a crash loop")
            return
        }
        #expect(detail.hasPrefix("It keeps stopping (3 restarts in two minutes)"))
    }

    @Test func orbitRestartsWhatLaunchdWontWithGrowingWaitsThenStops() {
        let looks = [look(20, pid: 11), look(1, pid: nil, job: crashed)]
        let none = KeepAlive()
        #expect(WatchdogPolicy.verdict(looks, keepAlive: none, restarts: [], now: now) == .restart(after: 10))
        let once = [now.addingTimeInterval(-60)]
        #expect(WatchdogPolicy.verdict(looks, keepAlive: none, restarts: once, now: now) == .restart(after: 30))
        let four = (1...4).map { now.addingTimeInterval(-Double($0) * 120) }
        guard case .gaveUp(let detail) = WatchdogPolicy.verdict(looks, keepAlive: none, restarts: four, now: now) else {
            Issue.record("expected Orbit to give up")
            return
        }
        #expect(detail.contains("Segmentation fault"))
    }

    @Test func launchdsOwnRestartsAndCleanExitsAreLeftAlone() {
        let looks = [look(1, pid: nil, job: crashed)]
        #expect(WatchdogPolicy.verdict(looks, keepAlive: KeepAlive(afterCrash: true), restarts: [], now: now) == .fine)
        var clean = LaunchdJob()
        clean.lastExit = 0
        #expect(WatchdogPolicy.verdict([look(1, pid: nil, job: clean)], keepAlive: KeepAlive(), restarts: [], now: now) == .fine)
    }

    @Test func launchdJobDetailsComeFromTheJobsOwnLines() {
        let text = """
        gui/501/sh.brew.borders = {
        \tstate = not running
        \tstderr path = /opt/homebrew/var/log/borders/borders.err.log
        \truns = 7
        \tlast exit code = 1
        \tlast terminating signal = Abort trap: 6
        \tendpoints = {
        \t\tstate = active
        \t}
        }
        """
        let job = LaunchdJob.parse(text)
        #expect(!job.running && job.runs == 7 && job.lastExit == 1 && job.lastSignal == "Abort trap: 6")
        #expect(job.stderrPath == "/opt/homebrew/var/log/borders/borders.err.log")
    }

    @Test func keepAliveIsReadFromThePlist() throws {
        func plist(_ keepAlive: Any) throws -> Data {
            try PropertyListSerialization.data(fromPropertyList: ["Label": "x", "KeepAlive": keepAlive], format: .xml, options: 0)
        }
        #expect(KeepAlive.read(try plist(true)).always)
        let rules = KeepAlive.read(try plist(["SuccessfulExit": false, "Crashed": true]))
        #expect(rules.afterFailure && rules.afterCrash && !rules.always)
        #expect(KeepAlive.read(nil) == KeepAlive())
    }
}
