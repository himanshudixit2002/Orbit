import Foundation
import OrbitCore

extension Actions {
    /// Records how things were before Orbit changed anything. Runs once, at first launch.
    public func captureBaselineIfNeeded(wallpaper: String?) async {
        guard ctx.store.baseline == nil, !ctx.store.baselineUnreadable else { return }
        var baseline = Baseline(wallpaper: wallpaper)
        for (domain, key) in WatchedPreferences.keys {
            if let value = ctx.readings.preference(domain, key) { baseline.preferences[Baseline.key(domain, key)] = value }
        }
        let folder = ctx.store.root.appending(path: "Backups/Before Orbit")
        let files = ManagedFile.allCases.map { $0.url(paths) } + [paths.tmuxConf, paths.skhdrc, paths.btopConf]
        for url in files {
            if let copy = try? LiveFileStore().backup(url, into: folder) {
                baseline.files[url.path(percentEncoded: false)] = copy.path(percentEncoded: false)
            }
        }
        baseline.lookedAt = files.map { $0.path(percentEncoded: false) }.sorted()
        baseline.preferencesLookedAt = WatchedPreferences.keys.map { Baseline.key($0.domain, $0.key) }.sorted()
        for helper in Helper.allCases {
            baseline.helpersOn[helper] = await isRunning(helper)
        }
        let delta = await ctx.run(Commands.gitConfigGet("delta.syntax-theme"))
        baseline.gitDeltaTheme = delta.status == 0 ? delta.stdout.trimmingCharacters(in: .whitespacesAndNewlines) : nil
        ctx.store.setBaseline(baseline)
    }

    /// The files the baseline knows the state of.
    func lookedAt(_ baseline: Baseline) -> Set<String> {
        let first = ManagedFile.first.map { $0.url(paths) } + [paths.tmuxConf, paths.skhdrc, paths.btopConf]
        return Set(baseline.lookedAt ?? first.map { $0.path(percentEncoded: false) })
    }

    /// The preferences ("domain|key") the baseline knows the state of.
    func preferencesLookedAt(_ baseline: Baseline) -> Set<String> {
        Set(baseline.preferencesLookedAt ?? WatchedPreferences.first.map { Baseline.key($0.domain, $0.key) })
    }

    /// Files and preferences Orbit began to manage after the baseline was made (the Downloads sorter,
    /// Warp's theme, the Speed page's animation settings): as they are now is how they were before
    /// Orbit, unless Orbit has changed them since. Runs at launch, before anything can change them, so
    /// "Back to before Orbit" never mistakes them for Orbit's own (or clears what the user had set).
    public func topUpBaseline() {
        guard var baseline = ctx.store.baseline else { return }
        var looked = lookedAt(baseline)
        let before = looked
        let folder = ctx.store.root.appending(path: "Backups/Before Orbit")
        for file in ManagedFile.allCases {
            let url = file.url(paths)
            let path = url.path(percentEncoded: false)
            guard !looked.contains(path) else { continue }
            looked.insert(path)
            // Written by Orbit already: its history says what was there first.
            guard Self.before(path, baseline: baseline, journal: ctx.store.journal) == .unknown else { continue }
            if let copy = try? LiveFileStore().backup(url, into: folder) { baseline.files[path] = copy.path(percentEncoded: false) }
        }
        var lookedPrefs = preferencesLookedAt(baseline)
        let beforePrefs = lookedPrefs
        for (domain, key) in WatchedPreferences.keys {
            let id = Baseline.key(domain, key)
            guard lookedPrefs.insert(id).inserted else { continue }
            switch Self.beforePreference(domain, key, journal: ctx.store.journal) {
            case .value(let original): baseline.preferences[id] = original
            case .unknown: baseline.preferences[id] = ctx.readings.preference(domain, key)
            }
        }
        guard looked != before || baseline.lookedAt == nil || lookedPrefs != beforePrefs || baseline.preferencesLookedAt == nil else { return }
        baseline.lookedAt = looked.sorted()
        baseline.preferencesLookedAt = lookedPrefs.sorted()
        ctx.store.setBaseline(baseline)
    }

    enum PreferenceBefore: Equatable {
        /// What it was before Orbit first changed it (nil: not set).
        case value(PrefValue?)
        case unknown
    }

    /// How a preference was before Orbit, from the first change in the history that touched it.
    static func beforePreference(_ domain: String, _ key: String, journal: [JournalEntry]) -> PreferenceBefore {
        for entry in journal {
            for case .restorePreference(let d, let k, let value) in entry.actions where d == domain && k == key {
                return .value(value)
            }
        }
        return .unknown
    }

