import AppKit
import Foundation
import OrbitCore

extension Actions {
    /// Switches instant tweaks on or off, as one change with Undo. On, each remembers what it replaces;
    /// off, that comes back (or Apple's default, when nothing was set). The Dock and Finder restart to
    /// show it; apps pick up the rest as they open.
    public func setInstant(_ groups: Set<SpeedTweak.Group>, on: Bool) async -> ActionOutcome {
        let tweaks = SpeedTweak.all.filter { groups.contains($0.group) }
        return await steps { undo in
            var snapshot = settings.speed.before
            var changes: [PreferenceChange] = []
            for tweak in tweaks {
                let id = Baseline.key(tweak.domain, tweak.key)
                if on {
                    let now = ctx.readings.preference(tweak.domain, tweak.key)
                    if !snapshot.knows(id), !tweak.isApplied(now) { snapshot.record(id, now) }
                    changes.append(PreferenceChange(tweak.domain, tweak.key, tweak.value))
                } else {
                    changes.append(PreferenceChange(tweak.domain, tweak.key, snapshot.value(id)))
                    snapshot.forget(id)
                }
            }
            if snapshot != settings.speed.before { undo += changeSettings { $0.speed.before = snapshot } }
            undo += await setPreferences(changes, message: "").undo
            guard on else { return "The animations are back as they were." }
            let reopen = groups.contains(.windows) || groups.contains(.sheets)
            return "Done: the Dock and Finder already show it" + (reopen ? "; apps get it as you open them (reopen any that are open now)." : ".")
        }
    }

    /// Which instant groups are fully on now.
    public func instantGroupsOn() -> Set<SpeedTweak.Group> {
        SpeedTweak.groupsOn { ctx.readings.preference($0, $1) }
    }
}

extension Actions {
    /// Asks an app to quit, as Quit in its menu would: it can save first, and is never forced. Undo
    /// opens it again. In practice mode it's only written down.
    public func quitApp(path: String, name: String) async -> ActionOutcome {
        let target = path.hasSuffix("/") ? String(path.dropLast()) : path
        func running() -> NSRunningApplication? {
            NSWorkspace.shared.runningApplications.first { app in
                guard let url = app.bundleURL?.path(percentEncoded: false) else { return false }
                return (url.hasSuffix("/") ? String(url.dropLast()) : url) == target
            }
        }
        guard let app = running() else { return ActionOutcome(ok: true, message: "\(name) isn't open.") }
        guard ctx.mode == .live else {
            ctx.practiceLog.record("Would ask \(name) to quit", target)
            return ActionOutcome(ok: true, message: "Practice: \(name) wasn't really asked to quit.")
        }
        guard app.terminate() else {
            return ActionOutcome(ok: false, message: "\(name) didn't take the request. Use Force Quit (⌥⌘⎋) if it's stuck.")
        }
        for _ in 0..<20 where !app.isTerminated { try? await Task.sleep(for: .milliseconds(500)) }
        guard app.isTerminated else {
            return ActionOutcome(ok: true, message: "Asked \(name) to quit. It may be asking about unsaved work.")
        }
        return ActionOutcome(ok: true, message: "\(name) has quit.", undo: [.reopenApp(path: target, name: name)])
    }
}

/// What the Speed check and the heavy-app notices need between looks: each process's processor time
/// last time (for "using now"), and when each app was last in front.
public final class AppUsageTracker: Sendable {
    private struct State {
        var lastTimes: [Int32: Double] = [:]
        var lastAt: ContinuousClock.Instant?
        var lastActive: [String: Date] = [:]
        let started = Date()
    }

    private let state = Locked(State())
    private let readings: SystemReadings

    public init(readings: SystemReadings) { self.readings = readings }

    /// An app came to the front (its bundle's path).
    public func noteActive(_ bundlePath: String, at date: Date = Date()) {
        state.withLock { $0.lastActive[Self.trimmed(bundlePath)] = date }
    }

    /// The apps and what each uses now; processor use needs an earlier look, so the first has none.
    public func sample(frontmost: String?, at date: Date = Date()) -> [AppUsage] {
        let stats = readings.processStats()
        let playing = readings.mediaPIDs()
        let now = ContinuousClock.now
        let (before, interval, lastActive, started) = state.withLock { s -> ([Int32: Double]?, Double, [String: Date], Date) in
            let elapsed = s.lastAt.map { now - $0 }.map { Double($0.components.seconds) + Double($0.components.attoseconds) / 1e18 }
            defer {
                s.lastTimes = Dictionary(stats.map { ($0.pid, $0.cpuTime) }, uniquingKeysWith: { first, _ in first })
                s.lastAt = now
            }
            return (elapsed.map { _ in s.lastTimes }, elapsed ?? 0, s.lastActive, s.started)
        }
        let front = frontmost.map(Self.trimmed)
        return AppGrouping.apps(stats, before: before, interval: interval, playing: playing).map { app in
            var app = app
            app.isFrontmost = app.path == front
            let since = app.isFrontmost ? date : lastActive[app.path] ?? started
            app.idleMinutes = max(0, date.timeIntervalSince(since) / 60)
            return app
        }
    }

    static func trimmed(_ path: String) -> String { path.hasSuffix("/") ? String(path.dropLast()) : path }
}

