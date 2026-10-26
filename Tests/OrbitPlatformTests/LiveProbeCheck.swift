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
    /// What Cleanup finds on this Mac (it only measures).
    @Test func cleanupOnThisMac() async {
        let start = ContinuousClock.now
        let items = await CleanupScanner(SystemContext.make(mode: .live)).scan(includeDownloads: false)
        print("PROBE cleanup took \(ContinuousClock.now - start)")
        for item in items {
            print("PROBE cleanup: \(ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file))  [\(item.safety.label)\(item.suggested ? ", ticked" : "")]  \(item.title)")
        }
    }

    /// The bar's scripts run here against a stand-in `sketchybar` that only prints what it was asked
    /// (they read yabai, launchctl and the disk; nothing on the real bar changes).
    @Test func barScriptsOnThisMac() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "orbit-bar-\(UUID().uuidString.prefix(6))")
        let plugins = dir.appending(path: "plugins")
        let bin = dir.appending(path: "bin")
        try FileManager.default.createDirectory(at: plugins, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try SketchyBarConfig.colors(.tokyoNight).write(to: dir.appending(path: "colors.sh"), atomically: true, encoding: .utf8)
        for (name, text) in SketchyBarConfig.plugins { try text.write(to: plugins.appending(path: name), atomically: true, encoding: .utf8) }
        try "#!/bin/sh\necho \"sketchybar $*\"\n".write(to: bin.appending(path: "sketchybar"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.appending(path: "sketchybar").path(percentEncoded: false))
        var bar = BarSettings()
        for item in BarItem.allCases { bar.setShown(item, true) }
        bar.hideEmptySpaces = true
        let rc = SketchyBarConfig.rc(bar)
        try rc.write(to: dir.appending(path: "sketchybarrc"), atomically: true, encoding: .utf8)
        func zsh(_ arguments: [String], env: [String: String] = [:]) throws -> String {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = arguments
            process.environment = ["PATH": bin.path(percentEncoded: false) + ":/usr/bin:/bin:/usr/sbin:/sbin", "HOME": NSHomeDirectory(),
                                   "CONFIG_DIR": dir.path(percentEncoded: false), "USER": NSUserName()].merging(env) { $1 }
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            try process.run()
            process.waitUntilExit()
            return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self) + (process.terminationStatus == 0 ? "" : "[exit \(process.terminationStatus)]")
        }
        print("PROBE bar: rc syntax \(try zsh(["-n", dir.appending(path: "sketchybarrc").path(percentEncoded: false)]).isEmpty ? "ok" : "BROKEN")")
        for name in SketchyBarConfig.plugins.keys.sorted() {
            let path = plugins.appending(path: name).path(percentEncoded: false)
            let syntax = try zsh(["-n", path])
            print("PROBE bar: \(name) syntax \(syntax.isEmpty ? "ok" : syntax)")
        }
        for name in ["disk.sh", "services.sh", "git.sh", "spaces_shown.sh"] {
            let out = try zsh([plugins.appending(path: name).path(percentEncoded: false)], env: ["NAME": name.replacingOccurrences(of: ".sh", with: ""), "SENDER": "forced"])
            print("PROBE bar: \(name) → \(out.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        let music = #"{"Player State":"Playing","Name":"Song","Artist":"Someone"}"#
        print("PROBE bar: music.sh → \(try zsh([plugins.appending(path: "music.sh").path(percentEncoded: false)], env: ["NAME": "music", "INFO": music]).trimmingCharacters(in: .whitespacesAndNewlines))")
        let clock = rc.split(separator: "\n").first { $0.contains("script='sketchybar --set") }.map { $0.split(separator: "'")[1] } ?? ""
        print("PROBE bar: clock → \(try zsh(["-c", String(clock)], env: ["NAME": "clock"]).trimmingCharacters(in: .whitespacesAndNewlines))")
        try? FileManager.default.trashItem(at: dir, resultingItemURL: nil)
    }

    /// The windows on this Mac as a saved layout, and what putting it straight back would do (it only reads).
    @Test func windowLayoutOnThisMac() async throws {
        let actions = Actions(SystemContext.make(mode: .live))
        let start = ContinuousClock.now
        guard let now = await actions.windowsNow() else {
            print("PROBE windows: tiling isn't running")
            return
        }
        let layout = WindowLayout.capture(name: "Now", windows: now.windows, spaces: now.spaces)
        print("PROBE windows: read in \(ContinuousClock.now - start): \(layout.summary)")
        let plan = LayoutPlanner.plan(layout, windows: now.windows, spaces: now.spaces)
        print("PROBE windows: putting it back needs \(plan.steps.count) steps, notes \(plan.notes)")
    }

    /// This Mac's setup as a profile, and what importing it straight back would change (it only reads).
    @Test func profileOfThisMac() throws {
        let ctx = SystemContext.make(mode: .live)
        let actions = Actions(ctx)
        let profile = actions.currentProfile()
        let data = try profile.encoded()
        let text = String(decoding: data, as: UTF8.self)
        print("PROBE profile: \(data.count / 1024) KB, \(profile.files.count) files, edited by hand: \(profile.edited)")
        print("PROBE profile: link token left out: \(!text.contains(ctx.store.linkToken))")
        let back = try OrbitProfile.decode(data)
        print("PROBE profile: reads back the same: \(back == profile); importing it here changes \(back.changedSettings(from: ctx.store.settings))")
        print("PROBE profile: would replace hand-edited files here: \(actions.filesImportReplaces(back))")
    }

    /// Per-process readings on this Mac: how many processes Orbit can see into, and the biggest (it only reads).
    @Test func processStatsOnThisMac() {
        let start = ContinuousClock.now
        let stats = ProcessStat.all()
        let all = RunningProcess.all()
        print("PROBE processes: \(stats.count) of \(all.count) readable in \(ContinuousClock.now - start); swap \(StatsSampler.swapUsed() / 1_048_576) MB")
        for stat in stats.sorted(by: { $0.memory > $1.memory }).prefix(5) {
            print("PROBE processes:   \(stat.memory / 1_048_576) MB  \(Int(stat.cpuTime)) s  \(stat.name)  \(stat.path.suffix(60))")
        }
        for name in ["Siri AI", "sirittsd", "corespeechd", "coreduetd", "WindowServer"] {
            let match = stats.filter { $0.name == name }
            print("PROBE processes: \(name): \(match.isEmpty ? "not readable or not running" : "\(Int(match.reduce(0) { $0 + $1.cpuTime })) s of CPU")")
        }
    }

    /// What theme sync would change on this Mac (it only reads).
    @Test func themeSyncOnThisMac() throws {
        let ctx = SystemContext.make(mode: .live)
        let actions = Actions(ctx)
        let installed = actions.installedEditorThemes()
        print("PROBE themes: editor has \(installed.sorted().joined(separator: ", "))")
        let current = try actions.editorValues()
        print("PROBE themes: editor now \(current)")
        for id in ThemeID.allCases {
            let changes = EditorTheme.changes(Palette.named(id), installed: installed, current: current)
            print("PROBE themes: \(id) → \(EditorTheme.theme(for: id, installed: installed)), \(changes.keys.sorted()), accent \(MacAccent.matching(id).name)")
        }
        print("PROBE themes: accent now \(String(describing: Preferences.read(WatchedPreferences.globalDomain, MacAccent.key)))")
        print("PROBE themes: baseline looked at \(ctx.store.baseline?.lookedAt?.count ?? -1) files")
    }

    /// The Developer page's facts on this Mac (it only reads).
    @Test func developerOnThisMac() async {
        let probe = DeveloperProbe(SystemContext.make(mode: .live))
        let start = ContinuousClock.now
        let projects = await probe.projects()
        print("PROBE developer: \(projects.count) projects in \(ContinuousClock.now - start)")
        for project in projects {
            let git = project.git.map { "\($0.branch) ↑\($0.ahead) ↓\($0.behind) \($0.changes) changed" } ?? "not in git"
            print("PROBE developer:   \(project.name) [\(project.kind.title)] \(git)")
        }
        for service in await probe.services() { print("PROBE developer: service \(service.name) running=\(service.running) atLogin=\(service.atLogin)") }
        for info in await probe.ports() { print("PROBE developer: :\(info.port.port) \(info.port.command) \(info.owner) \(info.folder ?? "")") }
    }

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
