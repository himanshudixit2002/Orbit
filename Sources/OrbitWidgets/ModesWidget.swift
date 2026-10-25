import AppIntents
import OrbitCore
import SwiftUI
import WidgetKit

/// The user's modes as buttons: one click switches a mode on, or off if it's on.
struct ModesWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "com.himanshudixit.orbit.modes", provider: OrbitProvider()) { entry in
            SizedToFamily { ModesView(entry: entry, family: $0) }
                .containerBackground(for: .widget) { OrbitBackground(palette: entry.palette) }
        }
        .configurationDisplayName("Orbit Modes")
        .description("Switch Work, Focus, Chill, Present or your own modes with one click.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct ModesView: View {
    let entry: OrbitEntry
    let family: WidgetFamily

    var body: some View {
        if let snapshot = entry.snapshot, entry.live {
            let modes = Array(snapshot.modes.prefix(family == .systemSmall ? 4 : 6))
            let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: family == .systemSmall ? 2 : 3)
            VStack(alignment: .leading, spacing: 8) {
                Label("Modes", systemImage: "moon.stars.fill").font(.headline)
                LazyVGrid(columns: columns, spacing: 6) {
                    ForEach(modes) { mode in
                        ModeButton(mode: mode, active: snapshot.activeMode == mode.id, palette: entry.palette)
                    }
                }
                Spacer(minLength: 0)
            }
        } else {
            NotRunningView()
        }
    }
}

struct ModeButton: View {
    let mode: OrbitSnapshot.Mode
    let active: Bool
    let palette: Palette

    var body: some View {
        Button(intent: ToggleModeIntent(ModeEntity(id: mode.id, name: mode.name, symbol: mode.symbol))) {
            VStack(spacing: 3) {
                Image(systemName: mode.symbol).font(.title3)
                Text(mode.name).font(.caption2.weight(.semibold)).lineLimit(1)
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(active ? Color(palette.accent, opacity: 0.45) : Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10).strokeBorder(active ? Color(palette.accent) : .clear, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(mode.name) mode, \(active ? "on" : "off")")
    }
}
