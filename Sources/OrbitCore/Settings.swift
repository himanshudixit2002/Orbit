import Foundation

/// Everything the user can change in Orbit. Saved as JSON; missing keys fall back to these defaults,
/// which match how the Mac was set up before Orbit.
public struct OrbitSettings: Codable, Sendable, Equatable {
    public var version = 2
    public var theme: ThemeID = .tokyoNight
    /// Off until the user asks: a theme should never replace a wallpaper they chose.
    public var wallpaperFollowsTheme = false
    public var themeTmux = false
    public var tiling = TilingSettings()
    public var floatingApps = OrbitSettings.defaultFloatingApps
    public var glow = GlowSettings()
    public var bar = BarSettings()
    public var keyboard = KeyboardSettings()
    public var modes = ModeDefinition.defaults
    public var setupCompleted = false
    /// Whether the user wants Orbit to open at login; nil until they choose (it then opens, quietly).
    public var openAtLogin: Bool?
    /// The shortcut that opens the command palette from anywhere; nil means the standard Hyper+Space.
    public var hotKey: HotKeySetting?
    /// Doctor findings the user chose to ignore, by id.
    public var doctorIgnored: [String] = []
    public var downloads = DownloadSettings()
    /// Other apps that wear the theme too.
    public var themeSync = ThemeSyncSettings()

    public init() {}

    public static let defaultFloatingApps = [
        "System Settings", "System Information", "Calculator", "Archive Utility", "Installer", "App Store",
        "Activity Monitor", "Disk Utility", "FaceTime", "Photo Booth", "Raycast", "Amphetamine", "Sip",
        "Wallpaper X", "Simulator", "Downloads Sorter", "uihost", "Orbit"
    ]

    public var palette: Palette { Palette.named(theme) }

    /// Decodes saved settings over the defaults, so settings saved by an older Orbit still load.
    public static func decode(_ data: Data) throws -> OrbitSettings {
        let defaults = try JSONSerialization.jsonObject(with: JSONEncoder().encode(OrbitSettings()))
        let stored = try JSONSerialization.jsonObject(with: data)
        let merged = merge(defaults, stored)
        var settings = try JSONDecoder().decode(OrbitSettings.self, from: JSONSerialization.data(withJSONObject: merged))
        // Saved by Orbit 1: everything it had still means the same; new settings take their defaults.
        if settings.version < 2 { settings.version = 2 }
        return settings
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    private static func merge(_ base: Any, _ over: Any) -> Any {
        guard let baseDict = base as? [String: Any], let overDict = over as? [String: Any] else { return over }
        var out = baseDict
        for (key, value) in overDict {
            out[key] = baseDict[key].map { merge($0, value) } ?? value
        }
        return out
    }
}

public enum TilingLayout: String, Codable, CaseIterable, Sendable, Identifiable {
    case tiles = "bsp", stack, free = "float"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .tiles: "Tiles"
        case .stack: "One at a time"
        case .free: "Free"
        }
    }

    public var blurb: String {
        switch self {
        case .tiles: "Windows share the screen side by side."
        case .stack: "Each window fills the screen; flip between them."
        case .free: "Windows stay where you put them, like normal macOS."
        }
    }
}

/// Whether pointing at a window focuses it.
public enum FocusFollowsMouse: String, Codable, CaseIterable, Sendable, Identifiable {
    case off, autofocus, autoraise

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .off: "Click to focus"
        case .autofocus: "Point to focus"
        case .autoraise: "Point to focus and raise"
        }
    }
}

public struct TilingSettings: Codable, Sendable, Equatable {
    public var layout: TilingLayout = .tiles
    public var gap = 10
    public var padding = 12
    /// New windows open on the left (or top) of the one they split, instead of the right.
    public var newWindowsFirst = false
    /// How much of a split the first window gets.
    public var splitRatio = 0.5
    /// Keep every window the same size.
    public var autoBalance = false
    public var mouseFollowsFocus = false
    public var focusFollowsMouse: FocusFollowsMouse = .off

