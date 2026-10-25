import OrbitCore
import SwiftUI

/// Orbit's mark: a glowing planet inside a tilted ring.
struct OrbitLogo: View {
    var size: CGFloat = 32

    var body: some View {
        ZStack {
            Circle()
                .fill(LinearGradient(colors: [Hue.blue.top, Hue.purple.bottom], startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: size * 0.56, height: size * 0.56)
                .shadow(color: Hue.blue.top.opacity(0.7), radius: size * 0.16)
            Ellipse()
                .stroke(LinearGradient(colors: [.white.opacity(0.95), Hue.pink.top.opacity(0.8)], startPoint: .leading, endPoint: .trailing),
                        lineWidth: max(1.5, size * 0.06))
                .frame(width: size * 0.98, height: size * 0.38)
                .rotationEffect(.degrees(-24))
            Circle()
                .fill(.white)
                .frame(width: size * 0.13, height: size * 0.13)
                .offset(x: size * 0.4, y: -size * 0.15)
                .shadow(color: .white, radius: size * 0.08)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// A small screen to draw the illustrations on.
private struct MiniScreen<Content: View>: View {
    @ViewBuilder var content: (CGSize) -> Content

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(LinearGradient(colors: [Color(red: 0.1, green: 0.11, blue: 0.2), Color(red: 0.16, green: 0.12, blue: 0.28)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                content(geo.size)
            }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .accessibilityHidden(true)
    }
}

private struct MiniWindow: View {
    var tint: Color = .white
    var glow: Color?

    var body: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(tint.opacity(0.16))
            .overlay(alignment: .topLeading) {
                HStack(spacing: 3) {
                    Circle().fill(.red.opacity(0.8))
                    Circle().fill(.yellow.opacity(0.8))
                    Circle().fill(.green.opacity(0.8))
                }
                .frame(height: 5)
                .padding(5)
            }
            .overlay {
                if let glow {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(glow, lineWidth: 2.5)
                        .shadow(color: glow, radius: 6)
                }
            }
    }
}

/// Windows drift into neat tiles.
struct TilingIllustration: View {
    @State private var tiled = false

    var body: some View {
        MiniScreen { size in
            let pad: CGFloat = 10, gap: CGFloat = 6
            let w = size.width - pad * 2, h = size.height - pad * 2
            let frames: [(CGRect, CGRect, Color)] = [
                (CGRect(x: pad, y: pad, width: (w - gap) / 2, height: h), CGRect(x: w * 0.2, y: h * 0.3, width: w * 0.45, height: h * 0.5), Hue.blue.top),
                (CGRect(x: pad + (w + gap) / 2, y: pad, width: (w - gap) / 2, height: (h - gap) / 2),
                 CGRect(x: w * 0.45, y: h * 0.1, width: w * 0.4, height: h * 0.45), Hue.purple.top),
                (CGRect(x: pad + (w + gap) / 2, y: pad + (h + gap) / 2, width: (w - gap) / 2, height: (h - gap) / 2),
                 CGRect(x: w * 0.05, y: h * 0.45, width: w * 0.42, height: h * 0.4), Hue.pink.top)
            ]
            ForEach(0..<frames.count, id: \.self) { i in
                let (target, messy, tint) = frames[i]
                let frame = tiled ? target : messy
                MiniWindow(tint: tint, glow: i == 0 && tiled ? Hue.blue.top : nil)
                    .frame(width: frame.width, height: frame.height)
                    .rotationEffect(.degrees(tiled ? 0 : Double(i * 7 - 6)))
                    .offset(x: frame.minX, y: frame.minY)
            }
        }
        .onAppear { Motion.reveal(.spring(duration: 1.1, bounce: 0.25).delay(0.25)) { tiled = true } }
    }
}

/// The window you're using gets a soft glow.
struct GlowIllustration: View {
    let color: Color
    @State private var lit = false

    var body: some View {
        MiniScreen { size in
            MiniWindow(tint: .white)
                .frame(width: size.width * 0.5, height: size.height * 0.55)
                .offset(x: size.width * 0.08, y: size.height * 0.12)
            MiniWindow(tint: color, glow: lit ? color : color.opacity(0.1))
                .frame(width: size.width * 0.55, height: size.height * 0.6)
                .offset(x: size.width * 0.36, y: size.height * 0.3)
                .scaleEffect(lit ? 1 : 0.97)
        }
        .onAppear { Motion.reveal(.easeOut(duration: 1.2).delay(0.2)) { lit = true } }
    }
}

/// A floating bar slides down from the top.
struct MenuBarIllustration: View {
    let palette: Palette
    @State private var shown = false

    var body: some View {
        MiniScreen { size in
            HStack(spacing: 5) {
                Image(systemName: "applelogo").font(.system(size: 8, weight: .bold)).foregroundStyle(Color(palette.accent))
                ForEach(1..<5) { i in
                    Text("\(i)").font(.system(size: 7, weight: .bold, design: .rounded))
                        .foregroundStyle(i == 1 ? Color(palette.bg) : .white.opacity(0.5))
                        .frame(width: 11, height: 11)
                        .background(i == 1 ? Color(palette.accent) : .clear, in: RoundedRectangle(cornerRadius: 3))
                }
                Spacer()
                Image(systemName: "music.note").font(.system(size: 7)).foregroundStyle(Color(palette.green))
                Spacer()
                ForEach(["cpu", "memorychip", "wifi"], id: \.self) {
                    Image(systemName: $0).font(.system(size: 7)).foregroundStyle(.white.opacity(0.75))
                }
                Text("21:04").font(.system(size: 7, weight: .semibold, design: .rounded)).foregroundStyle(.white)
            }
            .padding(.horizontal, 8)
            .frame(width: size.width - 16, height: 16)
            .background(Color(palette.bgDark).opacity(0.92), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(palette.accent).opacity(0.5), lineWidth: 0.6))
            .offset(x: 8, y: shown ? 6 : -24)
            MiniWindow(tint: Color(palette.accent))
                .frame(width: size.width - 20, height: size.height - 40)
                .offset(x: 10, y: 30)
        }
        .onAppear { Motion.reveal(.spring(duration: 0.9).delay(0.25)) { shown = true } }
    }
}

/// Caps Lock becomes Escape and Hyper.
struct KeyboardIllustration: View {
    @State private var pressed = false

    func key(_ text: String, width: CGFloat = 28, lit: Bool = false) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold, design: .rounded))
            .foregroundStyle(lit ? .white : .white.opacity(0.7))
            .frame(width: width, height: 24)
            .background(lit ? AnyShapeStyle(Hue.orange.gradient) : AnyShapeStyle(.white.opacity(0.12)), in: RoundedRectangle(cornerRadius: 5))
            .shadow(color: lit ? Hue.orange.top.opacity(0.8) : .clear, radius: 6)
    }

