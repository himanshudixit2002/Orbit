import CoreGraphics
import Foundation
import ImageIO
import OrbitCore
import UniformTypeIdentifiers

extension Actions {
    /// Gives the glow, the menu bar and the terminal tools one palette.
    public func applyTheme(_ id: ThemeID, tmux: Bool, policy: WritePolicy = .askIfEdited) async throws -> ActionOutcome {
        let p = Palette.named(id)
        var files: [ManagedFile: String] = [
            .bordersrc: BordersConfig.render(settings.glow, palette: p),
            .sketchybarColors: SketchyBarConfig.colors(p),
            .batTheme: TerminalThemes.bat(p),
            .batConfig: TerminalThemes.batConfig(),
            .btopTheme: TerminalThemes.btop(p),
            .lazygit: TerminalThemes.lazygit(p),
            .fastfetch: TerminalThemes.fastfetch(p)
        ]
        if tmux { files[.tmuxTheme] = TerminalThemes.tmux(p) }
        try checkEdits(files, policy: policy)
        let backups = backupFolder("theme \(p.name)")
        return await steps { undo in
            undo += changeSettings {
                $0.theme = id
                $0.themeTmux = tmux
            }

            undo += try write(.bordersrc, files[.bordersrc]!, executable: true, backups: backups)
            if await isRunning(.borders) {
                await ctx.run(Commands.bordersApply(BordersConfig.options(settings.glow, palette: p)))
            }
            undo += try write(.sketchybarColors, files[.sketchybarColors]!, executable: true, backups: backups)
            if await isRunning(.sketchybar) { await ctx.run(Commands.sketchybarReload()) }

            undo += try write(.batTheme, files[.batTheme]!, backups: backups)
            undo += try write(.batConfig, files[.batConfig]!, backups: backups)
            await ctx.run(Commands.batCacheBuild())
            let delta = await ctx.run(Commands.gitConfigGet("delta.syntax-theme"))
            let oldDelta = delta.status == 0 ? delta.stdout.trimmingCharacters(in: .whitespacesAndNewlines) : nil
            if oldDelta != TerminalThemes.themeName {
                await ctx.run(Commands.gitConfigSet("delta.syntax-theme", TerminalThemes.themeName))
                undo.append(.gitConfig(key: "delta.syntax-theme", value: oldDelta))
            }

            undo += try write(.btopTheme, files[.btopTheme]!, backups: backups)
            let btopConf = ctx.files.read(paths.btopConf).map { String(decoding: $0, as: UTF8.self) }
            undo += try writePlain(paths.btopConf, TerminalThemes.btopConf(btopConf), executable: false, backups: backups)
            undo += try write(.lazygit, files[.lazygit]!, backups: backups)
            undo += try write(.fastfetch, files[.fastfetch]!, backups: backups)

            if tmux, let theme = files[.tmuxTheme] {
                undo += try write(.tmuxTheme, theme, backups: backups)
                let conf = ctx.files.read(paths.tmuxConf).map { String(decoding: $0, as: UTF8.self) } ?? ""
                undo += try writePlain(paths.tmuxConf, TerminalThemes.tmuxConfWithInclude(conf), executable: false, backups: backups)
                await ctx.run(Command(Tool.tmux, ["source-file", paths.tmuxTheme.path(percentEncoded: false)],
                                      effect: .userFiles, summary: "Recolour open tmux windows", timeout: 5, okStatuses: [0, 1]))
            }
            return "Your Mac now wears \(p.name)."
        }
    }

    /// Removes Orbit's block from ~/.tmux.conf, leaving the rest exactly as it was.
    public func removeTmuxTheme() async throws -> ActionOutcome {
        await steps { undo in
            undo += changeSettings { $0.themeTmux = false }
            guard let data = ctx.files.read(paths.tmuxConf) else { return "Nothing to remove." }
            undo += try writePlain(paths.tmuxConf, TerminalThemes.tmuxConfWithoutInclude(String(decoding: data, as: UTF8.self)),
                                   executable: false, backups: backupFolder("tmux"))
            return "tmux keeps its own colours again."
        }
    }
}

/// Draws a wallpaper for a palette: an aurora glow with faint orbit rings and a few planets.
public enum WallpaperRenderer {
    public static let version = 1

    public static func fileName(_ p: Palette, width: Int, height: Int) -> String {
        "orbit-\(p.id.rawValue)-\(width)x\(height)-v\(version).png"
    }