    public init() {}
}

public enum BorderStyle: String, Codable, CaseIterable, Sendable {
    case round, square
}

public struct GlowSettings: Codable, Sendable, Equatable {
    public var width = 6.0
    public var glow = true
    public var style: BorderStyle = .round
    public var useThemeColor = true
    public var customColor = RGB(0x7aa2f7)
    public var ignoredApps = ["uihost", "Raycast"]

    public init() {}

    public func color(in palette: Palette) -> RGB { useThemeColor ? palette.accent : customColor }
}

public struct BarSettings: Codable, Sendable, Equatable {
    public var showSpaces = true
    public var showFrontApp = true
    public var showSpotify = true
    public var showCPU = true
    public var showMemory = true
    public var showVolume = true
    public var showNetwork = true
    public var showClock = true
    public var height = 34
    public var yOffset = 6

    public init() {}

    /// Room yabai keeps free at the top of the screen while the bar is on.
    public var reservedSpace: Int { height + yOffset }
}

/// What holding Caps Lock and a key does.
public enum HyperAction: Codable, Sendable, Hashable {
    /// Opens the binding's app.
    case app
    /// Opens a website in the default browser.
    case website(String)
    /// Opens a folder (a project, say) in the binding's app, or in Finder when it has none.
    case folder(String)
    /// Does something in Orbit.
    case orbit(OrbitCommand)
}

/// "Hold Caps Lock + key opens app" (or a website, a project folder, or something in Orbit).
public struct HyperBinding: Codable, Sendable, Equatable, Hashable, Identifiable {
    public var key: String
    public var appName: String
    public var appPath: String
    public var bundleID: String?
    public var action: HyperAction = .app

    public var id: String { key }

    private enum CodingKeys: String, CodingKey { case key, appName, appPath, bundleID, action }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = try c.decode(String.self, forKey: .key)
        appName = c.value(.appName, or: "")
        appPath = c.value(.appPath, or: "")
        bundleID = c.value(.bundleID, or: nil)
        action = c.value(.action, or: .app)
    }

    /// What it does, short: "Warp", "github.com", "Orbit", "turn on window tiling".
    public var label: String {
        switch action {
        case .app: appName
        case .website(let url): URL(string: url)?.host() ?? url
        case .folder(let path): URL(fileURLWithPath: path).lastPathComponent
        case .orbit(let command): command.summary
        }
    }

    /// Keys Caps Lock can be held with.
    public static let keys = Array("abcdefghijklmnopqrstuvwxyz0123456789").map(String.init)

    public init(key: String, appName: String, appPath: String, bundleID: String? = nil) {
        self.key = key
        self.appName = appName
        self.appPath = appPath
        self.bundleID = bundleID
    }

    public static let defaults: [HyperBinding] = [
        HyperBinding(key: "t", appName: "Warp", appPath: "/Applications/Warp.app"),
        HyperBinding(key: "b", appName: "Google Chrome", appPath: "/Applications/Google Chrome.app"),
        HyperBinding(key: "i", appName: "Antigravity IDE", appPath: "/Applications/Antigravity IDE.app"),
        HyperBinding(key: "c", appName: "Claude", appPath: "/Applications/Claude.app"),
        HyperBinding(key: "g", appName: "ChatGPT", appPath: "/Applications/ChatGPT.app"),
        HyperBinding(key: "w", appName: "WhatsApp", appPath: "/Applications/WhatsApp.app"),
        HyperBinding(key: "s", appName: "Spotify", appPath: "/Applications/Spotify.app"),
        HyperBinding(key: "n", appName: "Notes", appPath: "/System/Applications/Notes.app"),
        HyperBinding(key: "f", appName: "Finder", appPath: "/System/Library/CoreServices/Finder.app"),
        HyperBinding(key: "p", appName: "Postman", appPath: "/Applications/Postman.app"),
        HyperBinding(key: "d", appName: "DBeaver", appPath: "/Applications/DBeaver.app"),
        HyperBinding(key: "o", appName: "Orbit", appPath: "/Applications/Orbit.app")
    ]
}

