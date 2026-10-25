import AppKit
import Darwin
import Foundation
import OrbitCore

/// Gathers what the Doctor looks at. Read-only: it reads files and asks the process table, and changes
/// nothing.
public struct DoctorProbe: Sendable {
    let ctx: SystemContext
    let applicationFolders: [URL]

    public init(_ ctx: SystemContext, applicationFolders: [URL]? = nil) {
        self.ctx = ctx
        self.applicationFolders = applicationFolders ?? [URL(fileURLWithPath: "/Applications"), ctx.paths.at("Applications")]
    }

    public func facts() -> DoctorFacts {
        let settings = ctx.store.settings
        var facts = DoctorFacts()
        facts.capsLockOn = settings.keyboard.capsLockEnabled
        facts.missingHyperApps = settings.keyboard.hyperApps.filter { !$0.appPath.isEmpty && !ctx.readings.installed($0.appPath) }
        facts.apps = applicationCopies()
        let agents = launchAgents()
        facts.launchAgents = agents.map(\.agent)
        facts.servicesAtLogin = services(agents)
        (facts.tmuxPluginsMissing, facts.tmuxManagerInstalled) = tmuxPlugins()
        facts.projectsNotInGit = Self.projects(in: ctx.paths.developer).filter { !$0.inGit }.map(\.name)
        facts.cheatSheetStale = cheatSheetStale()
        return facts
    }

    /// Every app in the Applications folders, with the facts needed to spot a spare copy. Sizes are only
    /// worked out for apps that have a twin (it means reading every file in them).
    func applicationCopies() -> [DoctorFacts.AppCopy] {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleURL?.standardizedFileURL.path(percentEncoded: false) })
        var copies: [DoctorFacts.AppCopy] = []
        for folder in applicationFolders {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false))) ?? []
            for name in names where name.hasSuffix(".app") {
                let url = folder.appending(path: name)
                guard let info = NSDictionary(contentsOf: url.appending(path: "Contents/Info.plist")),
                      let id = info["CFBundleIdentifier"] as? String else { continue }
                let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                copies.append(DoctorFacts.AppCopy(name: String(name.dropLast(4)), path: url.path(percentEncoded: false), bundleID: id,
                                                  version: info["CFBundleShortVersionString"] as? String ?? "?", modified: modified,
                                                  running: running.contains(url.standardizedFileURL.path(percentEncoded: false))))
            }
        }
        let twins = Set(Dictionary(grouping: copies, by: \.bundleID).filter { $0.value.count > 1 }.keys)
        return copies.map { copy in
            guard twins.contains(copy.bundleID) else { return copy }
            var sized = copy
            sized.size = CleanupScanner.allocatedSize(URL(fileURLWithPath: copy.path))
            return sized
        }
    }

    struct AgentFile {
        var agent: DoctorFacts.LaunchAgent
        var runAtLoad: Bool
    }

    func launchAgents() -> [AgentFile] {
        let folder = ctx.paths.at("Library/LaunchAgents")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false))) ?? []
        return names.filter { $0.hasSuffix(".plist") }.sorted().compactMap { name in
            let url = folder.appending(path: name)
            guard let data = ctx.files.read(url),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
            let program = plist["Program"] as? String ?? (plist["ProgramArguments"] as? [String])?.first
            let agent = DoctorFacts.LaunchAgent(path: url.path(percentEncoded: false), label: plist["Label"] as? String, program: program,
                                                programExists: program.map { FileManager.default.isExecutableFile(atPath: $0) } ?? false)
            return AgentFile(agent: agent, runAtLoad: plist["RunAtLoad"] as? Bool ?? false)
        }
    }

    /// Homebrew services set to start at login, and the memory each uses now.
    func services(_ agents: [AgentFile]) -> [DoctorFacts.Service] {
        let processes = ctx.readings.processes()
        return agents.compactMap { file in
            guard file.runAtLoad, let label = file.agent.label, let formula = Self.formula(label) else { return nil }
            let executable = file.agent.program.map { URL(fileURLWithPath: $0).lastPathComponent }
            let pid = processes.first { $0.name == executable }?.pid
            return DoctorFacts.Service(formula: formula, memory: pid.flatMap(Self.memory))
        }
    }

    /// "homebrew.mxcl.mongodb-community" or "sh.brew.mongodb-community" → "mongodb-community".
    static func formula(_ label: String) -> String? {
        for prefix in ["homebrew.mxcl.", "sh.brew."] where label.hasPrefix(prefix) { return String(label.dropFirst(prefix.count)) }
        return nil
    }

    static func memory(_ pid: Int32) -> Int64? {
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size) == size else { return nil }
        return Int64(info.pti_resident_size)
    }

    /// The plugins tmux.conf asks for that aren't installed, and whether the plugin manager is.
    func tmuxPlugins() -> (missing: [String], managerInstalled: Bool) {
        guard let text = ctx.files.read(ctx.paths.tmuxConf).map({ String(decoding: $0, as: UTF8.self) }) else { return ([], false) }
        let folder = ctx.paths.at(".tmux/plugins")
        let missing = TmuxPlugins.declared(in: text).filter { $0 != "tpm" && !ctx.files.exists(folder.appending(path: $0)) }
        return (missing, ctx.files.exists(folder.appending(path: "tpm/bin/install_plugins")))
    }

    /// Projects one or two folders down in ~/Developer: a folder with a project file in it.
    public static func projects(in developer: URL) -> [(name: String, url: URL, inGit: Bool)] {
        let markers = ["Package.swift", "package.json", "Cargo.toml", "pyproject.toml", "go.mod", "pubspec.yaml", "build.gradle",
                       "build.gradle.kts", "Gemfile", "requirements.txt", "setup.py", "pom.xml", "composer.json"]
        let fm = FileManager.default
        func children(_ url: URL) -> [URL] {
            ((try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? [])
                .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true && !["node_modules", "build"].contains($0.lastPathComponent) }
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        }
        func isProject(_ url: URL) -> Bool {
            markers.contains { fm.fileExists(atPath: url.appending(path: $0).path(percentEncoded: false)) }
                || ((try? fm.contentsOfDirectory(atPath: url.path(percentEncoded: false))) ?? []).contains { $0.hasSuffix(".xcodeproj") }
        }
        var found: [(String, URL, Bool)] = []
        for first in children(developer) {
            let candidates = isProject(first) ? [(first.lastPathComponent, first)]
                : children(first).filter(isProject).map { ("\(first.lastPathComponent)/\($0.lastPathComponent)", $0) }
            for (name, project) in candidates {
                found.append((name, project, fm.fileExists(atPath: project.appending(path: ".git").path(percentEncoded: false))))
            }
        }
        return found
    }
}