    /// Puts settings, config files and helpers back the way they were before Orbit.
    public func restoreBaseline() async -> ActionOutcome {
        guard let baseline = ctx.store.baseline else {
            return ActionOutcome(ok: false, message: "Orbit has no record of how things were before it.")
        }
        let undo = UndoRecorder.forThisTask(ctx.store)
        var domains = Set<String>()
        let lookedPrefs = preferencesLookedAt(baseline)
        for (domain, key) in WatchedPreferences.keys {
            let id = Baseline.key(domain, key)
            // Nothing says how it was before Orbit (neither the record nor the history): left alone.
            let before: PrefValue?
            if lookedPrefs.contains(id) {
                before = baseline.preferences[id]
            } else if case .value(let original) = Self.beforePreference(domain, key, journal: ctx.store.journal) {
                before = original
            } else {
                continue
            }
            let now = ctx.readings.preference(domain, key)
            guard before != now else { continue }
            if key == "_HIHideMenuBar" {
                undo += await setMacMenuBarHidden(before?.boolValue ?? false)
                continue
            }
            ctx.prefs.set(domain, key, before)
            domains.insert(domain)
            undo.append(.restorePreference(domain: domain, key: key, value: now))
        }
        let backups = backupFolder("before restoring")
        var failures: [String] = []
        var restored = Set<ManagedFile>()
        let looked = lookedAt(baseline)
        for file in ManagedFile.allCases {
            let url = file.url(paths)
            let path = url.path(percentEncoded: false)
            // Not in the baseline and never written by Orbit: nothing says how it was, so it stays.
            let before: Before = looked.contains(path) ? baseline.files[path].map { .copy($0) } ?? .absent
                                                       : Self.before(path, baseline: baseline, journal: ctx.store.journal)
            do {
                switch before {
                case .unknown:
                    continue
                case .copy(let copy):
                    // A saved copy that's gone says nothing about the file, so it's left as it is.
                    guard let data = ctx.files.read(URL(fileURLWithPath: copy)) else {
                        failures.append("the saved copy of \(paths.tilde(url)) is missing")
                        continue
                    }
                    guard ctx.files.read(url) != data else { continue }
                    let backup = try ctx.files.backup(url, into: backups)
                    try ctx.files.write(data, to: url, executable: file.isExecutable)
                    ctx.store.noteWritten(file, data: data)
                    undo.append(.restoreFile(path: path, backup: backup?.path(percentEncoded: false)))
                    restored.insert(file)
                case .absent:
                    guard ctx.files.exists(url), let backup = try ctx.files.backup(url, into: backups) else { continue }
                    _ = try ctx.files.trash(url)
                    undo.append(.restoreFile(path: path, backup: backup.path(percentEncoded: false)))
                    restored.insert(file)
                }
            } catch {
                failures.append("\(paths.tilde(url)): \(error.localizedDescription)")
            }
        }
        // Orbit's block in ~/.tmux.conf comes out; the rest of the file is the user's and stays as it is.
        if let data = ctx.files.read(paths.tmuxConf) {
            let conf = String(decoding: data, as: UTF8.self)
            let without = TerminalThemes.tmuxConfWithoutInclude(conf)
            if without != conf {
                do {
                    undo += try writePlain(paths.tmuxConf, without, executable: false, backups: backups)
                } catch {
                    failures.append("\(paths.tilde(paths.tmuxConf)): \(error.localizedDescription)")
                }
            }
        }
        // Files Orbit writes besides its own: btop's settings and the menu bar's plugins.
        let plugins = paths.sketchybarDir.appending(path: "plugins")
        for url in [paths.btopConf] + SketchyBarConfig.plugins.keys.sorted().map({ plugins.appending(path: $0) }) {
            let path = url.path(percentEncoded: false)
            do {
                switch Self.before(path, baseline: baseline, journal: ctx.store.journal) {
                case .unknown:
                    continue
                case .absent:
                    guard ctx.files.exists(url), let backup = try ctx.files.backup(url, into: backups) else { continue }
                    _ = try ctx.files.trash(url)
                    undo.append(.restoreFile(path: path, backup: backup.path(percentEncoded: false)))
                case .copy(let copy):
                    guard let data = ctx.files.read(URL(fileURLWithPath: copy)) else {
                        failures.append("the saved copy of \(paths.tilde(url)) is missing")
                        continue
                    }
                    guard ctx.files.read(url) != data else { continue }
                    let backup = try ctx.files.backup(url, into: backups)
                    try ctx.files.write(data, to: url, executable: url.pathExtension == "sh")
                    undo.append(.restoreFile(path: path, backup: backup?.path(percentEncoded: false)))
                }
            } catch {
                failures.append("\(paths.tilde(url)): \(error.localizedDescription)")
            }
        }
        // git's diff colours, which themes set, go back too.
        let delta = await ctx.run(Commands.gitConfigGet("delta.syntax-theme"))
        let deltaNow = delta.status == 0 ? delta.stdout.trimmingCharacters(in: .whitespacesAndNewlines) : nil
        if deltaNow != baseline.gitDeltaTheme {
            if let theme = baseline.gitDeltaTheme {
                await ctx.run(Commands.gitConfigSet("delta.syntax-theme", theme))
            } else {
                await ctx.run(Commands.gitConfigUnset("delta.syntax-theme"))
            }
            undo.append(.gitConfig(key: "delta.syntax-theme", value: deltaNow))
        }
        // The editor's theme and the accent colour go back to what they were before Orbit set them.
        if settings.themeSync.editor {
            do { undo += try editorSyncOff() } catch { failures.append("Antigravity IDE: \(error.localizedDescription)") }
        }
        if settings.themeSync.accent { undo += accentSyncOff() }
        // Orbit's own settings go back to their defaults, which describe the Mac before Orbit.
        undo += changeSettings { s in
            var fresh = OrbitSettings()
            fresh.modes = s.modes
            fresh.setupCompleted = s.setupCompleted
            s = fresh
        }
        for helper in Helper.allCases {
            do {
                undo += try await setHelper(helper, on: baseline.helpersOn[helper] ?? false)
            } catch {
                if let failed = error as? StepFailed { undo += failed.undo }
                failures.append(error.localizedDescription)
            }
        }
        await refreshAfterPreferences(domains)
        await reload(restored)
        guard failures.isEmpty else {
            return ActionOutcome(ok: false, message: "Mostly back the way it was before Orbit, but " + failures.joined(separator: "; ") + ".",
                                 undo: undo.actions)
        }
        return ActionOutcome(ok: true, message: "Everything is back the way it was before Orbit.", undo: undo.actions)
    }

