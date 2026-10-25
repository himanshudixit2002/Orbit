import OrbitCore
import OrbitShared
import SwiftUI
import WidgetKit

/// What every widget shows: Orbit's latest snapshot, or that Orbit isn't running.
struct OrbitEntry: TimelineEntry {
    let date: Date
    let snapshot: OrbitSnapshot?

    var live: Bool { snapshot?.isLive(now: date) == true }
    var palette: Palette { Palette.named(snapshot?.theme ?? .tokyoNight) }
}

struct OrbitProvider: TimelineProvider {
    func placeholder(in context: Context) -> OrbitEntry { OrbitEntry(date: Date(), snapshot: .preview) }

    func getSnapshot(in context: Context, completion: @escaping (OrbitEntry) -> Void) {
        completion(OrbitEntry(date: Date(), snapshot: context.isPreview ? .preview : SharedStore.forThisApp.load() ?? .preview))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<OrbitEntry>) -> Void) {
        let now = Date()
        // Orbit reloads the widgets whenever something changes; the half-hourly look only notices that
        // Orbit has stopped.
        completion(Timeline(entries: [OrbitEntry(date: now, snapshot: SharedStore.forThisApp.load())],
                            policy: .after(now.addingTimeInterval(30 * 60))))
    }
}

extension OrbitSnapshot {
    static let preview = OrbitSnapshot(
        features: FeatureID.allCases.map { Feature(id: $0, state: $0 == .downloads ? .attention : $0 == .ice ? .off : .on) },
        modes: ModeDefinition.defaults.map { Mode(id: $0.id, name: $0.name, symbol: $0.symbol) },
        activeMode: "focus")
}

extension Color {
    init(_ rgb: RGB, opacity: Double = 1) {
        self.init(.sRGB, red: rgb.red, green: rgb.green, blue: rgb.blue, opacity: opacity)
    }
}

extension OrbitSnapshot.State {
    var color: Color {
        switch self {
        case .on: .green
        case .attention: .orange
        case .off, .notInstalled: .secondary
        case .checking: .blue
        }
    }

    var label: String {
        switch self {
        case .on: "On"
        case .off: "Off"
        case .attention: "Needs you"
        case .notInstalled: "Not installed"
        case .checking: "Checking"
        }
    }
}

/// Links back into this copy of Orbit (Orbit Dev answers to orbitdev://).
enum OrbitLinks {
    static var scheme: String { Bundle.main.bundleIdentifier?.contains(".orbit.dev") == true ? "orbitdev" : "orbit" }

    static func url(_ command: OrbitCommand) -> URL? { OrbitLink.url(for: command, scheme: scheme) }
}

/// Hands a widget's view the size it's shown at (views take it as a value, so they can be drawn
/// outside a widget too).
struct SizedToFamily<Content: View>: View {
    @Environment(\.widgetFamily) private var family
    @ViewBuilder let content: (WidgetFamily) -> Content

    var body: some View { content(family) }
}

/// The theme's soft gradient, behind every widget: deep in dark mode, pale in light mode.
struct OrbitBackground: View {
    let palette: Palette
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let dark = scheme == .dark
        let base = dark ? Color(palette.bgDark, opacity: 0.92) : Color(red: 0.97, green: 0.97, blue: 0.99, opacity: 0.94)
        LinearGradient(colors: [Color(palette.accent, opacity: dark ? 0.32 : 0.2), base, Color(palette.accent2, opacity: dark ? 0.28 : 0.16)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

/// Shown when Orbit has quit (or stopped answering): the widgets can't change anything without it.
struct NotRunningView: View {
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "atom").font(.title2).foregroundStyle(.secondary)
            Text("Orbit isn't running").font(.headline)
            Text("Click to open it.").font(.caption).foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .widgetURL(OrbitLinks.url(.open(.page(.home))))
    }
}