public struct KeyboardSettings: Codable, Sendable, Equatable {
    public var capsLockEnabled = true
    public var hyperApps = HyperBinding.defaults
    /// A tap shorter than this (milliseconds) is Escape; holding longer is Hyper.
    public var tapTimeout = 300

    public init() {}
}

public enum KeepAwake: String, Codable, CaseIterable, Sendable {
    case off, system, display

    public var title: String {
        switch self {
        case .off: "Let the Mac sleep"
        case .system: "Keep the Mac awake"
        case .display: "Keep the screen on"
        }
    }
}

/// Something a mode can switch while it's on: on, off, or left as it is.
public enum ModeSwitch: String, Codable, CaseIterable, Sendable {
    case leave, on, off

    public var title: String {
        switch self {
        case .leave: "Leave"
        case .on: "On"
        case .off: "Off"
        }
    }
}

/// When a mode starts by itself, and (optionally) stops.
public struct ModeSchedule: Codable, Sendable, Equatable {
    public var enabled = false
    /// Calendar weekdays: 1 is Sunday, 7 Saturday.
    public var weekdays: Set<Int> = [2, 3, 4, 5, 6]
    /// Minutes after midnight.
    public var start = 9 * 60
    /// When it stops by itself; nil to leave it on.
    public var end: Int? = 18 * 60
    /// A notification asks before it starts.
    public var askFirst = true

    public init() {}

    private enum CodingKeys: String, CodingKey { case enabled, weekdays, start, end, askFirst }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = ModeSchedule()
        enabled = c.value(.enabled, or: fallback.enabled)
        weekdays = c.value(.weekdays, or: fallback.weekdays)
        start = c.value(.start, or: fallback.start)
        end = c.value(.end, or: fallback.end)
        askFirst = c.value(.askFirst, or: fallback.askFirst)
    }

    /// The next start after `date`, in local time: across a clock change it's the same time on the wall,
    /// and a time a clock change skips moves to the next one that exists.
    public func nextStart(after date: Date, calendar: Calendar = .current) -> Date? {
        next(start, after: date, calendar: calendar)
    }

    public func nextEnd(after date: Date, calendar: Calendar = .current) -> Date? {
        end.flatMap { next($0, after: date, calendar: calendar) }
    }

    func next(_ minutes: Int, after date: Date, calendar: Calendar) -> Date? {
        guard enabled, !weekdays.isEmpty else { return nil }
        return weekdays.compactMap { weekday in
            calendar.nextDate(after: date, matching: DateComponents(hour: minutes / 60, minute: minutes % 60, weekday: weekday),
                              matchingPolicy: .nextTime)
        }.min()
    }
}

