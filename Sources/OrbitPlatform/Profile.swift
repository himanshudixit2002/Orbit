import Foundation
import OrbitCore

extension Actions {
    /// The setup as it is now: settings, and each config file Orbit manages that's there.
    public func currentProfile() -> OrbitProfile {
        var files: [ManagedFile: String] = [:]
        var edited = Set<ManagedFile>()
        for file in ManagedFile.allCases {
            guard let data = ctx.files.read(file.url(paths)) else { continue }
            files[file] = String(decoding: data, as: UTF8.self)
            if ctx.store.registry.verdict(for: file, current: data) == .editedByHand { edited.insert(file) }
        }
        return OrbitProfile.make(settings: settings, files: files, edited: edited, token: ctx.store.linkToken)
    }

    static let profileReadme = """
    This is an Orbit profile: Orbit's settings and the config files it manages, as they were when it was saved.
    To use it, open Orbit › Health › Your setup › Import, and pick this file. Orbit shows what would change first.
    Orbit's private link token isn't in it.

    """

    /// Saves the profile as a .zip holding "Orbit Profile.json" and a note on what it is.
    public func exportProfile(to destination: URL) async -> ActionOutcome {
        let name = destination.deletingPathExtension().lastPathComponent
        let staging = FileManager.default.temporaryDirectory.appending(path: "Orbit-export-\(UUID().uuidString.prefix(8))").appending(path: name)
        do {
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            try currentProfile().encoded().write(to: staging.appending(path: "Orbit Profile.json"))
            try Self.profileReadme.write(to: staging.appending(path: "README.txt"), atomically: true, encoding: .utf8)
        } catch {
            return ActionOutcome(ok: false, message: "Orbit couldn't put the profile together: \(error.localizedDescription)")
        }
        let result = await ctx.run(Commands.zip(staging, to: destination))
        guard result.ok else { return ActionOutcome(ok: false, message: "The profile couldn't be saved: \(result.failureMessage)") }
        if result.simulated { return ActionOutcome(ok: true, message: "Practice: the profile wasn't really saved.") }
        return ActionOutcome(ok: true, message: "Saved your setup to \(paths.tilde(destination)).")
    }

    /// Writes the profile into a folder as plain files (for a dotfiles repository): "Orbit Profile.json"
    /// and each config file under "files". Orbit's own files there are replaced; nothing else is touched.
    public func exportProfile(intoFolder folder: URL) async -> ActionOutcome {
        let profile = currentProfile()
        return await steps { undo in
            let backups = backupFolder("profile folder")
            undo += try writePlain(folder.appending(path: "Orbit Profile.json"), String(decoding: try profile.encoded(), as: UTF8.self),
                                   executable: false, backups: backups)
            for (name, text) in profile.files.sorted(by: { $0.key < $1.key }) {
                undo += try writePlain(folder.appending(path: "files").appending(path: name), text, executable: false, backups: backups)
            }
            return "Saved your setup into \(paths.tilde(folder))."
        }
    }

    /// Whether a folder is inside a git repository (to offer a commit there).
    public func isInGit(_ folder: URL) async -> Bool {
        await ctx.run(Commands.gitInsideWorkTree(folder.path(percentEncoded: false))).ok
    }

    /// Commits the profile files in a dotfiles repository, on this Mac only: nothing is pushed.
    public func commitProfile(in folder: URL) async -> ActionOutcome {
        let path = folder.path(percentEncoded: false)
        let add = await ctx.run(Commands.gitAdd(path, ["Orbit Profile.json", "files"]))
        guard add.ok else { return ActionOutcome(ok: false, message: "git couldn't add the files: \(add.failureMessage)") }
        let commit = await ctx.run(Commands.gitCommit(path, message: "Orbit profile, \(Date().formatted(date: .abbreviated, time: .shortened))"))
        guard commit.ok else {
            let nothing = commit.stdout.contains("nothing to commit") || commit.stdout.contains("nothing added")
            return ActionOutcome(ok: nothing, message: nothing ? "Nothing changed since the last commit." : "git couldn't commit: \(commit.failureMessage)")
        }
        return ActionOutcome(ok: true, message: commit.simulated ? "Practice: nothing was committed." : "Committed in \(paths.tilde(folder)). Nothing was pushed.")
    }

