import AppIntents
import OrbitCore
import SwiftUI
import WidgetKit

/// How the Mac is doing: how much is set up, what needs attention, the mode that's on, and switches
/// for the five features (in the medium and large sizes).
struct StatusWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "com.himanshudixit.orbit.status", provider: OrbitProvider()) { entry in
            SizedToFamily { StatusView(entry: entry, family: $0) }
                .containerBackground(for: .widget) { OrbitBackground(palette: entry.palette) }
        }
        .configurationDisplayName("Orbit")
        .description("How your Mac is set up, what needs you, and quick switches.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct StatusView: View {
    let entry: OrbitEntry
    let family: WidgetFamily

    var body: some View {
        if let snapshot = entry.snapshot, entry.live {
            switch family {
            case .systemSmall: small(snapshot)
            case .systemLarge: large(snapshot)
            default: medium(snapshot)
            }
        } else {
            NotRunningView()
        }
    }

    func small(_ s: OrbitSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "atom").foregroundStyle(Color(entry.palette.accent))
                Text("Orbit").font(.headline)
                Spacer()
            }
            Spacer(minLength: 0)
            ScoreRing(done: s.done, total: s.features.count, palette: entry.palette, size: 62)
            Spacer(minLength: 0)
            footer(s)
        }
        .widgetURL(OrbitLinks.url(.open(.page(s.attention.isEmpty ? .home : .health))))
    }

    func medium(_ s: OrbitSnapshot) -> some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                ScoreRing(done: s.done, total: s.features.count, palette: entry.palette, size: 70)
                footer(s)
            }
            .frame(width: 112, alignment: .leading)
            VStack(spacing: 4) {
                ForEach(FeatureChoice.allCases, id: \.self) { choice in
                    FeatureSwitch(choice: choice, feature: s.feature(choice.feature))
                }
            }
        }
    }

    func large(_ s: OrbitSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                ScoreRing(done: s.done, total: s.features.count, palette: entry.palette, size: 70)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Your Mac is \(s.done) of \(s.features.count) set up").font(.headline)
                    footer(s)
                }
            }
            VStack(spacing: 4) {
                ForEach(FeatureChoice.allCases, id: \.self) { choice in
                    FeatureSwitch(choice: choice, feature: s.feature(choice.feature))
                }
            }
            if let first = s.attention.first {
                Label(first.detail ?? "\(first.id.title) needs your attention.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .widgetURL(OrbitLinks.url(.open(.page(s.attention.isEmpty ? .home : .health))))
    }

    @ViewBuilder
    func footer(_ s: OrbitSnapshot) -> some View {
        if !s.attention.isEmpty {
            Label("\(s.attention.count) need\(s.attention.count == 1 ? "s" : "") you", systemImage: "exclamationmark.circle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.orange)
        } else if let mode = s.activeMode.flatMap(s.mode) {
            Label("\(mode.name) mode", systemImage: mode.symbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color(entry.palette.accent2))
        } else {
            Label("All good", systemImage: "checkmark.seal.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.green)
        }
    }
}

/// "8 of 10" in a ring.
struct ScoreRing: View {
    let done: Int
    let total: Int
    let palette: Palette
    let size: CGFloat

    var body: some View {
        ZStack {
            Circle().stroke(.quaternary, lineWidth: size * 0.11)
            Circle()
                .trim(from: 0, to: total == 0 ? 0 : CGFloat(done) / CGFloat(total))
                .stroke(AngularGradient(colors: [Color(palette.accent), Color(palette.accent2), Color(palette.accent)], center: .center),
                        style: StrokeStyle(lineWidth: size * 0.11, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: -2) {
                Text("\(done)").font(.system(size: size * 0.36, weight: .bold, design: .rounded))
                Text("of \(total)").font(.system(size: size * 0.14)).foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(done) of \(total) set up")
    }
}

/// One feature with its switch; the switch runs in Orbit, like the one in its window.
struct FeatureSwitch: View {
    let choice: FeatureChoice
    let feature: OrbitSnapshot.Feature?

    var body: some View {
        let state = feature?.state ?? .checking
        HStack(spacing: 8) {
            Image(systemName: choice.feature.symbol)
                .frame(width: 18)
                .foregroundStyle(state.color)
            Text(choice.feature.shortTitle).font(.callout).lineLimit(1)
            Spacer(minLength: 4)
            if state == .on || state == .off {
                Toggle(isOn: state == .on, intent: FeatureSwitchIntent(choice)) { EmptyView() }
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
            } else {
                Text(state.label).font(.caption2).foregroundStyle(state.color)
            }
        }
    }
}