public struct ModeDefinition: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var symbol: String
    public var blurb: String
    public var openApps: [String]
    public var quitApps: [String]
    public var hideOthers: Bool
    public var keepAwake: KeepAwake
    public var tiling: ModeSwitch = .leave
    public var glow: ModeSwitch = .leave
    public var menuBar: ModeSwitch = .leave
    /// The theme while it's on; nil leaves it.
    public var theme: ThemeID?
    /// The window style while it's on; nil leaves it.
    public var layout: TilingLayout?
    /// Websites and links it opens.
    public var urls: [String] = []
    /// Switches itself off after this many minutes.
    public var timerMinutes: Int?
    /// A Shortcuts shortcut to run when it starts.
    public var shortcut: String?
    public var schedule: ModeSchedule?

    /// Orbit 1's single switch.
    public var tilingOn: Bool {
        get { tiling == .on }
        set { tiling = newValue ? .on : .leave }
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, symbol, blurb, openApps, quitApps, hideOthers, keepAwake, tilingOn, tiling, glow, menuBar, theme, layout, urls,
             timerMinutes, shortcut, schedule
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = c.value(.name, or: id.capitalized)
        symbol = c.value(.symbol, or: "sparkles")
        blurb = c.value(.blurb, or: "")
        openApps = c.value(.openApps, or: [])
        quitApps = c.value(.quitApps, or: [])
        hideOthers = c.value(.hideOthers, or: false)
        keepAwake = c.value(.keepAwake, or: .off)
        tiling = c.value(.tiling, or: c.value(.tilingOn, or: false) ? .on : .leave)
        glow = c.value(.glow, or: .leave)
        menuBar = c.value(.menuBar, or: .leave)
        theme = c.value(.theme, or: nil)
        layout = c.value(.layout, or: nil)
        urls = c.value(.urls, or: [])
        timerMinutes = c.value(.timerMinutes, or: nil)
        shortcut = c.value(.shortcut, or: nil)
        schedule = c.value(.schedule, or: nil)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(symbol, forKey: .symbol)
        try c.encode(blurb, forKey: .blurb)
        try c.encode(openApps, forKey: .openApps)
        try c.encode(quitApps, forKey: .quitApps)
        try c.encode(hideOthers, forKey: .hideOthers)
        try c.encode(keepAwake, forKey: .keepAwake)
        try c.encode(tiling, forKey: .tiling)
        try c.encode(glow, forKey: .glow)
        try c.encode(menuBar, forKey: .menuBar)
        try c.encodeIfPresent(theme, forKey: .theme)
        try c.encodeIfPresent(layout, forKey: .layout)
        try c.encode(urls, forKey: .urls)
        try c.encodeIfPresent(timerMinutes, forKey: .timerMinutes)
        try c.encodeIfPresent(shortcut, forKey: .shortcut)
        try c.encodeIfPresent(schedule, forKey: .schedule)
    }

    public init(id: String, name: String, symbol: String, blurb: String, openApps: [String], quitApps: [String],
                hideOthers: Bool, keepAwake: KeepAwake, tilingOn: Bool) {
        self.id = id
        self.name = name
        self.symbol = symbol
        self.blurb = blurb
        self.openApps = openApps
        self.quitApps = quitApps
        self.hideOthers = hideOthers
        self.keepAwake = keepAwake
        self.tiling = tilingOn ? .on : .leave
    }

    /// A blank mode for the user to fill in.
    public static func newCustom() -> ModeDefinition {
        ModeDefinition(id: "custom-\(UUID().uuidString.prefix(8).lowercased())", name: "", symbol: "sparkles",
                       blurb: "", openApps: [], quitApps: [], hideOthers: false, keepAwake: .off, tilingOn: false)
    }

    public var isBuiltIn: Bool { Self.defaults.contains { $0.id == id } }

    public static let defaults: [ModeDefinition] = [
        ModeDefinition(id: "work", name: "Work", symbol: "laptopcomputer",
                       blurb: "Opens your work apps and keeps the Mac awake.",
                       openApps: ["Warp", "Antigravity IDE", "Google Chrome", "Claude"], quitApps: [],
                       hideOthers: false, keepAwake: .system, tilingOn: true),
        ModeDefinition(id: "focus", name: "Focus", symbol: "scope",
                       blurb: "Closes chat apps and hides everything else.",
                       openApps: [], quitApps: ["WhatsApp", "Telegram", "Messages"],
                       hideOthers: true, keepAwake: .system, tilingOn: false),
        ModeDefinition(id: "chill", name: "Chill", symbol: "music.note",
                       blurb: "Music and chats, and the Mac can sleep.",
                       openApps: ["Spotify", "WhatsApp"], quitApps: [],
                       hideOthers: false, keepAwake: .off, tilingOn: false),
        ModeDefinition(id: "present", name: "Present", symbol: "play.rectangle",
                       blurb: "Closes chats and keeps the screen on.",
                       openApps: [], quitApps: ["WhatsApp", "Telegram", "Messages"],
                       hideOthers: true, keepAwake: .display, tilingOn: false)
    ]
}
