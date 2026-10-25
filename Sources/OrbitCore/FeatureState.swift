import Foundation

/// The things Orbit switches on and off.
public enum FeatureID: String, CaseIterable, Sendable, Codable, Identifiable {
    case tiling, glow, menuBar, capsLock, downloads, raycast, altTab, ice, syntaxHighlight, terminalLook

    public var id: String { rawValue }
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