/// Gathers what the Speed check looks at. Read-only.
public struct SpeedProbe: Sendable {
    let ctx: SystemContext
    let library: URL
    let applicationFolders: [URL]

    public init(_ ctx: SystemContext, library: URL = URL(fileURLWithPath: "/Library"), applicationFolders: [URL]? = nil) {
        self.ctx = ctx
        self.library = library
        self.applicationFolders = applicationFolders ?? [URL(fileURLWithPath: "/Applications"),
                                                         URL(fileURLWithPath: "/Applications/Utilities"),
                                                         ctx.paths.home.appending(path: "Applications")]
    }

    /// Siri's and Apple Intelligence's own processes (those Orbit can see into: they run as you).
    static let siriProcesses: Set<String> = ["Siri AI", "Siri", "sirittsd", "corespeechd", "siriactionsd", "siriknowledged",
                                             "siriinferenced", "assistantd"]

    public func facts(apps: [AppUsage]) -> SpeedFacts {
        var facts = SpeedFacts()
        let sample = StatsSampler().sample()
        facts.memoryPressure = sample.memoryPressure
        facts.diskFree = sample.diskFree
        facts.diskTotal = sample.diskTotal
        facts.swapUsed = StatsSampler.swapUsed()
        facts.apps = apps
        facts.siriOn = PrefValue.same(ctx.readings.preference("com.apple.assistant.support", "Assistant Enabled"), .bool(true))
        facts.siriSeconds = ctx.readings.processStats().filter { Self.siriProcesses.contains($0.name) }.reduce(0) { $0 + $1.cpuTime }
        facts.leftovers = Leftovers.find(systemLaunchItems(), installedApps: installedApps())
        facts.instantOn = SpeedTweak.groupsOn { ctx.readings.preference($0, $1) }
        return facts
    }

    /// Background jobs installed for the whole Mac (they start at boot or login, for every user).
    func systemLaunchItems() -> [LaunchItem] {
        ["LaunchDaemons", "LaunchAgents"].flatMap { folder -> [LaunchItem] in
            let dir = library.appending(path: folder)
            let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path(percentEncoded: false))) ?? []
            return names.filter { $0.hasSuffix(".plist") }.compactMap { name in
                let url = dir.appending(path: name)
                guard let data = try? Data(contentsOf: url),
                      let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
                let program = plist["Program"] as? String ?? (plist["ProgramArguments"] as? [String])?.first
                return LaunchItem(label: plist["Label"] as? String ?? url.deletingPathExtension().lastPathComponent,
                                  plist: url.path(percentEncoded: false), program: program,
                                  programExists: program.map { FileManager.default.fileExists(atPath: $0) } ?? false)
            }
        }
    }

    /// The names of the apps installed ("Docker.app"), in the Applications folders and one level down.
    func installedApps() -> Set<String> {
        var names = Set<String>()
        for folder in applicationFolders {
            for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false))) ?? [] {
                if name.hasSuffix(".app") {
                    names.insert(name)
                } else if !name.hasPrefix(".") {
                    let inner = (try? FileManager.default.contentsOfDirectory(atPath: folder.appending(path: name).path(percentEncoded: false))) ?? []
                    names.formUnion(inner.filter { $0.hasSuffix(".app") })
                }
            }
        }
        return names
    }

    /// Your own background jobs that start at login (Orbit's helpers aside: their switches are elsewhere).
    public func loginAgents() -> [UserLoginAgent] {
        let mine = Set(Helper.allCases.map(\.label))
        let dir = ctx.paths.launchAgents
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path(percentEncoded: false))) ?? []
        return names.filter { $0.hasSuffix(".plist") }.sorted().compactMap { name in
            let url = dir.appending(path: name)
            guard let data = ctx.files.read(url),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let label = plist["Label"] as? String, !mine.contains(label) else { return nil }
            let program = plist["Program"] as? String ?? (plist["ProgramArguments"] as? [String])?.first
            guard program != nil else { return nil }
            let name = program.flatMap(AppGrouping.bundle(of:)).map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent }
                ?? program.map { URL(fileURLWithPath: $0).lastPathComponent } ?? label
            return UserLoginAgent(label: label, path: url.path(percentEncoded: false), name: name,
                                  startsAtLogin: plist["RunAtLoad"] as? Bool ?? false)
        }
    }
}

/// One of your own background jobs, and whether it starts at login.
public struct UserLoginAgent: Sendable, Equatable, Identifiable {
    public var label: String
    public var path: String
    public var name: String
    public var startsAtLogin: Bool

    public var id: String { label }
}

extension Actions {
    /// Makes one of your background jobs start at login or not (from the next login on). Its file is
    /// backed up first, and Undo puts it back.
    public func setStartsAtLogin(_ agent: UserLoginAgent, _ on: Bool) async -> ActionOutcome {
        await steps { undo in
            let url = URL(fileURLWithPath: agent.path)
            guard let data = ctx.files.read(url),
                  var plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
                throw StepFailed(message: "\(agent.name)'s file couldn't be read.")
            }
            plist["RunAtLoad"] = on
            let xml = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            undo += try writePlain(url, String(decoding: xml, as: UTF8.self), executable: false, backups: backupFolder("login agent"))
            return on ? "\(agent.name) starts at login again." : "\(agent.name) won't start at login any more (from the next login)."
        }
    }
}
