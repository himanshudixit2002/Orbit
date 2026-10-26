import OrbitCore
import OrbitPlatform
import SwiftUI

struct HomePage: View {
    @Environment(AppModel.self) private var model

    var headline: String {
        let total = model.coreFeatures.count
        if model.status.checkedAt == nil { return "Checking your Mac…" }
        if model.doneCount == total { return "Everything is set up ✨" }
        return "Your Mac is \(model.doneCount) of \(total) set up"
    }

    var subline: String {
        let issues = model.attention.count
        if issues > 0 { return "\(issues) thing\(issues == 1 ? "" : "s") need\(issues == 1 ? "s" : "") a quick OK from you." }
        if model.doneCount < model.coreFeatures.count { return "Switch on what you'd like below, or let the guided setup do it." }
        return "Have fun. You can change anything here, and undo it too."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 4) {
                Text(model.greeting).font(.system(size: 36, weight: .bold, design: .rounded))
                Text("Here's your Mac at a glance.").font(.title3).foregroundStyle(.secondary)
            }

            PausedBanner()

            GlassPanel(padding: 22, glow: Color(model.palette.accent)) {
                HStack(spacing: 24) {
                    ScoreRing(done: model.doneCount, total: model.coreFeatures.count)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(headline).font(.title2.weight(.bold))
                        Text(subline).foregroundStyle(.secondary)
                        HStack(spacing: 10) {
                            if model.doneCount < model.coreFeatures.count || !model.settings.setupCompleted {
                                Button { model.showSetup = true } label: { Label("Guided setup", systemImage: "wand.and.stars") }
                                    .buttonStyle(.glassProminent)
                            }
                            if let first = model.attention.first, model.paused == nil {
                                Button { model.fix(first) } label: { Label("Fix \(first.shortTitle.lowercased())", systemImage: "wrench.and.screwdriver.fill") }
                                    .buttonStyle(.glass)
                            }
                            if model.paused == nil { PauseButton() }
                        }
                        .padding(.top, 4)
                    }
                    Spacer(minLength: 0)
                }
            }

            SectionTitle(text: "Quick switches")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 128), spacing: 14)], spacing: 14) {
                ForEach([FeatureID.tiling, .glow, .menuBar, .capsLock, .downloads], id: \.self) { id in
                    QuickTile(title: id.shortTitle, symbol: id.symbol, hue: id.hue, state: model.state(id),
                              isBusy: model.isBusy(busyKey(id))) { model.toggle(id) }
                }
                ModeTile()
            }

            SectionTitle(text: "Right now")
            MiniStats()

            if !model.doctor.isEmpty {
                GlassPanel {
                    HStack(spacing: 12) {
                        IconTile(symbol: "stethoscope", hue: .red, size: 34)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("The Doctor found \(model.doctor.count) thing\(model.doctor.count == 1 ? "" : "s") to look at").font(.headline)
                            Text(model.doctor.first?.title ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Button("Show") { model.page = .health }.buttonStyle(.glass)
                    }
                }
            }

            if !model.speedFindings.isEmpty {
                GlassPanel {
                    HStack(spacing: 12) {
                        IconTile(symbol: "bolt.fill", hue: .orange, size: 34)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(model.speedFindings.count) thing\(model.speedFindings.count == 1 ? "" : "s") slow\(model.speedFindings.count == 1 ? "s" : "") your Mac down").font(.headline)
                            Text(model.speedFindings.first?.title ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Button("Show") { model.page = .speed }.buttonStyle(.glass)
                    }
                }
            }

            if !model.attention.isEmpty {
                SectionTitle(text: "Needs your OK")
                VStack(spacing: 12) {
                    ForEach(model.attention, id: \.self) { id in
                        FeatureCard(title: id.title, blurb: id.blurb, symbol: id.symbol, hue: id.hue,
                                    state: model.state(id), onFix: { model.fix(id) })
                    }
                }
            }
        }
    }

    func busyKey(_ id: FeatureID) -> String {
        id == .capsLock ? "keyboard" : id.rawValue
    }
}

