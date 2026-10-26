import AppKit
import OrbitCore
import OrbitPlatform
import SwiftUI

/// The quick panel: in the macOS menu bar, and opened by orbit://panel (the Apple logo in the new bar).
public struct MenuBarPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    public init() {}

    public var body: some View {
        let s = model.monitor.latest
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                OrbitLogo(size: 26)
                Text("Orbit").font(.system(size: 18, weight: .bold, design: .rounded))
                Spacer()
                if model.isPractice {
                    Text("Practice").font(.caption.weight(.bold)).foregroundStyle(.orange)
                }
                Button { Task { await model.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Check again")
            }

            HStack(spacing: 10) {
                if model.paused != nil {
                    Label("Paused", systemImage: "pause.circle.fill").font(.callout.weight(.semibold)).foregroundStyle(.orange)
                } else {
                    Text("Everything Orbit runs").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                PauseButton().controlSize(.small)
            }

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                ForEach([FeatureID.tiling, .glow, .menuBar, .capsLock, .downloads, .terminalLook], id: \.self) { id in
                    let state = model.state(id)
                    Button { model.toggle(id) } label: {
                        VStack(spacing: 6) {
                            IconTile(symbol: id.symbol, hue: state.isOn ? id.hue : .gray, size: 30)
                            Text(id.shortTitle).font(.caption.weight(.medium)).lineLimit(1)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .contentShape(.rect(cornerRadius: 14))
                    }
                    .buttonStyle(.plain)
                    .glassEffect(state.isOn ? .regular.tint(id.hue.top.opacity(0.3)).interactive() : .regular.interactive(),
                                 in: .rect(cornerRadius: 14))
                    .overlay(alignment: .topTrailing) {
                        if state.needsAttention {
                            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange).padding(4)
                        }
                    }
                    .accessibilityLabel("\(id.title), \(state.label)")
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Mode").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    ForEach(model.settings.modes) { mode in
                        let active = model.modes.active?.modeID == mode.id
                        Button { Task { await model.modes.toggle(mode) } } label: {
                            Label(mode.name, systemImage: mode.symbol)
                                .labelStyle(.titleAndIcon)
                                .font(.caption.weight(.semibold))
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(active ? AnyButtonStyle(.glassProminent) : AnyButtonStyle(.glass))
                        .controlSize(.small)
                    }
                }
            }

            HStack(spacing: 14) {
                mini("cpu", percent(s.cpu))
                mini("memorychip", percent(s.memoryFraction))
                mini("internaldrive", bytes(s.diskFree))
                mini("arrow.down", speed(s.download))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)

            HStack {
                Button("Open Orbit") { model.openMainWindow() }
                .buttonStyle(.glassProminent)
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }.buttonStyle(.glass)
            }
        }
        .padding(16)
        .frame(width: 340)
        .liveStats(model.monitor)
    }

    func mini(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: symbol)
            Text(text).lineLimit(1)
        }
    }
}

/// Lets one button switch between the glass styles.
struct AnyButtonStyle: PrimitiveButtonStyle {
    private let make: (Configuration) -> AnyView

    init<S: PrimitiveButtonStyle>(_ style: S) {
        make = { AnyView(style.makeBody(configuration: $0)) }
    }

    func makeBody(configuration: Configuration) -> some View { make(configuration) }
}
