import AppKit
import OrbitCore
import SwiftUI

/// Movement that follows Reduce Motion (System Settings › Accessibility › Display): with it on, springs
/// and slides become short fades, and decorative movement shows its end straight away.
enum Motion {
    static var reduced: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    static func animation(_ animation: Animation) -> Animation { reduced ? .easeInOut(duration: 0.15) : animation }

    static func transition(_ transition: AnyTransition) -> AnyTransition { reduced ? .opacity : transition }

    /// A decorative change: animated, or made at once with Reduce Motion on.
    static func reveal(_ animation: Animation, _ change: () -> Void) {
        if reduced { change() } else { withAnimation(animation, change) }
    }
}

extension Color {
    init(_ rgb: RGB, opacity: Double = 1) {
        self.init(.sRGB, red: rgb.red, green: rgb.green, blue: rgb.blue, opacity: opacity)
    }
}

/// The two colours behind each section's icon.
struct Hue: Equatable {
    let top: Color
    let bottom: Color

    var gradient: LinearGradient { LinearGradient(colors: [top, bottom], startPoint: .topLeading, endPoint: .bottomTrailing) }

    static let blue = Hue(top: Color(red: 0.36, green: 0.62, blue: 1.0), bottom: Color(red: 0.33, green: 0.36, blue: 0.95))
    static let purple = Hue(top: Color(red: 0.74, green: 0.52, blue: 1.0), bottom: Color(red: 0.49, green: 0.31, blue: 0.93))
    static let pink = Hue(top: Color(red: 1.0, green: 0.45, blue: 0.62), bottom: Color(red: 0.93, green: 0.32, blue: 0.55))
    static let orange = Hue(top: Color(red: 1.0, green: 0.68, blue: 0.3), bottom: Color(red: 0.98, green: 0.45, blue: 0.24))
    static let yellow = Hue(top: Color(red: 1.0, green: 0.83, blue: 0.3), bottom: Color(red: 0.98, green: 0.62, blue: 0.15))
    static let green = Hue(top: Color(red: 0.36, green: 0.86, blue: 0.5), bottom: Color(red: 0.16, green: 0.68, blue: 0.42))
    static let teal = Hue(top: Color(red: 0.3, green: 0.85, blue: 0.85), bottom: Color(red: 0.12, green: 0.6, blue: 0.72))
    static let cyan = Hue(top: Color(red: 0.4, green: 0.82, blue: 1.0), bottom: Color(red: 0.2, green: 0.55, blue: 0.95))
    static let indigo = Hue(top: Color(red: 0.5, green: 0.48, blue: 1.0), bottom: Color(red: 0.32, green: 0.26, blue: 0.82))
    static let red = Hue(top: Color(red: 1.0, green: 0.48, blue: 0.45), bottom: Color(red: 0.9, green: 0.24, blue: 0.3))
    static let gray = Hue(top: Color(white: 0.62), bottom: Color(white: 0.42))
}

/// A rounded, colourful icon like the ones in System Settings.
struct IconTile: View {
    let symbol: String
    let hue: Hue
    var size: CGFloat = 28

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
            .fill(hue.gradient)
            .overlay {
                RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
                    .strokeBorder(.white.opacity(0.22), lineWidth: 0.6)
            }
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.18), radius: 1, y: 0.5)
            }
            .frame(width: size, height: size)
            .shadow(color: hue.bottom.opacity(0.35), radius: size * 0.18, y: size * 0.06)
    }
}

/// The soft gradient behind every page, tinted by the active theme.
struct AuroraBackground: View {
    let palette: Palette
    @Environment(\.colorScheme) private var scheme

    @Environment(\.accessibilityReduceTransparency) private var solid

    var body: some View {
        let dark = scheme == .dark
        let base = dark ? Color(palette.bgDark) : Color(red: 0.96, green: 0.96, blue: 0.98)
        let a = Color(palette.accent, opacity: dark ? 0.55 : 0.28)
        let b = Color(palette.accent2, opacity: dark ? 0.45 : 0.22)
        let c = Color(palette.cyan, opacity: dark ? 0.3 : 0.16)
        MeshGradient(
            width: 3, height: 3,
            points: [
                [0, 0], [0.5, 0], [1, 0],
                [0, 0.5], [0.62, 0.42], [1, 0.5],
                [0, 1], [0.5, 1], [1, 1]
            ],
            colors: [
                a, base, b,
                base, base, c,
                b.opacity(0.6), base, a.opacity(0.7)
            ]
        )
        // Reduce Transparency: a plain background.
        .overlay(base.opacity(solid ? 1 : dark ? 0.35 : 0.45))
        .ignoresSafeArea()
    }
}