    var body: some View {
        MiniScreen { _ in
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 4) { key("esc", width: 36, lit: pressed); ForEach(["1", "2", "3", "4", "5"], id: \.self) { key($0) } }
                HStack(spacing: 4) { key("tab", width: 42); ForEach(["Q", "W", "E", "R"], id: \.self) { key($0) } }
                HStack(spacing: 4) { key("caps", width: 50, lit: pressed); key("A"); key("S"); key("D"); key("F", lit: pressed) }
                Text(pressed ? "tap = esc   ·   hold + F = Finder" : " ")
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.top, 2)
            }
            .padding(14)
        }
        .onAppear { Motion.reveal(.easeInOut(duration: 0.6).delay(0.4)) { pressed = true } }
    }
}

/// Files fly into tidy folders.
struct SortIllustration: View {
    @State private var sorted = false

    var body: some View {
        MiniScreen { size in
            let folders: [(String, Color)] = [("doc.fill", Hue.blue.top), ("photo.fill", Hue.pink.top), ("archivebox.fill", Hue.orange.top)]
            ForEach(0..<3) { i in
                VStack(spacing: 4) {
                    Image(systemName: "folder.fill").font(.system(size: 26)).foregroundStyle(folders[i].1)
                    Text(["Documents", "Images", "Archives"][i]).font(.system(size: 8, weight: .medium)).foregroundStyle(.white.opacity(0.8))
                }
                .position(x: size.width * (0.2 + 0.3 * CGFloat(i)), y: size.height * 0.72)
                Image(systemName: folders[i].0)
                    .font(.system(size: 14))
                    .foregroundStyle(.white)
                    .position(x: sorted ? size.width * (0.2 + 0.3 * CGFloat(i)) : size.width * (0.35 + 0.12 * CGFloat(i)),
                              y: sorted ? size.height * 0.68 : size.height * (0.2 + 0.08 * CGFloat(i)))
                    .opacity(sorted ? 0 : 1)
            }
        }
        .onAppear { Motion.reveal(.easeIn(duration: 1.0).delay(0.4)) { sorted = true } }
    }
}
