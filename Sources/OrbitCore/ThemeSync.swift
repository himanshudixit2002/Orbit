import Foundation

/// Other apps that can wear Orbit's theme. Each is off until the user switches it on.
public struct ThemeSyncSettings: Codable, Sendable, Equatable {
    /// Warp gets an "Orbit" theme that follows yours (picked once in Warp's settings).
    public var warp = false
    /// Antigravity IDE's colours follow the theme.
    public var editor = false
    /// The Mac's accent colour follows the theme.
    public var accent = false
    /// The editor's colour theme before Orbit set it (nil: none was set), put back when this goes off.
    public var editorThemeBefore: String?
    /// The accent colour before Orbit set it (nil: none was set), put back when this goes off.
    public var accentBefore: PrefValue?

    public init() {}

    public subscript(target: ThemeSyncTarget) -> Bool {
        get {
            switch target {
            case .warp: warp
            case .editor: editor
            case .accent: accent
            }
        }
        set {
            switch target {
            case .warp: warp = newValue
            case .editor: editor = newValue
            case .accent: accent = newValue
            }
        }
    }
}

public enum ThemeSyncTarget: String, Codable, Sendable, CaseIterable {
    case warp, editor, accent

    /// Mid-sentence: "Stopped colouring Warp with the theme".
    public var title: String {
        switch self {
        case .warp: "Warp"
        case .editor: "Antigravity IDE"
        case .accent: "the accent colour"
        }
    }
}

/// macOS's accent colours, numbered as the AppleAccentColor preference numbers them.
public enum MacAccent: Int, Sendable, CaseIterable {
    case graphite = -1, red, orange, yellow, green, blue, purple, pink

    public static let key = "AppleAccentColor"

    /// The one closest to a theme's glow.
    public static func matching(_ id: ThemeID) -> MacAccent {
        switch id {
        case .tokyoNight, .nord: .blue
        case .catppuccin, .dracula, .rosePine: .purple
        case .sunset: .orange
        }
    }

    public var name: String { String(describing: self) }
}

/// Warp's theme file: picked once in Warp, it follows Orbit's theme from then on.
public enum WarpTheme {
    public static func render(_ p: Palette) -> String {
        func q(_ c: RGB) -> String { "'\(c.hex)'" }
        func bright(_ c: RGB) -> String { q(c.mixed(with: p.fg, 0.2)) }
        return """
        # Orbit's theme for Warp, in \(p.name)'s colours. Orbit rewrites this file when you switch themes.
        name: Orbit
        accent: \(q(p.accent))
        background: \(q(p.bg))
        foreground: \(q(p.fg))
        details: darker
        terminal_colors:
          normal:
            black: \(q(p.surface))
            red: \(q(p.red))
            green: \(q(p.green))
            yellow: \(q(p.yellow))
            blue: \(q(p.accent))
            magenta: \(q(p.accent2))
            cyan: \(q(p.cyan))
            white: \(q(p.fg.mixed(with: p.muted, 0.3)))
          bright:
            black: \(q(p.line))
            red: \(bright(p.red))
            green: \(bright(p.green))
            yellow: \(bright(p.yellow))
            blue: \(bright(p.accent))
            magenta: \(bright(p.accent2))
            cyan: \(q(p.teal))
            white: \(q(p.fg))

        """
    }
}

/// Antigravity IDE (a VS Code relative) in Orbit's theme: the editor's own copy of the theme when it
/// has one, otherwise its Default Dark Modern with the palette's colours laid over it. Only the three
/// keys below are touched, and inside the two colour settings only Orbit's own entries, which apply
/// to Default Dark Modern alone: everything else in the file stays as the user left it.
public enum EditorTheme {
    public static let bundleID = "com.google.antigravity-ide"
    public static let themeKey = "workbench.colorTheme"
    public static let colorsKey = "workbench.colorCustomizations"
    public static let tokensKey = "editor.tokenColorCustomizations"
    public static let keys: Set<String> = [themeKey, colorsKey, tokensKey]
    public static let base = "Default Dark Modern"
    static let scope = "[\(base)]"

    /// The editor's themes that are the palette: bundled (Tokyo Night) or from its marketplace.
    public static func themes(matching id: ThemeID) -> [String] {
        switch id {
        case .tokyoNight: ["Tokyo Night"]
        case .catppuccin: ["Catppuccin Mocha"]
        case .dracula: ["Dracula Theme", "Dracula"]
        case .nord: ["Nord"]
        case .rosePine: ["Rosé Pine"]
        case .sunset: []
        }
    }

    public static func theme(for id: ThemeID, installed: Set<String>) -> String {
        themes(matching: id).first(where: installed.contains) ?? base
    }

    /// The theme names an extension's package.json offers (its ids, or labels when they have none).
    public static func themeNames(inManifest data: Data) -> [String] {
        guard let manifest = try? JSONDecoder().decode(JSONValue.self, from: data),
              case .array(let themes)? = manifest.objectValue?["contributes"]?.objectValue?["themes"] else { return [] }
        return themes.compactMap { theme in
            let fields = theme.objectValue
            let name = fields?["id"]?.stringValue ?? fields?["label"]?.stringValue
            return name.flatMap { $0.hasPrefix("%") ? nil : $0 }
        }
    }