    /// How a file looked before Orbit, for files the snapshot may not hold (it gained btop.conf later):
    /// its copy there, or else the first backup Orbit made of it, where none means Orbit created it.
    enum Before: Equatable {
        case copy(String), absent, unknown
    }

    static func before(_ path: String, baseline: Baseline, journal: [JournalEntry]) -> Before {
        if let copy = baseline.files[path] { return .copy(copy) }
        for entry in journal {
            for case .restoreFile(let changed, let backup) in entry.actions where changed == path {
                return backup.map { .copy($0) } ?? .absent
            }
        }
        return .unknown
    }

    /// Clears Orbit's and anyone's Dock and Finder tweaks, so macOS uses its own defaults.
    public func resetDockAndFinder() async -> ActionOutcome {
        let changes = WatchedPreferences.keys
            .filter { $0.domain == WatchedPreferences.dockDomain || $0.domain == WatchedPreferences.finderDomain }
            .map { PreferenceChange($0.domain, $0.key, nil) }
        return await setPreferences(changes, message: "The Dock and Finder are back to Apple's defaults.")
    }

    /// Moves the projects that were tidied off the Desktop back onto it.
    public func putProjectsBackOnDesktop() async -> ActionOutcome {
        guard let data = ctx.files.read(paths.desktopMoveLog) else {
            return ActionOutcome(ok: false, message: "There's no record of moved projects.")
        }
        let undo = UndoRecorder.forThisTask(ctx.store)
        var moved = 0
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let parts = line.split(separator: "\t").map(String.init)
            guard parts.count == 2, parts[0].contains("/Desktop/") else { continue }
            let (original, current) = (URL(fileURLWithPath: parts[0]), URL(fileURLWithPath: parts[1]))
            guard ctx.files.exists(current), !ctx.files.exists(original) else { continue }
            do {
                try ctx.files.move(current, to: original)
                undo.append(.moveBack(current: original.path(percentEncoded: false), original: current.path(percentEncoded: false)))
                moved += 1
            } catch {
                continue
            }
        }
        return ActionOutcome(ok: true, message: moved == 0 ? "Nothing needed moving." : "Moved \(moved) items back to the Desktop.", undo: undo.actions)
    }
}
