import AppIntents
import OrbitCore
import OrbitShared
import SwiftUI
import WidgetKit

// Control Center (and menu bar) switches. Each one's action runs in Orbit; its state comes from
// Orbit's snapshot, which Orbit refreshes (and reloads the controls) whenever something changes.

struct FeatureValue: ControlValueProvider {
    let feature: FeatureID
    var previewValue: Bool { true }

    func currentValue() async throws -> Bool {
        SharedStore.forThisApp.load()?.feature(feature)?.state == .on
    }
}

struct TilingControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.himanshudixit.orbit.control.tiling", provider: FeatureValue(feature: .tiling)) { on in
            ControlWidgetToggle("Window Tiling", isOn: on, action: FeatureSwitchIntent(.tiling)) { on in
                Label(on ? "On" : "Off", systemImage: "rectangle.split.3x1.fill")
            }
        }
        .displayName("Window Tiling")
        .description("Windows arrange themselves side by side.")
    }
}

struct GlowControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.himanshudixit.orbit.control.glow", provider: FeatureValue(feature: .glow)) { on in
            ControlWidgetToggle("Window Glow", isOn: on, action: FeatureSwitchIntent(.glow)) { on in
                Label(on ? "On" : "Off", systemImage: "sparkles.rectangle.stack.fill")
            }
        }
        .displayName("Window Glow")
        .description("A soft outline on the window you're using.")
    }
}

struct MenuBarControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.himanshudixit.orbit.control.menuBar", provider: FeatureValue(feature: .menuBar)) { on in
            ControlWidgetToggle("New Menu Bar", isOn: on, action: FeatureSwitchIntent(.menuBar)) { on in
                Label(on ? "On" : "Off", systemImage: "menubar.rectangle")
            }
        }
        .displayName("New Menu Bar")
        .description("The floating menu bar with live stats.")
    }
}

struct CapsLockControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.himanshudixit.orbit.control.capsLock", provider: FeatureValue(feature: .capsLock)) { on in
            ControlWidgetToggle("Caps Lock Superpowers", isOn: on, action: FeatureSwitchIntent(.capsLock)) { on in
                Label(on ? "On" : "Off", systemImage: "capslock.fill")
            }
        }
        .displayName("Caps Lock Superpowers")
        .description("Tap for Escape, hold with a letter to open an app.")
    }
}

struct SortDownloadsControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.himanshudixit.orbit.control.sort") {
            ControlWidgetButton(action: SortDownloadsIntent()) {
                Label("Sort Downloads", systemImage: "arrow.down.doc.fill")
            }
        }
        .displayName("Sort Downloads")
        .description("Sorts the Downloads folder now.")
    }
}

/// A switch for one mode, chosen when adding it to Control Center.
struct ModeControl: ControlWidget {
    struct Value: Sendable {
        var mode: ModeEntity
        var isOn: Bool
    }

    struct Provider: AppIntentControlValueProvider {
        func previewValue(configuration: ModeControlConfiguration) -> Value {
            Value(mode: configuration.mode ?? Self.fallback, isOn: false)
        }

        func currentValue(configuration: ModeControlConfiguration) async throws -> Value {
            let mode = configuration.mode ?? Self.fallback
            return Value(mode: mode, isOn: SharedStore.forThisApp.load()?.activeMode == mode.id)
        }

        static var fallback: ModeEntity { ModeQuery.all().first ?? ModeEntity(id: "focus", name: "Focus", symbol: "scope") }
    }

    var body: some ControlWidgetConfiguration {
        AppIntentControlConfiguration(kind: "com.himanshudixit.orbit.control.mode", provider: Provider()) { value in
            ControlWidgetToggle("\(value.mode.name) Mode", isOn: value.isOn, action: ModeSwitchIntent(value.mode)) { on in
                Label(on ? "On" : "Off", systemImage: value.mode.symbol)
            }
        }
        .displayName("Orbit Mode")
        .description("Switches one of your modes on or off.")
        .promptsForUserConfiguration()
    }
}