    /// The window's colours, by the editor's colour ids (#rrggbbaa where it needs to see through).
    public static func colors(_ p: Palette) -> [String: String] {
        var colors = [
            "focusBorder": p.accent, "textLink.foreground": p.accent, "progressBar.background": p.accent,
            "editor.background": p.bg, "editor.foreground": p.fg, "editor.lineHighlightBackground": p.surface,
            "editorCursor.foreground": p.accent, "editorLineNumber.foreground": p.line, "editorLineNumber.activeForeground": p.fg,
            "editorGroupHeader.tabsBackground": p.bgDark, "tab.activeBackground": p.bg, "tab.activeForeground": p.fg,
            "tab.activeBorderTop": p.accent, "tab.inactiveBackground": p.bgDark, "tab.inactiveForeground": p.muted,
            "sideBar.background": p.bgDark, "sideBar.foreground": p.fg.mixed(with: p.muted, 0.4), "sideBarSectionHeader.background": p.bgDark,
            "activityBar.background": p.bgDark, "activityBar.foreground": p.accent, "activityBar.inactiveForeground": p.muted,
            "activityBarBadge.background": p.accent, "activityBarBadge.foreground": p.bgDark,
            "titleBar.activeBackground": p.bgDark, "titleBar.activeForeground": p.fg, "titleBar.inactiveBackground": p.bgDark,
            "statusBar.background": p.bgDark, "statusBar.foreground": p.muted, "panel.background": p.bgDark, "panel.border": p.line,
            "list.activeSelectionBackground": p.surface, "list.hoverBackground": p.surface, "input.background": p.surface,
            "dropdown.background": p.surface, "button.background": p.accent, "button.foreground": p.bgDark,
            "badge.background": p.accent, "badge.foreground": p.bgDark,
            "terminal.background": p.bg, "terminal.foreground": p.fg,
            "terminal.ansiBlack": p.surface, "terminal.ansiRed": p.red, "terminal.ansiGreen": p.green, "terminal.ansiYellow": p.yellow,
            "terminal.ansiBlue": p.accent, "terminal.ansiMagenta": p.accent2, "terminal.ansiCyan": p.cyan, "terminal.ansiWhite": p.fg,
            "terminal.ansiBrightBlack": p.line, "terminal.ansiBrightRed": p.red, "terminal.ansiBrightGreen": p.green,
            "terminal.ansiBrightYellow": p.yellow, "terminal.ansiBrightBlue": p.accent, "terminal.ansiBrightMagenta": p.accent2,
            "terminal.ansiBrightCyan": p.teal, "terminal.ansiBrightWhite": p.fg
        ].mapValues(\.hex)
        colors["editor.selectionBackground"] = p.accent.hex + "40"
        return colors
    }

    /// Code's colours, by the editor's simple token groups.
    public static func tokens(_ p: Palette) -> [String: String] {
        ["comments": p.muted, "strings": p.green, "keywords": p.accent2, "numbers": p.orange,
         "types": p.cyan, "functions": p.accent, "variables": p.fg].mapValues(\.hex)
    }

    static let colorIDs = Set(colors(.tokyoNight).keys)
    static let tokenIDs = Set(tokens(.tokyoNight).keys)

    /// What to change to dress the editor in `p`, given the three keys' values now (missing: not set).
    public static func changes(_ p: Palette, installed: Set<String>, current: [String: JSONValue]) -> [String: JSONKeyPatch.Change] {
        let theme = theme(for: p.id, installed: installed)
        let ours = theme == base
        return different([
            themeKey: .set(.string(theme)),
            colorsKey: merged(current[colorsKey], ids: colorIDs, with: ours ? colors(p) : [:]),
            tokensKey: merged(current[tokensKey], ids: tokenIDs, with: ours ? tokens(p) : [:])
        ], from: current)
    }

    /// Orbit's colours taken out again, and the theme put back to `before`, if it's still the one Orbit chose.
    public static func removal(orbitTheme: String, before: String?, current: [String: JSONValue]) -> [String: JSONKeyPatch.Change] {
        var changes = [
            colorsKey: merged(current[colorsKey], ids: colorIDs, with: [:]),
            tokensKey: merged(current[tokensKey], ids: tokenIDs, with: [:])
        ]
        if current[themeKey] == .string(orbitTheme) { changes[themeKey] = before.map { .set(.string($0)) } ?? .remove }
        return different(changes, from: current)
    }

    /// A colour setting with Orbit's entries for Default Dark Modern swapped for `colors` (none: taken out).
    static func merged(_ current: JSONValue?, ids: Set<String>, with colors: [String: String]) -> JSONKeyPatch.Change {
        var setting = current?.objectValue ?? [:]
        var scoped = setting[scope]?.objectValue ?? [:]
        for id in ids { scoped[id] = nil }
        for (id, color) in colors { scoped[id] = .string(color) }
        setting[scope] = scoped.isEmpty ? nil : .object(scoped)
        return setting.isEmpty ? .remove : .set(.object(setting))
    }

    /// Only the changes that change something, so an untouched file keeps its own formatting.
    static func different(_ changes: [String: JSONKeyPatch.Change], from current: [String: JSONValue]) -> [String: JSONKeyPatch.Change] {
        changes.filter { key, change in
            switch change {
            case .set(let value): current[key] != value
            case .remove: current[key] != nil
            }
        }
    }
}