/// A frosted-glass panel.
struct GlassPanel<Content: View>: View {
    var padding: CGFloat = 18
    var radius: CGFloat = 22
    var glow: Color?
    @ViewBuilder var content: Content
    @Environment(\.accessibilityReduceTransparency) private var solid

    var body: some View {
        // Reduce Transparency: solid panels without the coloured glow.
        let glow = solid ? nil : glow
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(solid ? Color(nsColor: .windowBackgroundColor) : .clear, in: .rect(cornerRadius: radius))
            .glassEffect(solid ? .identity : .regular, in: .rect(cornerRadius: radius))
            .overlay {
                if let glow {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(glow.opacity(0.55), lineWidth: 1)
                }
            }
            // Plain panels get a zero shadow (one modifier chain keeps the contents' identity when the
            // glow comes and goes); a real shadow is redrawn whenever anything inside changes.
            .shadow(color: (glow ?? .clear).opacity(0.35), radius: glow == nil ? 0 : 18, y: glow == nil ? 0 : 6)
    }
}

/// "On", "Off", "Needs your OK"…
struct StatusPill: View {
    let state: FeatureState

    var color: Color {
        switch state {
        case .on: .green
        case .off: .secondary
        case .notInstalled: .gray
        case .needsPermission: .orange
        case .blocked: .red
        case .working, .unknown: .blue
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            if case .working = state {
                ProgressView().controlSize(.mini)
            } else if case .unknown = state {
                ProgressView().controlSize(.mini)
            } else {
                Circle().fill(color).frame(width: 7, height: 7)
                    .shadow(color: state.isOn ? .green.opacity(0.8) : .clear, radius: 4)
            }
            Text(state.label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(state == .off ? .secondary : color)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(color.opacity(0.13), in: Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Status: \(state.label)")
    }
}

/// A title and a friendly sentence at the top of a page.
struct PageHeader: View {
    let page: Page
    var subtitle: String?

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            IconTile(symbol: page.symbol, hue: page.hue, size: 52)
            VStack(alignment: .leading, spacing: 4) {
                Text(page.title).font(.system(size: 30, weight: .bold, design: .rounded))
                Text(subtitle ?? page.blurb).font(.title3).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.bottom, 6)
    }
}

/// One feature: icon, name, what it does, a switch, its status, and optional extra controls.
struct FeatureCard<Extra: View>: View {
    let title: String
    let blurb: String
    let symbol: String
    let hue: Hue
    let state: FeatureState
    var poweredBy: String?
    var isBusy = false
    var illustration: AnyView?
    var onToggle: ((Bool) -> Void)?
    var onFix: (() -> Void)?
    var onInstall: (() -> Void)?
    @ViewBuilder var extra: Extra
    @State private var showMore = false

    var body: some View {
        GlassPanel(glow: state.isOn ? hue.top : nil) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 14) {
                    IconTile(symbol: symbol, hue: hue, size: 44)
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 10) {
                            Text(title).font(.title3.weight(.semibold))
                            StatusPill(state: isBusy ? .working("Working…") : state)
                        }
                        Text(blurb).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        if let detail = state.detail {
                            Label(detail, systemImage: state.needsAttention ? "exclamationmark.triangle.fill" : "info.circle")
                                .font(.callout)
                                .foregroundStyle(state.needsAttention ? .orange : .secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 12)
                    controls
                }
                extra
                if illustration != nil || poweredBy != nil {
                    HStack {
                        if illustration != nil {
                            Button(showMore ? "Hide picture" : "How it looks") {
                                withAnimation(Motion.animation(.spring(duration: 0.4))) { showMore.toggle() }
                            }
                            .buttonStyle(.link)
                            .font(.callout)
                        }
                        Spacer()
                        if let poweredBy {
                            Text("powered by \(poweredBy)").font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                    if showMore, let illustration {
                        illustration
                            .frame(maxWidth: .infinity)
                            .frame(height: 150)
                            .transition(Motion.transition(.opacity.combined(with: .scale(scale: 0.96))))
                    }
                }
            }
        }
    }

    @ViewBuilder var controls: some View {
        switch state {
        case .notInstalled:
            if let onInstall {
                Button("Install", action: onInstall).buttonStyle(.glassProminent).disabled(isBusy)
            }
        case .needsPermission, .blocked:
            HStack(spacing: 10) {
                if let onFix { Button("Fix", action: onFix).buttonStyle(.glassProminent) }
                if let onToggle { toggle(onToggle) }
            }
        default:
            if let onToggle { toggle(onToggle) }
        }
    }

    func toggle(_ action: @escaping (Bool) -> Void) -> some View {
        Toggle(isOn: Binding(get: { state.isOn || state.needsAttention }, set: { action($0) })) { EmptyView() }
            .toggleStyle(.switch)
            .controlSize(.large)
            .labelsHidden()
            .disabled(isBusy || state == .unknown)
            .accessibilityLabel(title)
    }
}

extension FeatureCard where Extra == EmptyView {
    init(title: String, blurb: String, symbol: String, hue: Hue, state: FeatureState, poweredBy: String? = nil,
         isBusy: Bool = false, illustration: AnyView? = nil, onToggle: ((Bool) -> Void)? = nil,
         onFix: (() -> Void)? = nil, onInstall: (() -> Void)? = nil) {
        self.init(title: title, blurb: blurb, symbol: symbol, hue: hue, state: state, poweredBy: poweredBy, isBusy: isBusy,
                  illustration: illustration, onToggle: onToggle, onFix: onFix, onInstall: onInstall) { EmptyView() }
    }
}

/// A big square switch for the Home page, like Control Center.
struct QuickTile: View {
    let title: String
    let symbol: String
    let hue: Hue
    let state: FeatureState
    var isBusy = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    IconTile(symbol: symbol, hue: state.isOn ? hue : .gray, size: 34)
                    Spacer()
                    if isBusy { ProgressView().controlSize(.small) }
                    else if state.needsAttention { Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange) }
                }
                Spacer(minLength: 0)
                Text(title).font(.headline).foregroundStyle(.primary).lineLimit(1)
                Text(isBusy ? "Working…" : state.label).font(.subheadline).foregroundStyle(.secondary)
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 112, alignment: .leading)
            .contentShape(.rect(cornerRadius: 20))
        }
        .buttonStyle(.plain)
        .glassEffect(state.isOn ? .regular.tint(hue.top.opacity(0.35)).interactive() : .regular.interactive(),
                     in: .rect(cornerRadius: 20))
        .shadow(color: state.isOn ? hue.top.opacity(0.45) : .clear, radius: 16, y: 4)
        .accessibilityLabel("\(title), \(state.label)")
        .accessibilityHint(state == .notInstalled ? "Opens the page to install it" : "Switches it on or off")
    }
}

