import Foundation

/// Everything Orbit can be asked to do from outside its window: links, Shortcuts and Siri, widgets,
/// Control Center, the ⌘K palette and the global hotkey. One vocabulary, run by one dispatcher.
public enum OrbitCommand: Codable, Sendable, Hashable {
    case setFeature(FeatureID, on: Bool)
    case toggleFeature(FeatureID)
    case setTheme(ThemeID)
    case startMode(String)
    case stopMode
    case toggleMode(String)
    case sortDownloads
    /// A fresh, thorough check of everything.
    case checkStatus
    case open(OrbitDestination)

    /// What it does, mid-sentence: "turn off window tiling".
    public var summary: String {
        switch self {
        case .setFeature(let id, let on): "turn \(on ? "on" : "off") \(id.inSentence)"
        case .toggleFeature(let id): "switch \(id.inSentence) on or off"
        case .setTheme(let theme): "switch to the \(Palette.named(theme).name) theme"
        case .startMode(let id): "start the \(id) mode"
        case .toggleMode(let id): "switch the \(id) mode on or off"
        case .stopMode: "stop the mode that's on"
        case .sortDownloads: "sort your Downloads folder"
        case .checkStatus: "check everything"
        case .open(let destination):
            switch destination {
            case .page(let page): "open \(page.title)"
            case .setup: "open the guided setup"
            case .panel: "open the quick panel"
            case .palette: "open the command palette"
            }
        }
    }

    /// Only showing something brings Orbit to the front; changes happen where the user already is.
    public var showsOrbit: Bool {
        if case .open = self { true } else { false }
    }
}

/// Somewhere in Orbit to show.
public enum OrbitDestination: Codable, Sendable, Hashable {
    case page(Page)
    case setup
    case panel
    case palette
}

/// Where a command came from. Anything but Orbit's own window runs without asking: it never opens
/// System Settings or a sheet by itself, and says what's needed instead.
public enum CommandSource: String, Codable, Sendable {
    case window, panel, link, shortcut, widget, control, hotkey, palette, focus, schedule

    public var isBackground: Bool {
        switch self {
        case .window, .panel, .palette: false
        case .link, .shortcut, .widget, .control, .hotkey, .focus, .schedule: true
        }
    }
}

/// What a command did, in a sentence fit for Siri or a notification.
public struct OrbitReply: Sendable, Equatable {
    public var ok: Bool
    public var message: String

    public init(ok: Bool, message: String) {
        self.ok = ok
        self.message = message
    }
}

/// orbit:// links, both ways. Only this short list is understood: a link can show Orbit, switch a
/// feature, a theme or a mode, sort Downloads or check status, all of them easy to undo. Nothing
/// that clears, restores or undoes can be started by a link.
///
///     orbit://page/monitor   orbit://setup   orbit://panel   orbit://palette
///     orbit://toggle/tiling   orbit://on/glow   orbit://off/menuBar
///     orbit://theme/nord   orbit://mode/focus   orbit://mode/stop   orbit://sort-downloads   orbit://check
public enum OrbitLink {
    public static let schemes: Set<String> = ["orbit", "orbitdev"]

    public static func command(from url: URL) -> OrbitCommand? {
        guard let scheme = url.scheme?.lowercased(), schemes.contains(scheme), let host = url.host()?.lowercased() else { return nil }
        let argument = url.pathComponents.dropFirst().first
        switch host {
        case "page": return argument.flatMap(Page.init(rawValue:)).map { .open(.page($0)) }
        case "setup": return .open(.setup)
        case "panel": return .open(.panel)
        case "palette": return .open(.palette)
        case "toggle": return switchable(argument).map { .toggleFeature($0) }
        case "on": return switchable(argument).map { .setFeature($0, on: true) }
        case "off": return switchable(argument).map { .setFeature($0, on: false) }
        case "theme": return argument.flatMap(ThemeID.init(rawValue:)).map { .setTheme($0) }
        case "mode":
            guard let argument, !argument.isEmpty else { return nil }
            return argument == "stop" ? .stopMode : .toggleMode(argument)
        case "sort-downloads": return .sortDownloads
        case "check": return .checkStatus
        default: return nil
        }
    }

    /// The token a link carries (see `StateStore.linkToken`).
    public static func token(in url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "token" }?.value
    }

    /// The link that does `command`, when there is one. Links that change things carry `token`.
    public static func url(for command: OrbitCommand, scheme: String = "orbit", token: String? = nil) -> URL? {
        let path: String? = switch command {
        case .open(.page(let page)): "page/\(page.rawValue)"
        case .open(.setup): "setup"
        case .open(.panel): "panel"
        case .open(.palette): "palette"
        case .toggleFeature(let feature): feature.isSwitchable ? "toggle/\(feature.rawValue)" : nil
        case .setFeature(let feature, let on): feature.isSwitchable ? "\(on ? "on" : "off")/\(feature.rawValue)" : nil
        case .setTheme(let theme): "theme/\(theme.rawValue)"
        case .toggleMode(let id), .startMode(let id): id == "stop" ? nil : "mode/\(id)"
        case .stopMode: "mode/stop"
        case .sortDownloads: "sort-downloads"
        case .checkStatus: "check"
        }
        let query = token.map { command.showsOrbit ? "" : "?token=\($0)" } ?? ""
        return path.flatMap { URL(string: "\(scheme)://\($0)\(query)") }
    }

    private static func switchable(_ name: String?) -> FeatureID? {
        // Links are typed by hand: "menubar" and "menuBar" are the same feature.
        guard let name else { return nil }
        return FeatureID.switchable.first { $0.rawValue.lowercased() == name.lowercased() }
    }
}
