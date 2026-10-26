import Foundation

/// One item in the Dock, as stored in the Dock's `persistent-apps` preference: usually an app.
public struct DockTile: Sendable, Identifiable, Equatable, Hashable {
    public let id: String
    /// The app's path; empty for a spacer or anything else that isn't an app.
    public let path: String
    public let label: String
    /// The Dock's own entry, kept as-is so nothing it stores is lost.
    public let raw: PrefValue?

    public var isApp: Bool { !path.isEmpty }

    public init(path: String, label: String, raw: PrefValue? = nil) {
        self.id = path
        self.path = path
        self.label = label
        self.raw = raw
    }

    /// A spacer, or anything else Orbit doesn't recognise, carried along untouched.
    public init(other raw: PrefValue, label: String, position: Int) {
        self.id = "\(label) \(position)"
        self.path = ""
        self.label = label
        self.raw = raw
    }

    public static func == (a: DockTile, b: DockTile) -> Bool { a.id == b.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

public enum DockModel {
    public static func tiles(_ persistentApps: PrefValue?) -> [DockTile] {
        guard case .array(let items) = persistentApps else { return [] }
        return items.enumerated().map { index, item in
            guard case .dict(let entry) = item,
                  case .dict(let tileData)? = entry["tile-data"],
                  case .dict(let fileData)? = tileData["file-data"],
                  case .string(let urlString)? = fileData["_CFURLString"] else {
                // Spacers have no app behind them; they stay exactly where they are.
                let kind: String? = if case .dict(let entry) = item, case .string(let type)? = entry["tile-type"] { type } else { nil }
                let label = switch kind {
                case "spacer-tile": "Space"
                case "small-spacer-tile": "Small space"
                case "flex-spacer-tile": "Flexible space"
                default: "Other item"
                }
                return DockTile(other: item, label: label, position: index)
            }
            let path = URL(string: urlString)?.path(percentEncoded: false) ?? urlString
            let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
            var label = URL(fileURLWithPath: trimmed).deletingPathExtension().lastPathComponent
            if case .string(let name)? = tileData["file-label"] { label = name }
            return DockTile(path: trimmed, label: label, raw: item)
        }
    }

    /// A new Dock entry for the app at `path`.
    public static func entry(path: String, label: String) -> PrefValue {
        let url = URL(fileURLWithPath: path, isDirectory: true).absoluteString
        return .dict([
            "tile-data": .dict([
                "file-data": .dict(["_CFURLString": .string(url), "_CFURLStringType": .int(15)]),
                "file-label": .string(label)
            ]),
            "tile-type": .string("file-tile")
        ])
    }

    public static func persistentApps(_ tiles: [DockTile]) -> PrefValue {
        .array(tiles.map { $0.raw ?? entry(path: $0.path, label: $0.label) })
    }
}

/// Places in System Settings Orbit sends people to.
public enum SettingsPane: String, Sendable, CaseIterable {
    case accessibility, inputMonitoring, screenRecording, filesAndFolders, automation, loginItems, desktopAndDock,
         wallpaper, keyboard, privacy, siri, spotlight, display, fullDiskAccess

    public var title: String {
        switch self {
        case .accessibility: "Accessibility settings"
        case .inputMonitoring: "Input Monitoring settings"
        case .screenRecording: "Screen Recording settings"
        case .filesAndFolders: "Files and Folders settings"
        case .automation: "Automation settings"
        case .loginItems: "Login Items"
        case .desktopAndDock: "Desktop & Dock settings"
        case .wallpaper: "Wallpaper settings"
        case .keyboard: "Keyboard settings"
        case .privacy: "Privacy settings"
        case .siri: "Siri settings"
        case .spotlight: "Spotlight settings"
        case .display: "Display settings"
        case .fullDiskAccess: "Full Disk Access settings"
        }
    }

    public var url: String {
        let privacy = "x-apple.systempreferences:com.apple.preference.security?"
        switch self {
        case .accessibility: return privacy + "Privacy_Accessibility"
        case .inputMonitoring: return privacy + "Privacy_ListenEvent"
        case .screenRecording: return privacy + "Privacy_ScreenCapture"
        case .filesAndFolders: return privacy + "Privacy_FilesAndFolders"
        case .automation: return privacy + "Privacy_Automation"
        case .fullDiskAccess: return privacy + "Privacy_AllFiles"
        case .privacy: return "x-apple.systempreferences:com.apple.preference.security"
        case .loginItems: return "x-apple.systempreferences:com.apple.LoginItems-Settings.extension"
        case .desktopAndDock: return "x-apple.systempreferences:com.apple.Desktop-Settings.extension"
        case .wallpaper: return "x-apple.systempreferences:com.apple.Wallpaper-Settings.extension"
        case .keyboard: return "x-apple.systempreferences:com.apple.Keyboard-Settings.extension"
        case .siri: return "x-apple.systempreferences:com.apple.Siri-Settings.extension"
        case .spotlight: return "x-apple.systempreferences:com.apple.Spotlight-Settings.extension"
        case .display: return "x-apple.systempreferences:com.apple.Accessibility-Settings.extension?Display"
        }
    }

    public static func `for`(_ permission: PermissionKind) -> SettingsPane {
        switch permission {
        case .accessibility: .accessibility
        case .backgroundItems, .driverExtension: .loginItems
        case .inputMonitoring: .inputMonitoring
        case .screenRecording: .screenRecording
        case .filesAndFolders: .filesAndFolders
        case .automation: .automation
        case .firstOpen: .privacy
        }
    }
}