/// How much of the Mac is set up, as a ring.
struct ScoreRing: View {
    let done: Int
    let total: Int
    var hue: Hue = .blue

    var fraction: Double { total == 0 ? 0 : Double(done) / Double(total) }

    var body: some View {
        ZStack {
            Circle().stroke(.quaternary, lineWidth: 12)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(AngularGradient(colors: [hue.top, hue.bottom, hue.top], center: .center),
                        style: StrokeStyle(lineWidth: 12, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .shadow(color: hue.top.opacity(0.6), radius: 8)
                .animation(Motion.animation(.spring(duration: 0.9)), value: fraction)
            VStack(spacing: 0) {
                Text("\(done)").font(.system(size: 34, weight: .bold, design: .rounded)).contentTransition(.numericText())
                Text("of \(total)").font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(width: 108, height: 108)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(done) of \(total) set up")
    }
}

/// A short message after something changes, with an Undo button.
struct ToastView: View {
    let toast: Toast
    let undo: (() -> Void)?
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: toast.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.title3)
                .foregroundStyle(toast.ok ? .green : .orange)
            Text(toast.message).fixedSize(horizontal: false, vertical: true)
            if let undo {
                Button("Undo", action: undo).buttonStyle(.glass)
            }
            Button(action: dismiss) { Image(systemName: "xmark") }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .glassEffect(.regular, in: .capsule)
        .shadow(color: .black.opacity(0.18), radius: 16, y: 8)
        .frame(maxWidth: 560)
    }
}

struct Toast: Identifiable, Equatable {
    let id = UUID()
    let ok: Bool
    let message: String
    let journalID: UUID?
}

/// A labelled row inside a card: setting name on the left, its control on the right.
struct SettingRow<Control: View>: View {
    let title: String
    var detail: String?
    @ViewBuilder var control: Control

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 12)
            control
        }
        .padding(.vertical, 2)
    }
}

/// Section title used inside long pages.
struct SectionTitle: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(.caption.weight(.bold))
            .tracking(0.8)
            .foregroundStyle(.secondary)
            .padding(.top, 8)
            .padding(.leading, 4)
    }
}
