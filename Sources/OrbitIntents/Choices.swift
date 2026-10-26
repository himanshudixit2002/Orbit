import AppIntents
import OrbitCore
import OrbitShared

// What Orbit's actions can be pointed at. Built into both the app and the widget extension; the names
// are written out here (not borrowed from OrbitCore) because Xcode reads them while building.

/// The features with an on/off switch.
enum FeatureChoice: String, AppEnum {
    case tiling, glow, menuBar, capsLock, downloads

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Orbit Feature"
    static let caseDisplayRepresentations: [FeatureChoice: DisplayRepresentation] = [
        .tiling: DisplayRepresentation(title: "Window tiling", image: .init(systemName: "rectangle.split.3x1.fill")),
        .glow: DisplayRepresentation(title: "Window glow", image: .init(systemName: "sparkles.rectangle.stack.fill")),
        .menuBar: DisplayRepresentation(title: "New menu bar", image: .init(systemName: "menubar.rectangle")),
        .capsLock: DisplayRepresentation(title: "Caps Lock superpowers", image: .init(systemName: "capslock.fill")),
        .downloads: DisplayRepresentation(title: "Auto-sort Downloads", image: .init(systemName: "arrow.down.doc.fill"))
    ]

    var feature: FeatureID { FeatureID(rawValue: rawValue) ?? .tiling }
}

enum ThemeChoice: String, AppEnum {
    case tokyoNight, catppuccin, dracula, nord, rosePine, sunset

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Orbit Theme"
    static let caseDisplayRepresentations: [ThemeChoice: DisplayRepresentation] = [
        .tokyoNight: DisplayRepresentation(title: "Tokyo Night", image: .init(systemName: "moon.stars.fill")),
        .catppuccin: DisplayRepresentation(title: "Catppuccin Mocha", image: .init(systemName: "cup.and.saucer.fill")),
        .dracula: DisplayRepresentation(title: "Dracula", image: .init(systemName: "bolt.heart.fill")),
        .nord: DisplayRepresentation(title: "Nord", image: .init(systemName: "snowflake")),
        .rosePine: DisplayRepresentation(title: "Rosé Pine", image: .init(systemName: "leaf.fill")),
        .sunset: DisplayRepresentation(title: "Sunset", image: .init(systemName: "sun.horizon.fill"))
    ]

    var theme: ThemeID { ThemeID(rawValue: rawValue) ?? .tokyoNight }
}

enum PageChoice: String, AppEnum {
    case home, style, windows, menuBar, keyboard, files, modes, shortcuts, developer, monitor, speed, cleanup, dockFinder, apps, health

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Orbit Page"
    static let caseDisplayRepresentations: [PageChoice: DisplayRepresentation] = [
        .home: DisplayRepresentation(title: "Home", image: .init(systemName: "house.fill")),
        .style: DisplayRepresentation(title: "Style", image: .init(systemName: "paintpalette.fill")),
        .windows: DisplayRepresentation(title: "Windows", image: .init(systemName: "rectangle.split.3x1.fill")),
        .menuBar: DisplayRepresentation(title: "Menu Bar", image: .init(systemName: "menubar.rectangle")),
        .keyboard: DisplayRepresentation(title: "Keyboard", image: .init(systemName: "keyboard.fill")),
        .files: DisplayRepresentation(title: "Files", image: .init(systemName: "folder.fill")),
        .modes: DisplayRepresentation(title: "Modes", image: .init(systemName: "moon.stars.fill")),
        .shortcuts: DisplayRepresentation(title: "Shortcuts", image: .init(systemName: "command.square.fill")),
        .developer: DisplayRepresentation(title: "Developer", image: .init(systemName: "hammer.fill")),
        .monitor: DisplayRepresentation(title: "Monitor", image: .init(systemName: "waveform.path.ecg")),
        .speed: DisplayRepresentation(title: "Speed", image: .init(systemName: "bolt.fill")),
        .cleanup: DisplayRepresentation(title: "Cleanup", image: .init(systemName: "sparkles")),
        .dockFinder: DisplayRepresentation(title: "Dock & Finder", image: .init(systemName: "dock.rectangle")),
        .apps: DisplayRepresentation(title: "Apps", image: .init(systemName: "square.grid.2x2.fill")),
        .health: DisplayRepresentation(title: "Health & Undo", image: .init(systemName: "heart.text.square.fill"))
    ]

    var page: Page { Page(rawValue: rawValue) ?? .home }
}

/// One of the user's modes (they can make their own, so these come from Orbit's snapshot).
struct ModeEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Orbit Mode"
    static let defaultQuery = ModeQuery()

    let id: String
    let name: String
    let symbol: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", image: .init(systemName: symbol))
    }
}

struct ModeQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [ModeEntity] {
        Self.all().filter { identifiers.contains($0.id) }
    }

    func suggestedEntities() async throws -> [ModeEntity] { Self.all() }

    /// The modes in Orbit's snapshot, or the built-in four before there is one.
    static func all() -> [ModeEntity] {
        let modes = SharedStore.forThisApp.load()?.modes
            ?? ModeDefinition.defaults.map { OrbitSnapshot.Mode(id: $0.id, name: $0.name, symbol: $0.symbol) }
        return modes.map { ModeEntity(id: $0.id, name: $0.name, symbol: $0.symbol) }
    }
}

/// A command that didn't work: Shortcuts shows the reason and stops there.
struct OrbitIntentError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

extension OrbitReply {
    /// The reply as an action's result: its message, or an error when it didn't work.
    func checked() throws -> String {
        guard ok else { throw OrbitIntentError(message: message) }
        return message
    }
}
