import AppIntents
import OrbitCore
import OrbitShared

// Orbit's actions for Shortcuts, Siri, Spotlight, Focus, widgets and Control Center. Every one runs in
// the Orbit app itself (it starts in the background if it isn't running), through the same path as the
// window's switches: one change at a time, each in the history with Undo.

struct ToggleFeatureIntent: AppIntent {
    static let title: LocalizedStringResource = "Toggle Orbit Feature"
    static let description: IntentDescription? = "Turns window tiling, the window glow, the new menu bar, Caps Lock superpowers or Downloads sorting on or off."
    static let supportedModes: IntentModes = .background
    static let allowedExecutionTargets: IntentExecutionTargets = .main

    @Parameter(title: "Feature") var feature: FeatureChoice

    init() {}
    init(_ feature: FeatureChoice) { self.feature = feature }

    static var parameterSummary: some ParameterSummary { Summary("Toggle \(\.$feature)") }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let reply = await OrbitBridge.run(.toggleFeature(feature.feature), source: .shortcut)
        return .result(dialog: "\(try reply.checked())")
    }
}

struct SetFeatureIntent: AppIntent {
    static let title: LocalizedStringResource = "Turn Orbit Feature On or Off"
    static let description: IntentDescription? = "Switches one of Orbit's features on or off."
    static let supportedModes: IntentModes = .background
    static let allowedExecutionTargets: IntentExecutionTargets = .main

    @Parameter(title: "Feature") var feature: FeatureChoice
    @Parameter(title: "On", default: true) var on: Bool

    static var parameterSummary: some ParameterSummary { Summary("Turn \(\.$feature) \(\.$on)") }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let reply = await OrbitBridge.run(.setFeature(feature.feature, on: on), source: .shortcut)
        return .result(dialog: "\(try reply.checked())")
    }
}

/// A feature's Control Center switch.
struct FeatureSwitchIntent: SetValueIntent {
    static let title: LocalizedStringResource = "Orbit Feature Switch"
    static let isDiscoverable = false
    static let supportedModes: IntentModes = .background
    static let allowedExecutionTargets: IntentExecutionTargets = .main

    @Parameter(title: "Feature") var feature: FeatureChoice
    @Parameter(title: "On") var value: Bool

    init() {}
    init(_ feature: FeatureChoice) { self.feature = feature }

    func perform() async throws -> some IntentResult {
        _ = try await OrbitBridge.run(.setFeature(feature.feature, on: value), source: .control).checked()
        return .result()
    }
}

struct SetThemeIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Orbit Theme"
    static let description: IntentDescription? = "Gives the whole Mac one of Orbit's colour themes."
    static let supportedModes: IntentModes = .background
    static let allowedExecutionTargets: IntentExecutionTargets = .main

    @Parameter(title: "Theme") var theme: ThemeChoice

    static var parameterSummary: some ParameterSummary { Summary("Switch to the \(\.$theme) theme") }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let reply = await OrbitBridge.run(.setTheme(theme.theme), source: .shortcut)
        return .result(dialog: "\(try reply.checked())")
    }
}

struct ToggleModeIntent: AppIntent {
    static let title: LocalizedStringResource = "Toggle Orbit Mode"
    static let description: IntentDescription? = "Switches one of your Orbit modes on, or off if it's on."
    static let supportedModes: IntentModes = .background
    static let allowedExecutionTargets: IntentExecutionTargets = .main

    @Parameter(title: "Mode") var mode: ModeEntity

    init() {}
    init(_ mode: ModeEntity) { self.mode = mode }

    static var parameterSummary: some ParameterSummary { Summary("Toggle \(\.$mode) mode") }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let reply = await OrbitBridge.run(.toggleMode(mode.id), source: .shortcut)
        return .result(dialog: "\(try reply.checked())")
    }
}

