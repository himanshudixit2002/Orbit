import Foundation

/// The things Orbit switches on and off.
public enum FeatureID: String, CaseIterable, Sendable, Codable, Identifiable {
    case tiling, glow, menuBar, capsLock, downloads, raycast, altTab, ice, syntaxHighlight, terminalLook

    public var id: String { rawValue }

    /// The features with an on/off switch (the rest are apps to open, or follow the theme).
    public static let switchable: [FeatureID] = [.tiling, .glow, .menuBar, .capsLock, .downloads]

    public var isSwitchable: Bool { Self.switchable.contains(self) }

    /// The feature mid-sentence, as the history says it: "Turned off the new menu bar".
    public var inSentence: String {
        switch self {
        case .tiling: "window tiling"
        case .glow: "the window glow"
        case .menuBar: "the new menu bar"
        case .capsLock: "Caps Lock superpowers"
        case .downloads: "Downloads sorting"
        default: title
        }
    }

    public var title: String {
        switch self {
        case .tiling: "Window tiling"
        case .glow: "Window glow"
        case .menuBar: "New menu bar"
        case .capsLock: "Caps Lock superpowers"
        case .downloads: "Auto-sort Downloads"
        case .raycast: "Raycast"
        case .altTab: "AltTab"
        case .ice: "Ice"
        case .syntaxHighlight: "Syntax Highlight"
        case .terminalLook: "Terminal colours"
        }
    }

    public var blurb: String {
        switch self {
        case .tiling: "Windows arrange themselves side by side."
        case .glow: "A soft outline on the window you're using."
        case .menuBar: "A sleek floating bar with live stats."
        case .capsLock: "Tap for Escape, hold + a letter to open an app."
        case .downloads: "Downloads tidy themselves every hour."
        case .raycast: "Find and open anything from the keyboard."
        case .altTab: "⌘Tab with live window previews."
        case .ice: "Tucks menu bar icons out of the way."
        case .syntaxHighlight: "Coloured previews of code files in Finder."
        case .terminalLook: "Matching colours in your terminal tools."
        }
    }

    public var shortTitle: String {
        switch self {
        case .tiling: "Tiling"
        case .glow: "Glow"
        case .menuBar: "Menu bar"
        case .capsLock: "Caps Lock"
        case .downloads: "Auto-sort"
        default: title
        }
    }

    public var symbol: String {
        switch self {
        case .tiling: "rectangle.split.3x1.fill"
        case .glow: "sparkles.rectangle.stack.fill"
        case .menuBar: "menubar.rectangle"
        case .capsLock: "capslock.fill"
        case .downloads: "arrow.down.doc.fill"
        case .raycast: "magnifyingglass"
        case .altTab: "rectangle.on.rectangle"
        case .ice: "menubar.dock.rectangle"
        case .syntaxHighlight: "chevron.left.forwardslash.chevron.right"
        case .terminalLook: "terminal.fill"
        }
    }
}

/// Permissions macOS asks the user to grant, named the way System Settings names them.
public enum PermissionKind: String, Sendable, Codable {
    case accessibility, backgroundItems, inputMonitoring, driverExtension, screenRecording,
         filesAndFolders, automation, firstOpen

    public var settingsName: String {
        switch self {
        case .accessibility: "Accessibility"
        case .backgroundItems: "Allow in the Background"
        case .inputMonitoring: "Input Monitoring"
        case .driverExtension: "Driver Extensions"
        case .screenRecording: "Screen & System Audio Recording"
        case .filesAndFolders: "Files & Folders"
        case .automation: "Automation"
        case .firstOpen: "Open once"
        }
    }
}

/// What a feature's status pill shows.
public enum FeatureState: Sendable, Equatable {
    case unknown
    case notInstalled
    case off
    case on
    case working(String)
    case needsPermission(PermissionKind, String)
    case blocked(String)

    public var isOn: Bool { if case .on = self { true } else { false } }

    public var needsAttention: Bool {
        switch self {
        case .needsPermission, .blocked: true
        default: false
        }
    }

    public var label: String {
        switch self {
        case .unknown: "Checking…"
        case .notInstalled: "Not installed"
        case .off: "Off"
        case .on: "On"
        case .working(let what): what
        case .needsPermission: "Needs your OK"
        case .blocked: "Can't run"
        }
    }

    /// One plain-English sentence explaining a problem, if there is one.
    public var detail: String? {
        switch self {
        case .needsPermission(_, let text), .blocked(let text): text
        default: nil
        }
    }
}

/// Why a background helper isn't running, worked out from its own messages.
public enum HelperProblem: Sendable, Equatable {
    case needsAccessibility
    case notAllowedInBackground
    case secureInput(app: String?)
    case separateSpacesOff
    case duplicate
    case crashed(String)

    public var state: FeatureState {
        switch self {
        case .needsAccessibility:
            .needsPermission(.accessibility, "macOS needs you to switch it on under Privacy & Security → Accessibility.")
        case .notAllowedInBackground:
            .needsPermission(.backgroundItems, "It's switched off under Login Items → Allow in the Background.")
        case .secureInput(let app):
            .blocked("\(app ?? "Another app") has Secure Keyboard Entry on, which blocks keyboard shortcuts. Quit it or turn that off.")
        case .separateSpacesOff:
            .blocked("Turn on \"Displays have separate Spaces\" in Desktop & Dock settings, then log out and back in.")
        case .duplicate:
            .blocked("Two copies are trying to run. Orbit can tidy this up.")
        case .crashed(let detail):
            .blocked(detail)
        }
    }
}

/// One background helper as launchd reports it.
public enum HelperRun: Sendable, Equatable {
    case notLoaded
    case loaded(running: Bool, pid: Int?, lastExit: Int?)

    public var isRunning: Bool {
        if case .loaded(true, _, _) = self { true } else { false }
    }

    public var isLoaded: Bool {
        if case .loaded = self { true } else { false }
    }

    /// The process id while it runs.
    public var pid: Int? {
        if case .loaded(true, let pid, _) = self { pid } else { nil }
    }
}