extension Actions {
    /// Carries out a fix the Doctor suggested (`.open` is navigation, done by the app).
    public func fix(_ fix: DoctorFix, policy: WritePolicy = .askIfEdited) async throws -> ActionOutcome {
        switch fix {
        case .removeHyperKey(let key):
            var keyboard = settings.keyboard
            keyboard.hyperApps.removeAll { $0.key == key }
            return try await applyKeyboard(keyboard)
        case .trash(let paths):
            return await steps { undo in
                for path in paths {
                    let url = URL(fileURLWithPath: path)
                    if path.hasSuffix(".app"), NSWorkspace.shared.runningApplications.contains(where: { $0.bundleURL?.path(percentEncoded: false) == url.path(percentEncoded: false) }) {
                        throw StepFailed(message: "\(url.deletingPathExtension().lastPathComponent) is open. Quit it first.")
                    }
                    // A login item is stopped before its file goes.
                    if path.contains("/LaunchAgents/"), let data = ctx.files.read(url),
                       let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                       let label = plist["Label"] as? String {
                        await ctx.run(Commands.launchctlBootout(label, uid: uid))
                    }
                    guard ctx.files.exists(url) else { continue }
                    if let trashed = try ctx.files.trash(url) {
                        undo.append(.moveBack(current: trashed.path(percentEncoded: false), original: path))
                    }
                }
                return paths.count == 1 ? "Moved \(URL(fileURLWithPath: paths[0]).lastPathComponent) to the Trash."
                                        : "Moved \(paths.count) items to the Trash."
            }
        case .stopService(let formula):
            let name = Doctor.serviceName(formula)
            return await steps { undo in
                let result = await ctx.run(Commands.brewService(.stop, formula, name: name))
                guard result.ok else { throw StepFailed(message: "Couldn't stop \(name): \(result.failureMessage)") }
                undo.append(.brewService(formula: formula, wasRunning: true))
                return "\(name) is stopped and won't start at login. Start it from the Developer page when you need it."
            }
        case .installTmuxPlugins:
            let folder = paths.at(".tmux/plugins")
            let wanted = ctx.files.read(paths.tmuxConf).map { TmuxPlugins.declared(in: String(decoding: $0, as: UTF8.self)) } ?? []
            let before = Set(wanted.filter { ctx.files.exists(folder.appending(path: $0)) })
            return await steps { undo in
                let result = await ctx.run(Command(folder.appending(path: "tpm/bin/install_plugins").path(percentEncoded: false), [],
                                                   effect: .userFiles, summary: "Install tmux's plugins", timeout: 300))
                // Undo takes out what this added.
                for name in wanted where !before.contains(name) && ctx.files.exists(folder.appending(path: name)) {
                    undo.append(.restoreFile(path: folder.appending(path: name).path(percentEncoded: false), backup: nil))
                }
                guard result.ok else { throw StepFailed(message: "tmux's plugin manager stopped: \(result.failureMessage)") }
                return "tmux's plugins are installed. They load the next time tmux starts."
            }
        case .refreshCheatSheet:
            return try await refreshCheatSheet(policy: policy)
        case .open:
            return ActionOutcome(ok: true, message: "")
        }
    }
}

