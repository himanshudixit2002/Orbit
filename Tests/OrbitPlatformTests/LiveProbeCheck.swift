import Foundation
import OrbitCore
@testable import OrbitPlatform
import Testing

/// Reads this Mac's real status the way Orbit does and prints it with timings, so it can be compared
/// with `launchctl`/`pgrep`. Probes only read, and practice mode runs nothing else.
/// Opt-in: `ORBIT_LIVE_PROBE=1 swift test --filter LiveProbeCheck`.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["ORBIT_LIVE_PROBE"] != nil))
struct LiveProbeCheck {
    func timed<T>(_ work: () async -> T) async -> (T, Duration) {
        let start = ContinuousClock.now
        let value = await work()
        return (value, ContinuousClock.now - start)
    }

    @Test func probesMatchTheMac() async {
        let probes = Probes(SystemContext.make(mode: .practice))
        let (status, cold) = await timed { await probes.all() }
        let (_, warm) = await timed { await probes.all() }
        print("PROBE timings: first \(cold), again \(warm)")
        for id in FeatureID.allCases { print("PROBE \(id.rawValue): \(status.state(id))") }
        print("PROBE tiling: \(status.tiling)")
        for helper in Helper.allCases {
            print("PROBE allowed in the background? \(helper.label): \(!SystemReadings().backgroundBlocked(Paths().launchAgent(helper.label)))")
        }
        print("PROBE glow: \(status.glow.run)  menuBar: \(status.menuBar)")
        print("PROBE keyboard: \(status.keyboard)")
        print("PROBE downloads: run=\(status.downloads.run) disabled=\(status.downloads.disabled) sorted=\(status.downloads.log.entries.count)")
        for (id, app) in status.apps.sorted(by: { $0.key.rawValue < $1.key.rawValue }) { print("PROBE app \(id.rawValue): \(app)") }

        let sampler = StatsSampler()
        _ = sampler.sample()
        let (_, samples) = await timed { for _ in 0..<50 { _ = sampler.sample() } }
        let (_, cpu) = await timed { for _ in 0..<50 { _ = sampler.cpuTicks() } }
        let (_, memory) = await timed { for _ in 0..<50 { _ = sampler.memory() } }
        let (_, disk) = await timed { for _ in 0..<50 { _ = sampler.disk() } }
        let (_, network) = await timed { for _ in 0..<50 { _ = sampler.networkBytes() } }
        print("PROBE stats sample: \(samples / 50) each; cpu \(cpu / 50), memory \(memory / 50), disk \(disk / 50), network \(network / 50)")
    }

    /// The real state files still load with this build. Copies are loaded, so a file that didn't
    /// would only be set aside in the copy.
    @Test func realStateStillLoads() throws {
        let real = Paths().support
        let copy = FileManager.default.temporaryDirectory.appending(path: "orbit-state-copy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: copy, withIntermediateDirectories: true)
        for name in ["settings.json", "journal.json", "baseline.json", "managed-files.json"] {
            try FileManager.default.copyItem(at: real.appending(path: name), to: copy.appending(path: name))
        }
        let store = StateStore(root: copy)
        print("PROBE state: \(store.journal.count) undo entries, baseline \(store.baseline == nil ? "MISSING" : "ok"), "
              + "theme \(store.settings.theme), \(store.registry.lastWritten.count) files known")
        #expect(store.baseline != nil)
        #expect(!store.journal.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: copy.appending(path: "journal (unreadable).json").path(percentEncoded: false)))
    }

    /// Which real backups the tidy-up would clear, ignoring age. Only looks: nothing is moved.
    /// What the Doctor finds on this Mac (it only reads).
    @Test func doctorOnThisMac() {
        let start = ContinuousClock.now
        let facts = DoctorProbe(SystemContext.make(mode: .live)).facts()
        print("PROBE doctor took \(ContinuousClock.now - start)")
        for finding in Doctor.findings(facts) {
            print("PROBE doctor: [\(finding.severity)] \(finding.title) — \(finding.fix?.label ?? "no fix")")
        }
    }

    @Test func backupsNothingNeeds() {
        let actions = Actions(SystemContext.make(mode: .live))
        let unneeded = actions.unneededBackups(olderThan: 0)
        let all = (try? FileManager.default.contentsOfDirectory(atPath: actions.backupsFolder.path(percentEncoded: false)))?.count ?? 0
        print("PROBE backups: \(all) folders, \(unneeded.count) no longer needed: \(unneeded.map(\.lastPathComponent))")
        print("PROBE Orbit's own files: \(actions.storageUsed() / 1024) KB")
    }
}
