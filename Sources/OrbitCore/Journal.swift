import Foundation

/// A macOS preference value, kept with its exact type so restoring it is faithful.
public indirect enum PrefValue: Codable, Sendable, Equatable {
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case data(Data)
    case date(Date)
    case array([PrefValue])
    case dict([String: PrefValue])
}

/// A change under way, saved as it goes: if Orbit stops before it finishes, the next launch turns it
/// into an "interrupted" history entry that can still undo what was done.
public struct InflightChange: Codable, Sendable, Equatable, Identifiable {
    /// Also the id of the change's history entry, so one that made it there is recognised.
    public var id: UUID
    public var title: String
    public var started: Date
    public var actions: [UndoAction]

    public init(id: UUID = UUID(), title: String, started: Date = Date(), actions: [UndoAction] = []) {
        self.id = id
        self.title = title
        self.started = started
        self.actions = actions
    }

    /// How the change shows in the history when Orbit stopped before it finished.
    public var interrupted: JournalEntry {
        var entry = JournalEntry(id: id, title: title, actions: actions, date: started)
        entry.outcome = .interrupted
        entry.message = actions.isEmpty ? "Orbit stopped before this finished."
                                        : "Orbit stopped before this finished. Undo puts back what it had already changed."
        return entry
    }
}

/// Something Orbit can put back the way it was.
public enum UndoAction: Codable, Sendable, Equatable {
    /// Put a file back from a backup copy; a nil backup means it didn't exist, so it goes to the Trash.
    case restoreFile(path: String, backup: String?)
    /// Put a preference back; a nil value means it wasn't set, so it's removed.
    case restorePreference(domain: String, key: String, value: PrefValue?)
    /// Move something back to where it was.
    case moveBack(current: String, original: String)
    /// Switch a background helper back on or off.
    case helper(Helper, wasOn: Bool)
    /// Put a global git setting back; nil means it wasn't set.
    case gitConfig(key: String, value: String?)
    /// Put back the Orbit settings this change altered.
    case restoreSettings(SettingsUndo)
    /// Open an app at login again, or stop opening it.
    case loginItem(name: String, path: String, wasOn: Bool)

    /// What this step puts back, so two changes that touched the same thing can be found.
    public var targets: [String] {
        switch self {
        case .restoreFile(let path, _): ["file \(path)"]
        case .restorePreference(let domain, let key, _): ["preference \(domain) \(key)"]
        case .moveBack(let current, let original): ["file \(current)", "file \(original)"]
        case .helper(let helper, _): ["helper \(helper.rawValue)"]
        case .gitConfig(let key, _): ["git \(key)"]
        case .restoreSettings(let settings): settings.changedFields.map { "setting \($0)" }
        case .loginItem(let name, _, _): ["login item \(name)"]
        }
    }
}

/// The Orbit settings one change altered, as they were before it. Only those are put back, so
/// anything changed since by other means (say, an edited mode) stays.
public struct SettingsUndo: Codable, Sendable, Equatable {
    public var theme: ThemeID?
    public var themeTmux: Bool?
    public var wallpaperFollowsTheme: Bool?
    public var tiling: TilingSettings?
    public var floatingApps: [String]?
    public var glow: GlowSettings?
    public var bar: BarSettings?
    public var keyboard: KeyboardSettings?

    public init(before: OrbitSettings, after: OrbitSettings) {
        if before.theme != after.theme { theme = before.theme }
        if before.themeTmux != after.themeTmux { themeTmux = before.themeTmux }
        if before.wallpaperFollowsTheme != after.wallpaperFollowsTheme { wallpaperFollowsTheme = before.wallpaperFollowsTheme }
        if before.tiling != after.tiling { tiling = before.tiling }
        if before.floatingApps != after.floatingApps { floatingApps = before.floatingApps }
        if before.glow != after.glow { glow = before.glow }
        if before.bar != after.bar { bar = before.bar }
        if before.keyboard != after.keyboard { keyboard = before.keyboard }
    }

    /// The settings this puts back, by name.
    public var changedFields: [String] {
        [("theme", theme != nil), ("themeTmux", themeTmux != nil), ("wallpaperFollowsTheme", wallpaperFollowsTheme != nil),
         ("tiling", tiling != nil), ("floatingApps", floatingApps != nil), ("glow", glow != nil), ("bar", bar != nil),
         ("keyboard", keyboard != nil)].filter(\.1).map(\.0)
    }