    /// Renders (or reuses) the wallpaper and returns where it is.
    public static func file(_ p: Palette, width: Int, height: Int, folder: URL) throws -> URL {
        let url = folder.appending(path: fileName(p, width: width, height: height))
        if FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) { return url }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard let image = render(p, width: width, height: height),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
        return url
    }

    static func color(_ c: RGB, _ alpha: Double = 1) -> CGColor {
        CGColor(srgbRed: c.red, green: c.green, blue: c.blue, alpha: alpha)
    }

    public static func render(_ p: Palette, width: Int, height: Int) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let w = CGFloat(width), h = CGFloat(height), unit = min(w, h)

        // Base: a deep vertical gradient.
        let base = CGGradient(colorsSpace: space, colors: [color(p.bg), color(p.bgDark)] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(base, start: CGPoint(x: 0, y: h), end: CGPoint(x: 0, y: 0), options: [])

        func glow(_ c: RGB, _ x: CGFloat, _ y: CGFloat, _ radius: CGFloat, _ alpha: Double) {
            let g = CGGradient(colorsSpace: space, colors: [color(c, alpha), color(c, alpha * 0.35), color(c, 0)] as CFArray,
                               locations: [0, 0.45, 1])!
            let centre = CGPoint(x: x * w, y: y * h)
            ctx.drawRadialGradient(g, startCenter: centre, startRadius: 0, endCenter: centre, endRadius: radius * unit, options: [])
        }
        // Aurora: three soft clouds of colour.
        glow(p.accent, 0.2, 0.78, 0.95, 0.5)
        glow(p.accent2, 0.88, 0.2, 0.9, 0.42)
        glow(p.cyan, 0.72, 0.9, 0.55, 0.22)

        // Faint star dust, the same for every render of a theme.
        var seed = UInt64(p.id.rawValue.unicodeScalars.reduce(5381) { ($0 << 5) &+ UInt64($1.value) })
        func random() -> CGFloat {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return CGFloat((seed >> 33) % 10_000) / 10_000
        }
        for _ in 0..<Int(w * h / 9000) {
            let size = 0.6 + random() * 1.6 * unit / 1080
            ctx.setFillColor(color(p.fg, 0.04 + Double(random()) * 0.18))
            ctx.fillEllipse(in: CGRect(x: random() * w, y: random() * h, width: size, height: size))
        }

        // Orbit rings around an off-centre point, tilted.
        let centre = CGPoint(x: w * 0.6, y: h * 0.45)
        ctx.saveGState()
        ctx.translateBy(x: centre.x, y: centre.y)
        ctx.rotate(by: -0.32)
        let rings: [(CGFloat, Double)] = [(0.22, 0.13), (0.36, 0.1), (0.52, 0.075), (0.7, 0.05)]
        for (radius, alpha) in rings {
            let rw = radius * unit * 1.9, rh = radius * unit * 0.72
            ctx.setStrokeColor(color(p.fg, alpha))
            ctx.setLineWidth(max(1.2, unit / 900))
            ctx.strokeEllipse(in: CGRect(x: -rw / 2, y: -rh / 2, width: rw, height: rh))
        }
        // Planets riding the rings.
        let planets: [(CGFloat, CGFloat, RGB, CGFloat)] = [
            (0.22, 0.6, p.accent, 0.012), (0.36, 3.6, p.accent2, 0.009), (0.52, 2.2, p.yellow, 0.007), (0.7, 5.1, p.cyan, 0.006)
        ]
        for (radius, angle, c, size) in planets {
            let point = CGPoint(x: cos(angle) * radius * unit * 0.95, y: sin(angle) * radius * unit * 0.36)
            let g = CGGradient(colorsSpace: space, colors: [color(c, 0.9), color(c, 0.25), color(c, 0)] as CFArray,
                               locations: [0, 0.35, 1])!
            ctx.drawRadialGradient(g, startCenter: point, startRadius: 0, endCenter: point, endRadius: size * unit * 4, options: [])
            ctx.setFillColor(color(c.mixed(with: RGB(0xffffff), 0.35)))
            let r = size * unit
            ctx.fillEllipse(in: CGRect(x: point.x - r, y: point.y - r, width: r * 2, height: r * 2))
        }
        ctx.restoreGState()

        // A central star.
        glow(p.fg, 0.6, 0.45, 0.06, 0.55)
        glow(p.accent, 0.6, 0.45, 0.18, 0.3)

        // Darker edges keep icons and windows readable.
        let vignette = CGGradient(colorsSpace: space, colors: [color(p.bgDark, 0), color(p.bgDark, 0.55)] as CFArray, locations: [0.55, 1])!
        let middle = CGPoint(x: w / 2, y: h / 2)
        ctx.drawRadialGradient(vignette, startCenter: middle, startRadius: 0, endCenter: middle, endRadius: hypot(w, h) / 2, options: [])
        return ctx.makeImage()
    }
}
