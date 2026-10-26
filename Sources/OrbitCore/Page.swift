import Foundation

/// The pages of Orbit's window, also named by links (orbit://page/monitor), Shortcuts and search.
public enum Page: String, CaseIterable, Identifiable, Hashable, Codable, Sendable {
    case home, style, windows, menuBar, keyboard, files, modes, shortcuts, developer, monitor, speed, cleanup, dockFinder, apps, health

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .home: "Home"
        case .style: "Style"
        case .windows: "Windows"
        case .menuBar: "Menu Bar"
        case .keyboard: "Keyboard"
        case .files: "Files"
        case .modes: "Modes"
        case .shortcuts: "Shortcuts"
        case .developer: "Developer"
        case .monitor: "Monitor"
        case .speed: "Speed"
        case .cleanup: "Storage"
        case .dockFinder: "Dock & Finder"
        case .apps: "Apps"
        case .health: "Health & Undo"
        }
    }

    public var symbol: String {
        switch self {
        case .home: "house.fill"
        case .style: "paintpalette.fill"
        case .windows: "rectangle.split.3x1.fill"
        case .menuBar: "menubar.rectangle"
        case .keyboard: "keyboard.fill"
        case .files: "folder.fill"
        case .modes: "moon.stars.fill"
        case .shortcuts: "command.square.fill"
        case .developer: "hammer.fill"
        case .monitor: "waveform.path.ecg"
        case .speed: "bolt.fill"
        case .cleanup: "sparkles"
        case .dockFinder: "dock.rectangle"
        case .apps: "square.grid.2x2.fill"
        case .health: "heart.text.square.fill"
        }
    }

    public var blurb: String {
        switch self {
        case .home: "Here's your Mac at a glance."
        case .style: "Give the whole Mac one look in a single click."
        case .windows: "Windows that arrange themselves, with a glow on the one you're using."
        case .menuBar: "A sleek floating menu bar with the things you care about."
        case .keyboard: "Caps Lock superpowers and every shortcut in one place."
        case .files: "Downloads that tidy themselves, and where your things live."
        case .modes: "Set up the Mac for what you're doing, in one click."
        case .shortcuts: "Reach Orbit from anywhere: a hotkey, Siri, widgets, Control Center and links."
        case .developer: "Your projects, the services they need, and what's listening."
        case .monitor: "What your Mac is busy with, live."
        case .speed: "Take the waiting out of the Mac, and keep it quick."
        case .cleanup: "See where your space goes, and free it up safely."
        case .dockFinder: "A tidy Dock and a smarter Finder."
        case .apps: "Handy helper apps, and the permissions they need."
        case .health: "Check everything is working, and undo any change."
        }
    }

    public var group: String {
        switch self {
        case .home: ""
        case .style: "Look"
        case .windows, .menuBar, .keyboard, .files, .modes, .shortcuts: "Control"
        case .developer, .monitor, .speed, .cleanup, .dockFinder, .apps: "System"
        case .health: "Care"
        }
    }
}