    public var isEmpty: Bool {
        theme == nil && themeTmux == nil && wallpaperFollowsTheme == nil && tiling == nil && floatingApps == nil
            && glow == nil && bar == nil && keyboard == nil
    }

    public func apply(to settings: inout OrbitSettings) {
        if let theme { settings.theme = theme }
        if let themeTmux { settings.themeTmux = themeTmux }
        if let wallpaperFollowsTheme { settings.wallpaperFollowsTheme = wallpaperFollowsTheme }
        if let tiling { settings.tiling = tiling }
        if let floatingApps { settings.floatingApps = floatingApps }
        if let glow { settings.glow = glow }
        if let bar { settings.bar = bar }
        if let keyboard { settings.keyboard = keyboard }
    }
}

/// One change the user made through Orbit, and how to undo it.
public struct JournalEntry: Codable, Sendable, Equatable, Identifiable {
    public enum Outcome: String, Codable, Sendable {
        case done, failed, interrupted
    }

    public var id: UUID
    public var date: Date
    public var title: String
    public var actions: [UndoAction]
    public var undone: Bool
    /// How the change went; entries from before this was recorded count as done.
    public var outcome: Outcome?
    /// What went wrong, when it didn't work.
    public var message: String?

    public var failed: Bool { outcome == .failed || outcome == .interrupted }

    public init(id: UUID = UUID(), title: String, actions: [UndoAction], date: Date = Date()) {
        self.id = id
        self.date = date
        self.title = title
        self.actions = actions
        self.undone = false
    }

    /// Later changes, still in effect, that touched something this one would put back: undoing this
    /// would quietly undo part of them as well.
    public func overtaken(in journal: [JournalEntry]) -> [JournalEntry] {
        guard let index = journal.firstIndex(where: { $0.id == id }) else { return [] }
        let mine = Set(actions.flatMap(\.targets))
        return journal[(index + 1)...].filter { !$0.undone && !mine.isDisjoint(with: $0.actions.flatMap(\.targets)) }
    }
}

/// Preferences Orbit may change, recorded at first launch so "Back to before Orbit" can restore them.
public enum WatchedPreferences {
    public static let dockDomain = "com.apple.dock"
    public static let finderDomain = "com.apple.finder"
    public static let screenshotDomain = "com.apple.screencapture"
    public static let globalDomain = "NSGlobalDomain"

    public static let keys: [(domain: String, key: String)] = [
        (dockDomain, "persistent-apps"), (dockDomain, "persistent-others"), (dockDomain, "autohide"),
        (dockDomain, "autohide-delay"), (dockDomain, "autohide-time-modifier"), (dockDomain, "tilesize"),
        (dockDomain, "show-recents"), (dockDomain, "minimize-to-application"), (dockDomain, "mineffect"),
        (dockDomain, "mru-spaces"), (dockDomain, "expose-group-apps"), (dockDomain, "magnification"),
        (finderDomain, "ShowPathbar"), (finderDomain, "ShowStatusBar"), (finderDomain, "FXPreferredViewStyle"),
        (finderDomain, "_FXSortFoldersFirst"), (finderDomain, "FXDefaultSearchScope"),
        (finderDomain, "FXEnableExtensionChangeWarning"), (finderDomain, "AppleShowAllFiles"),
        (screenshotDomain, "location"), (screenshotDomain, "disable-shadow"), (screenshotDomain, "type"),
        (globalDomain, "KeyRepeat"), (globalDomain, "InitialKeyRepeat"), (globalDomain, "AppleShowAllExtensions"),
        (globalDomain, "_HIHideMenuBar"), (globalDomain, "AppleMenuBarVisibleInFullscreen")
    ]
}

/// What things looked like before Orbit changed anything.
public struct Baseline: Codable, Sendable, Equatable {
    public var date: Date
    public var preferences: [String: PrefValue]   // "domain|key" → value; missing means unset
    public var files: [String: String]            // path → backup copy (missing path means no file)
    public var helpersOn: [Helper: Bool]
    public var wallpaper: String?
    public var gitDeltaTheme: String?

    public init(date: Date = Date(), preferences: [String: PrefValue] = [:], files: [String: String] = [:],
                helpersOn: [Helper: Bool] = [:], wallpaper: String? = nil, gitDeltaTheme: String? = nil) {
        self.date = date
        self.preferences = preferences
        self.files = files
        self.helpersOn = helpersOn
        self.wallpaper = wallpaper
        self.gitDeltaTheme = gitDeltaTheme
    }

    public static func key(_ domain: String, _ key: String) -> String { "\(domain)|\(key)" }
}
