import AppKit
import Foundation
import OrbitCore

extension Actions {
    /// Switches one of the theme's other places on or off. On, it takes the current theme at once. Off,
    /// the editor's theme and the accent colour go back to what they were (unless you've changed them
    /// since); Warp keeps its Orbit theme, which simply stops following.
    public func setThemeSync(_ target: ThemeSyncTarget, on: Bool, policy: WritePolicy = .askIfEdited) async throws -> ActionOutcome {
        let p = settings.palette
        if target == .warp, on { try checkEdits([.warpTheme: WarpTheme.render(p)], policy: policy) }
        return await steps { undo in
            switch (target, on) {
            case (.warp, true):
                undo += try write(.warpTheme, WarpTheme.render(p), backups: backupFolder("warp theme"))
                undo += changeSettings { $0.themeSync.warp = true }
                return "Warp has an Orbit theme in \(p.name)'s colours. Pick it once in Warp: Settings → Appearance → Themes → Orbit."
            case (.warp, false):
                undo += changeSettings { $0.themeSync.warp = false }
                return "Warp's Orbit theme stays as it is and no longer follows yours."
            case (.editor, true):
                let current = try editorValues()
                // Switched on twice, the first "before" is the one that counts.
                let before = settings.themeSync.editor ? settings.themeSync.editorThemeBefore : current[EditorTheme.themeKey]?.stringValue
                undo += changeSettings {
                    $0.themeSync.editor = true
                    $0.themeSync.editorThemeBefore = before
                }
                let changes = EditorTheme.changes(p, installed: installedEditorThemes(), current: current)
                undo += try patchJSON(paths.editorSettings, changes, backups: backupFolder("editor theme"))
                return "Antigravity IDE wears \(p.name) now."
            case (.editor, false):
                undo += try editorSyncOff()
                undo += changeSettings {
                    $0.themeSync.editor = false
                    $0.themeSync.editorThemeBefore = nil
                }
                return "Antigravity IDE has its own colours back."
            case (.accent, true):
                let before = settings.themeSync.accent ? settings.themeSync.accentBefore
                                                       : ctx.readings.preference(WatchedPreferences.globalDomain, MacAccent.key)
                undo += changeSettings {
                    $0.themeSync.accent = true
                    $0.themeSync.accentBefore = before
                }
                let accent = MacAccent.matching(p.id)
                undo += setAccent(.int(accent.rawValue))
                return "The accent colour is \(accent.name) now, to go with \(p.name)."
            case (.accent, false):
                undo += accentSyncOff()
                undo += changeSettings {
                    $0.themeSync.accent = false
                    $0.themeSync.accentBefore = nil
                }
                return "The accent colour is yours again."
            }
        }
    }

    /// The other places, brought up to date with a new theme (each only when switched on). The editor's
    /// file may be unreadable; that's said, and the rest of the theme still goes ahead.
    func syncTheme(_ p: Palette, backups: URL) -> (undo: [UndoAction], notes: [String]) {
        var undo: [UndoAction] = []
        var notes: [String] = []
        let sync = settings.themeSync
        if sync.editor {
            do {
                let changes = EditorTheme.changes(p, installed: installedEditorThemes(), current: try editorValues())
                undo += try patchJSON(paths.editorSettings, changes, backups: backups)
            } catch {
                notes.append("Antigravity IDE's colours were left as they were: \(error.localizedDescription)")
            }
        }
        if sync.accent { undo += setAccent(.int(MacAccent.matching(p.id).rawValue)) }
        return (undo, notes)
    }

    /// Orbit's colours out of the editor's settings, and its theme back as it was, if it's still Orbit's choice.
    func editorSyncOff() throws -> [UndoAction] {
        let orbitTheme = EditorTheme.theme(for: settings.theme, installed: installedEditorThemes())
        let changes = EditorTheme.removal(orbitTheme: orbitTheme, before: settings.themeSync.editorThemeBefore, current: try editorValues())
        return try patchJSON(paths.editorSettings, changes, backups: backupFolder("editor theme"))
    }

    /// The accent colour back as it was, if it's still the one Orbit chose.
    func accentSyncOff() -> [UndoAction] {
        let now = ctx.readings.preference(WatchedPreferences.globalDomain, MacAccent.key)
        guard now == .int(MacAccent.matching(settings.theme).rawValue) else { return [] }
        return setAccent(settings.themeSync.accentBefore)
    }

    func editorValues() throws -> [String: JSONValue] {
        let text = ctx.files.read(paths.editorSettings).map { String(decoding: $0, as: UTF8.self) } ?? ""
        return try JSONKeyPatch.values(EditorTheme.keys, in: text)
    }

    /// The colour themes Antigravity IDE has: its own, and those added from its marketplace.
    func installedEditorThemes() -> Set<String> {
        var manifests: [URL] = []
        let fm = FileManager.default
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: EditorTheme.bundleID) {
            let bundled = app.appending(path: "Contents/Resources/app/extensions")
            for name in (try? fm.contentsOfDirectory(atPath: bundled.path(percentEncoded: false))) ?? [] where name.hasPrefix("theme-") {
                manifests.append(bundled.appending(path: name).appending(path: "package.json"))
            }
        }
        for name in (try? fm.contentsOfDirectory(atPath: paths.editorExtensions.path(percentEncoded: false))) ?? [] {
            manifests.append(paths.editorExtensions.appending(path: name).appending(path: "package.json"))
        }
        return Set(manifests.flatMap { url in (try? Data(contentsOf: url)).map(EditorTheme.themeNames(inManifest:)) ?? [] })
    }

    /// Sets (or, with nil, clears) the accent colour, and tells apps so they show it at once.
    func setAccent(_ value: PrefValue?) -> [UndoAction] {
        let old = ctx.readings.preference(WatchedPreferences.globalDomain, MacAccent.key)
        guard old != value else { return [] }
        ctx.prefs.set(WatchedPreferences.globalDomain, MacAccent.key, value)
        announceAccentChange()
        return [.restorePreference(domain: WatchedPreferences.globalDomain, key: MacAccent.key, value: old)]
    }

    /// Apps pick up a new accent colour when told about it, as System Settings tells them.
    func announceAccentChange() {
        guard ctx.prefs is LivePreferences else { return }
        let center = DistributedNotificationCenter.default()
        center.postNotificationName(.init("AppleColorPreferencesChangedNotification"), object: nil, userInfo: nil, deliverImmediately: true)
        center.postNotificationName(.init("AppleAquaColorVariantChanged"), object: nil, userInfo: nil, deliverImmediately: true)
    }
}