extension Actions {
    /// Rewrites the cheat sheet's Caps Lock paragraph from the current shortcuts (the rest stays).
    public func refreshCheatSheet(policy: WritePolicy = .askIfEdited) async throws -> ActionOutcome {
        let url = paths.cheatSheet
        let existing = ctx.files.read(url).map { String(decoding: $0, as: UTF8.self) }
        let text = CheatSheet.update(existing, block: cheatSheetBlock())
        guard text != existing else { return ActionOutcome(ok: true, message: "The cheat sheet is already up to date.") }
        return await steps { undo in
            undo += try writePlain(url, text, executable: false, backups: backupFolder("cheat sheet"))
            return "The cheat sheet shows your shortcuts now (⌥ / opens it)."
        }
    }

    func cheatSheetBlock() -> [String] {
        CheatSheet.block(capsLock: settings.keyboard.capsLockEnabled, bindings: settings.keyboard.hyperApps,
                         palette: settings.hotKey ?? .standard, extras: appHotkeyExtras())
    }

    /// The AppHotkey helper's shortcut (⌘⇧0 opens one app), if it's set up, with the app it opens now.
    func appHotkeyExtras() -> [CheatSheet.Extra] {
        let agent = paths.at("Library/LaunchAgents/com.himanshudixit.apphotkey.plist")
        guard let data = ctx.files.read(agent),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let arguments = plist["ProgramArguments"] as? [String], arguments.count > 1 else { return [] }
        var app = URL(fileURLWithPath: arguments[1])
        if !FileManager.default.fileExists(atPath: app.path(percentEncoded: false)), arguments.count > 2,
           let fallback = NSWorkspace.shared.urlForApplication(withBundleIdentifier: arguments[2]) {
            app = fallback
        }
        return [CheatSheet.Extra(keys: "⌘⇧ 0", does: "opens \(app.deletingPathExtension().lastPathComponent)")]
    }
}

extension DoctorProbe {
    /// Whether the cheat sheet's Caps Lock paragraph is behind the current shortcuts.
    func cheatSheetStale() -> Bool {
        guard let data = ctx.files.read(ctx.paths.cheatSheet) else { return false }
        let existing = String(decoding: data, as: UTF8.self)
        return CheatSheet.update(existing, block: Actions(ctx).cheatSheetBlock()) != existing
    }
}