struct StartModeIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Orbit Mode"
    static let description: IntentDescription? = "Switches one of your Orbit modes on (and the one that was on, off)."
    static let supportedModes: IntentModes = .background
    static let allowedExecutionTargets: IntentExecutionTargets = .main

    @Parameter(title: "Mode") var mode: ModeEntity

    static var parameterSummary: some ParameterSummary { Summary("Start \(\.$mode) mode") }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let reply = await OrbitBridge.run(.startMode(mode.id), source: .shortcut)
        return .result(dialog: "\(try reply.checked())")
    }
}

struct StopModeIntent: AppIntent {
    static let title: LocalizedStringResource = "Stop Orbit Mode"
    static let description: IntentDescription? = "Switches off the Orbit mode that's on, putting back what it changed."
    static let supportedModes: IntentModes = .background
    static let allowedExecutionTargets: IntentExecutionTargets = .main

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let reply = await OrbitBridge.run(.stopMode, source: .shortcut)
        return .result(dialog: "\(try reply.checked())")
    }
}

struct SortDownloadsIntent: AppIntent {
    static let title: LocalizedStringResource = "Sort Downloads"
    static let description: IntentDescription? = "Sorts the Downloads folder into its folders now."
    static let supportedModes: IntentModes = .background
    static let allowedExecutionTargets: IntentExecutionTargets = .main

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let reply = await OrbitBridge.run(.sortDownloads, source: .shortcut)
        return .result(dialog: "\(try reply.checked())")
    }
}

struct CheckStatusIntent: AppIntent {
    static let title: LocalizedStringResource = "Check Orbit Status"
    static let description: IntentDescription? = "Checks everything Orbit looks after and says what needs attention."
    static let supportedModes: IntentModes = .background
    static let allowedExecutionTargets: IntentExecutionTargets = .main

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let reply = await OrbitBridge.run(.checkStatus, source: .shortcut)
        return .result(value: reply.message, dialog: "\(reply.message)")
    }
}

struct OpenPageIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Orbit Page"
    static let description: IntentDescription? = "Opens Orbit on one of its pages."
    static let supportedModes: IntentModes = .foreground(.immediate)
    static let allowedExecutionTargets: IntentExecutionTargets = .main

    @Parameter(title: "Page") var page: PageChoice

    static var parameterSummary: some ParameterSummary { Summary("Open \(\.$page) in Orbit") }

    func perform() async throws -> some IntentResult {
        _ = await OrbitBridge.run(.open(.page(page.page)), source: .shortcut)
        return .result()
    }
}

/// Focus filter: a Focus can switch an Orbit mode on while it's on. When the Focus ends, only the mode
/// it started is switched off.
struct OrbitFocusFilter: SetFocusFilterIntent {
    static let title: LocalizedStringResource = "Set Orbit Mode"
    static let description: IntentDescription? = "Switches an Orbit mode on while this Focus is on."
    static let allowedExecutionTargets: IntentExecutionTargets = .main

    @Parameter(title: "Mode") var mode: ModeEntity?

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: mode.map { "\($0.name) mode" } ?? "No Orbit mode")
    }

    func perform() async throws -> some IntentResult {
        await OrbitBridge.focusChanged(to: mode?.id)
        return .result()
    }
}

/// A mode's Control Center switch.
struct ModeSwitchIntent: SetValueIntent {
    static let title: LocalizedStringResource = "Orbit Mode Switch"
    static let isDiscoverable = false
    static let supportedModes: IntentModes = .background
    static let allowedExecutionTargets: IntentExecutionTargets = .main

    @Parameter(title: "Mode") var mode: ModeEntity
    @Parameter(title: "On") var value: Bool

    init() {}
    init(_ mode: ModeEntity) { self.mode = mode }

    func perform() async throws -> some IntentResult {
        _ = try await OrbitBridge.run(value ? .startMode(mode.id) : .stopMode, source: .control).checked()
        return .result()
    }
}

/// Which mode a mode switch in Control Center is for.
struct ModeControlConfiguration: ControlConfigurationIntent {
    static let title: LocalizedStringResource = "Orbit Mode"
    static let isDiscoverable = false

    @Parameter(title: "Mode") var mode: ModeEntity?
}
