import Foundation

/// The pages of Orbit's window, also named by links (orbit://page/monitor), Shortcuts and search.
public enum Page: String, CaseIterable, Identifiable, Hashable, Codable, Sendable {
    case home, style, windows, menuBar, keyboard, files, modes, shortcuts, monitor, cleanup, dockFinder, apps, health

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
        case .monitor: "Monitor"
        case .cleanup: "Cleanup"
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
        case .monitor: "waveform.path.ecg"
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
        case .monitor: "What your Mac is busy with, live."
        case .cleanup: "See what's taking up space and clear it safely."
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
        case .monitor, .cleanup, .dockFinder, .apps: "System"
        case .health: "Care"
        }
    }
}
