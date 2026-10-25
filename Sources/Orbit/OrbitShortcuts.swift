import AppIntents

/// The phrases that work with Siri and Spotlight straight away, without making a shortcut first.
struct OrbitShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: ToggleFeatureIntent(), phrases: [
            "Toggle \(\.$feature) in \(.applicationName)",
            "Switch \(\.$feature) with \(.applicationName)"
        ], shortTitle: "Toggle a Feature", systemImageName: "switch.2")
        AppShortcut(intent: ToggleModeIntent(), phrases: [
            "Toggle \(\.$mode) mode in \(.applicationName)",
            "Start \(\.$mode) mode with \(.applicationName)"
        ], shortTitle: "Toggle a Mode", systemImageName: "moon.stars.fill")
        AppShortcut(intent: StopModeIntent(), phrases: [
            "Stop the mode in \(.applicationName)",
            "End my \(.applicationName) mode"
        ], shortTitle: "Stop the Mode", systemImageName: "stop.circle")
        AppShortcut(intent: SetThemeIntent(), phrases: [
            "Switch \(.applicationName) to \(\.$theme)",
            "Use the \(\.$theme) theme in \(.applicationName)"
        ], shortTitle: "Set the Theme", systemImageName: "paintpalette.fill")
        AppShortcut(intent: SortDownloadsIntent(), phrases: [
            "Sort my Downloads with \(.applicationName)",
            "Tidy Downloads with \(.applicationName)"
        ], shortTitle: "Sort Downloads", systemImageName: "arrow.down.doc.fill")
        AppShortcut(intent: CheckStatusIntent(), phrases: [
            "Check my Mac with \(.applicationName)",
            "Ask \(.applicationName) how my Mac is"
        ], shortTitle: "Check Status", systemImageName: "heart.text.square.fill")
        AppShortcut(intent: OpenPageIntent(), phrases: [
            "Open \(\.$page) in \(.applicationName)",
            "Show \(.applicationName) \(\.$page)"
        ], shortTitle: "Open a Page", systemImageName: "macwindow")
    }
}