/// The current mode as a quick switch: tap to open the Modes page.
struct ModeTile: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let active = model.settings.modes.first { $0.id == model.modes.active?.modeID }
        QuickTile(title: "Mode", symbol: active?.symbol ?? "moon.stars.fill", hue: .purple,
                  state: active == nil ? .off : .on) { model.page = .modes }
            .overlay(alignment: .bottomTrailing) {
                if let active {
                    Text(active.name).font(.caption.weight(.bold)).padding(10).foregroundStyle(Hue.purple.top)
                }
            }
    }
}

/// Four little live gauges.
struct MiniStats: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let s = model.monitor.latest
        let history = model.monitor.history
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 14)], spacing: 14) {
            StatTile(title: "Processor", value: percent(s.cpu), symbol: "cpu", hue: .green,
                     series: history.map(\.cpu), fraction: s.cpu)
            StatTile(title: "Memory", value: bytes(Int64(s.memoryUsed)) + " used", symbol: "memorychip", hue: pressureHue(s.memoryPressure),
                     series: history.map(\.memoryFraction), fraction: s.memoryFraction)
            StatTile(title: "Storage", value: diskBytes(s.diskFree) + " free", symbol: "internaldrive", hue: s.diskUsedFraction > 0.9 ? .red : .blue,
                     series: [], fraction: s.diskUsedFraction)
            StatTile(title: "Network", value: "↓ " + speed(s.download) + "  ↑ " + speed(s.upload), symbol: "network", hue: .cyan,
                     series: normalized(history.map(\.download)), fraction: nil)
        }
        .liveStats(model.monitor)
    }

    func pressureHue(_ level: Int) -> Hue { level >= 4 ? .red : level >= 2 ? .orange : .purple }
}

func percent(_ fraction: Double) -> String { "\(Int((fraction * 100).rounded()))%" }
func bytes(_ count: Int64) -> String { ByteCountFormatter.string(fromByteCount: count, countStyle: .memory) }
/// Disk space as Finder and System Settings count it (a GB is a billion bytes; memory counts in 1024s).
func diskBytes(_ count: Int64) -> String { ByteCountFormatter.string(fromByteCount: count, countStyle: .file) }
func speed(_ perSecond: Double) -> String { ByteCountFormatter.string(fromByteCount: Int64(perSecond), countStyle: .file) + "/s" }
func normalized(_ values: [Double]) -> [Double] {
    let top = max(values.max() ?? 1, 1)
    return values.map { $0 / top }
}

struct StatTile: View {
    let title: String
    let value: String
    let symbol: String
    let hue: Hue
    let series: [Double]
    let fraction: Double?

    var body: some View {
        GlassPanel(padding: 14, radius: 18) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: symbol).foregroundStyle(hue.top)
                    Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                    Spacer()
                }
                Text(value).font(.system(.title3, design: .rounded).weight(.bold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
                if !series.isEmpty {
                    Sparkline(values: series, color: hue.top).frame(height: 30)
                } else if let fraction {
                    ProgressView(value: fraction).tint(hue.top).frame(height: 30)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// A tiny line chart.
struct Sparkline: View {
    let values: [Double]
    let color: Color

    var body: some View {
        GeometryReader { geo in
            let points = values.enumerated().map { i, v in
                CGPoint(x: geo.size.width * CGFloat(i) / CGFloat(max(values.count - 1, 1)),
                        y: geo.size.height * (1 - CGFloat(min(max(v, 0), 1))))
            }
            ZStack {
                Path { p in
                    guard let first = points.first else { return }
                    p.move(to: CGPoint(x: first.x, y: geo.size.height))
                    points.forEach { p.addLine(to: $0) }
                    p.addLine(to: CGPoint(x: points.last?.x ?? 0, y: geo.size.height))
                    p.closeSubpath()
                }
                .fill(LinearGradient(colors: [color.opacity(0.35), color.opacity(0)], startPoint: .top, endPoint: .bottom))
                Path { p in
                    guard let first = points.first else { return }
                    p.move(to: first)
                    points.dropFirst().forEach { p.addLine(to: $0) }
                }
                .stroke(color, style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
                .shadow(color: color.opacity(0.6), radius: 3)
            }
        }
        .accessibilityHidden(true)
    }
}
