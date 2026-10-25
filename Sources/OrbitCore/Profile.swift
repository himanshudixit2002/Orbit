import Foundation

/// Orbit's whole setup in one file, to keep as a backup or bring to another Mac: the settings, and the
/// config files as they are (with which ones were edited by hand). The link token never leaves the Mac:
/// it's swapped for a placeholder, and this Mac's own goes back in on import.
public struct OrbitProfile: Sendable, Equatable {
    public static let format = 1
    public static let tokenPlaceholder = "ORBIT-LINK-TOKEN"

    public var exported: Date
    public var settings: OrbitSettings
    /// Config files by name (`ManagedFile` raw values).
    public var files: [String: String]
    /// The files that were edited by hand where the profile was made: they travel as they are.
    public var edited: [String]

    public init(exported: Date = Date(), settings: OrbitSettings, files: [String: String], edited: [String]) {
        // Whole seconds, as the file keeps it, so a profile reads back exactly as it was.
        self.exported = Date(timeIntervalSince1970: exported.timeIntervalSince1970.rounded(.down))
        self.settings = settings
        self.files = files
        self.edited = edited
    }

    /// The setup as it is now; `token` is taken out of every file.
    public static func make(settings: OrbitSettings, files: [ManagedFile: String], edited: Set<ManagedFile>, token: String,
                            date: Date = Date()) -> OrbitProfile {
        var texts: [String: String] = [:]
        for (file, text) in files { texts[file.rawValue] = token.isEmpty ? text : text.replacingOccurrences(of: token, with: tokenPlaceholder) }
        return OrbitProfile(exported: date, settings: settings, files: texts, edited: edited.map(\.rawValue).sorted())
    }

    public struct TooNew: LocalizedError {
        public var errorDescription: String? { "This profile was made by a newer Orbit. Update Orbit, then import it." }
    }

    private struct Stored: Codable {
        var format: Int
        var exported: Date
        var settings: JSONValue
        var files: [String: String]?
        var edited: [String]?
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let stored = Stored(format: Self.format, exported: exported, settings: try JSONValue(encoding: settings), files: files, edited: edited)
        return try encoder.encode(stored)
    }

    /// Reads a profile; settings from an older Orbit load as usual, anything they lack taking its default.
    public static func decode(_ data: Data) throws -> OrbitProfile {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let stored = try decoder.decode(Stored.self, from: data)
        guard stored.format <= format else { throw TooNew() }
        let settings = try OrbitSettings.decode(JSONEncoder().encode(stored.settings))
        return OrbitProfile(exported: stored.exported, settings: settings, files: stored.files ?? [:], edited: stored.edited ?? [])
    }

    /// The settings to use after importing: the profile's, keeping what belongs to this Mac (whether
    /// setup is done, opening at login, which other apps wear the theme, the Doctor's ignored findings).
    public func settings(keepingLocal local: OrbitSettings) -> OrbitSettings {
        var next = settings
        next.version = local.version
        next.setupCompleted = local.setupCompleted
        next.openAtLogin = local.openAtLogin
        next.themeSync = local.themeSync
        next.doctorIgnored = local.doctorIgnored
        return next
    }

    /// A hand-edited file to bring over as it is, with this Mac's link token back in.
    public func editedText(_ file: ManagedFile, token: String) -> String? {
        guard edited.contains(file.rawValue), let text = files[file.rawValue] else { return nil }
        return text.replacingOccurrences(of: Self.tokenPlaceholder, with: token)
    }

    /// The settings (by name) that importing changes here.
    public func changedSettings(from local: OrbitSettings) -> [String] {
        SettingsUndo(before: local, after: settings(keepingLocal: local)).changedFields
    }

    /// In a few words, for the import preview.
    public static func title(ofSetting key: String) -> String {
        switch key {
        case "theme": "Theme"
        case "wallpaperFollowsTheme": "Wallpaper follows the theme"
        case "themeTmux": "tmux colours"
        case "tiling": "Window tiling"
        case "floatingApps": "Apps that float"
        case "glow": "Window glow"
        case "bar": "Menu bar"
        case "keyboard": "Caps Lock keys and key repeat"
        case "modes": "Modes"
        case "hotKey": "Command palette shortcut"
        case "downloads": "Downloads sorting"
        case "windowLayouts": "Saved window arrangements"
        default: key
        }
    }

    /// The config files each setting is written into.
    public static func files(forSetting key: String) -> [ManagedFile] {
        switch key {
        case "tiling", "floatingApps": [.yabairc]
        case "glow": [.bordersrc]
        case "bar": [.sketchybarrc, .yabairc]
        case "keyboard": [.karabiner]
        case "theme", "themeTmux": [.sketchybarColors, .bordersrc, .batTheme, .batConfig, .btopTheme, .lazygit, .fastfetch, .tmuxTheme, .warpTheme]
        case "downloads": [.sorterScript]
        default: []
        }
    }
}