    /// Reads a profile from a .zip Orbit saved, or the "Orbit Profile.json" inside one.
    public func readProfile(at url: URL) async throws -> OrbitProfile {
        if url.pathExtension.lowercased() == "json" { return try OrbitProfile.decode(Data(contentsOf: url)) }
        let unpacked = FileManager.default.temporaryDirectory.appending(path: "Orbit-import-\(UUID().uuidString.prefix(8))")
        let result = await ctx.run(Commands.unzip(url, into: unpacked))
        guard result.ok else { throw StepFailed(message: "That file couldn't be opened as a .zip: \(result.failureMessage)") }
        let found = FileManager.default.enumerator(at: unpacked, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.first { $0.lastPathComponent == "Orbit Profile.json" }
        guard let found else { throw StepFailed(message: "That .zip has no Orbit profile in it.") }
        return try OrbitProfile.decode(Data(contentsOf: found))
    }

    /// What importing writes into each file it touches: Orbit's version for the new settings, or the
    /// profile's own for files edited by hand where it was made. (Karabiner's is rebuilt by its own step.)
    func importedFiles(_ profile: OrbitProfile, barOn: Bool) -> [ManagedFile: String] {
        let next = profile.settings(keepingLocal: settings)
        let p = next.palette
        let changed = profile.changedSettings(from: settings)
        var files: [ManagedFile: String] = [:]
        for file in Set(changed.flatMap(OrbitProfile.files(forSetting:))) {
            files[file] = switch file {
            case .yabairc: YabaiConfig.render(next, barReserved: barOn ? next.bar.reservedSpace : nil)
            case .bordersrc: BordersConfig.render(next.glow, palette: p)
            case .sketchybarrc: SketchyBarConfig.rc(next.bar)
            case .sketchybarColors: SketchyBarConfig.colors(p)
            case .batTheme: TerminalThemes.bat(p)
            case .batConfig: TerminalThemes.batConfig()
            case .btopTheme: TerminalThemes.btop(p)
            case .lazygit: TerminalThemes.lazygit(p)
            case .fastfetch: TerminalThemes.fastfetch(p)
            case .tmuxTheme: next.themeTmux ? TerminalThemes.tmux(p) : nil
            case .warpTheme: next.themeSync.warp ? WarpTheme.render(p) : nil
            case .sorterScript: SorterScript.render(next.downloads)
            case .karabiner: nil
            }
        }
        for file in ManagedFile.allCases where !file.ownerRewrites {
            if let text = profile.editedText(file, token: ctx.store.linkToken) { files[file] = text }
        }
        return files
    }

    /// Managed files edited by hand on this Mac that importing would write over. They're shown before
    /// importing; their copies are kept.
    public func filesImportReplaces(_ profile: OrbitProfile) -> [ManagedFile] {
        importedFiles(profile, barOn: true).filter { file, text in
            let current = ctx.files.read(file.url(paths))
            return ctx.store.registry.verdict(for: file, current: current) == .editedByHand && current != Data(text.utf8)
        }.keys.sorted { $0.rawValue < $1.rawValue }
    }

    /// Brings a profile's setup here as one change: each part that differs is written and applied as
    /// Orbit would (so it takes effect at once), then files that were edited by hand where the profile
    /// was made go in as they are. Nothing is switched on or off. Undo puts it all back.
    public func importProfile(_ profile: OrbitProfile, policy: WritePolicy = .askIfEdited) async throws -> ActionOutcome {
        let next = profile.settings(keepingLocal: settings)
        let changed = Set(profile.changedSettings(from: settings))
        let token = ctx.store.linkToken
        // Karabiner's file also holds this Mac's own keyboard setup, so it's always rebuilt from the settings.
        let carried = ManagedFile.allCases.filter { !$0.ownerRewrites }.compactMap { file in profile.editedText(file, token: token).map { (file, $0) } }
        // Every file it would write over is checked up front, so a hand-edited one asks before anything changes.
        try checkEdits(importedFiles(profile, barOn: await isRunning(.sketchybar)), policy: policy)
        return await steps { undo in
            func run(_ outcome: ActionOutcome) throws {
                undo += outcome.undo
                guard outcome.ok else { throw StepFailed(message: outcome.message) }
            }
            // Each part sets its own settings as it goes, so it sees what's changing.
            if changed.contains("tiling") { try run(try await applyTiling(next.tiling, policy: policy)) }
            if changed.contains("floatingApps") { try run(try await applyFloatingApps(next.floatingApps, policy: policy)) }
            if changed.contains("glow") { try run(try await applyGlow(next.glow, policy: policy)) }
            if changed.contains("bar") { try run(try await applyBar(next.bar, policy: policy)) }
            if changed.contains("keyboard") { try run(try await applyKeyboard(next.keyboard)) }
            if changed.contains("theme") || changed.contains("themeTmux") {
                try run(try await applyTheme(next.theme, tmux: next.themeTmux, policy: policy))
            }
            if changed.contains("downloads") { try run(try await applyDownloads(next.downloads, policy: policy)) }
            undo += changeSettings { $0 = next }
            var written = Set<ManagedFile>()
            let backups = backupFolder("profile import")
            for (file, text) in carried {
                let steps = try write(file, text, executable: file.isExecutable, backups: backups)
                if !steps.isEmpty { written.insert(file) }
                undo += steps
            }
            await reload(written)
            let date = profile.exported.formatted(date: .abbreviated, time: .omitted)
            let parts = changed.count == 1 ? "1 part of the setup" : "\(changed.count) parts of the setup"
            let files = written.isEmpty ? "" : ", and \(written.count) hand-edited \(written.count == 1 ? "file" : "files") as they were"
            return changed.isEmpty && written.isEmpty ? "The profile from \(date) matches this Mac already."
                                                      : "Imported \(parts) from the profile of \(date)\(files)."
        }
    }
}
