import Foundation

/// An sRGB colour as the config files spell it.
public struct RGB: Sendable, Hashable, Codable {
    public let r: UInt8
    public let g: UInt8
    public let b: UInt8

    public init(_ hex: UInt32) {
        r = UInt8((hex >> 16) & 0xFF)
        g = UInt8((hex >> 8) & 0xFF)
        b = UInt8(hex & 0xFF)
    }

    public init(r: UInt8, g: UInt8, b: UInt8) {
        self.r = r
        self.g = g
        self.b = b
    }

    /// `#7aa2f7`
    public var hex: String { String(format: "#%02x%02x%02x", r, g, b) }

    /// `0xff7aa2f7`, the format JankyBorders and SketchyBar use.
    public func argb(_ alpha: UInt8 = 0xFF) -> String { String(format: "0x%02x%02x%02x%02x", alpha, r, g, b) }

    /// `38;2;122;162;247`, a 24-bit terminal foreground.
    public var ansi: String { "38;2;\(r);\(g);\(b)" }

    public var red: Double { Double(r) / 255 }
    public var green: Double { Double(g) / 255 }
    public var blue: Double { Double(b) / 255 }

    /// Relative luminance (WCAG).
    public var luminance: Double {
        func channel(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * channel(red) + 0.7152 * channel(green) + 0.0722 * channel(blue)
    }

    public func contrast(with other: RGB) -> Double {
        let (a, b) = (luminance, other.luminance)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    public func mixed(with other: RGB, _ t: Double) -> RGB {
        func mix(_ a: UInt8, _ b: UInt8) -> UInt8 { UInt8((Double(a) + (Double(b) - Double(a)) * t).rounded()) }
        return RGB(r: mix(r, other.r), g: mix(g, other.g), b: mix(b, other.b))
    }
}

public enum ThemeID: String, Codable, CaseIterable, Sendable, Identifiable {
    case tokyoNight, catppuccin, dracula, nord, rosePine, sunset

    public var id: String { rawValue }
}

/// A colour scheme, described by role so every tool can use it the same way.
public struct Palette: Sendable, Equatable, Identifiable {
    public let id: ThemeID
    public let name: String
    public let tagline: String
    public let bgDark: RGB    // deepest tone: bar background, wallpaper base
    public let bg: RGB        // editor and terminal background
    public let surface: RGB   // raised panels, the bar's stats pill
    public let line: RGB      // outlines of windows you're not using
    public let fg: RGB
    public let muted: RGB
    public let accent: RGB    // the glow and highlights
    public let accent2: RGB
    public let green: RGB
    public let yellow: RGB
    public let orange: RGB
    public let red: RGB
    public let cyan: RGB
    public let teal: RGB

    public static func named(_ id: ThemeID) -> Palette {
        all.first { $0.id == id } ?? tokyoNight
    }

    public static let all: [Palette] = [tokyoNight, catppuccin, dracula, nord, rosePine, sunset]

    public static let tokyoNight = Palette(
        id: .tokyoNight, name: "Tokyo Night", tagline: "Neon city lights after dark",
        bgDark: RGB(0x16161e), bg: RGB(0x1a1b26), surface: RGB(0x1f2335), line: RGB(0x414868),
        fg: RGB(0xc0caf5), muted: RGB(0x565f89), accent: RGB(0x7aa2f7), accent2: RGB(0xbb9af7),
        green: RGB(0x9ece6a), yellow: RGB(0xe0af68), orange: RGB(0xff9e64), red: RGB(0xf7768e),
        cyan: RGB(0x7dcfff), teal: RGB(0x73daca))

    public static let catppuccin = Palette(
        id: .catppuccin, name: "Catppuccin Mocha", tagline: "Soft pastels, warm and cosy",
        bgDark: RGB(0x11111b), bg: RGB(0x1e1e2e), surface: RGB(0x313244), line: RGB(0x45475a),
        fg: RGB(0xcdd6f4), muted: RGB(0x7f849c), accent: RGB(0xcba6f7), accent2: RGB(0x89b4fa),
        green: RGB(0xa6e3a1), yellow: RGB(0xf9e2af), orange: RGB(0xfab387), red: RGB(0xf38ba8),
        cyan: RGB(0x89dceb), teal: RGB(0x94e2d5))

    public static let dracula = Palette(
        id: .dracula, name: "Dracula", tagline: "Bold purple and pink",
        bgDark: RGB(0x191a21), bg: RGB(0x282a36), surface: RGB(0x343746), line: RGB(0x44475a),
        fg: RGB(0xf8f8f2), muted: RGB(0x7281b8), accent: RGB(0xbd93f9), accent2: RGB(0xff79c6),
        green: RGB(0x50fa7b), yellow: RGB(0xf1fa8c), orange: RGB(0xffb86c), red: RGB(0xff5555),
        cyan: RGB(0x8be9fd), teal: RGB(0x8be9fd))

    public static let nord = Palette(
        id: .nord, name: "Nord", tagline: "Cool arctic blues",
        bgDark: RGB(0x242933), bg: RGB(0x2e3440), surface: RGB(0x3b4252), line: RGB(0x4c566a),
        fg: RGB(0xeceff4), muted: RGB(0x7b88a1), accent: RGB(0x88c0d0), accent2: RGB(0x81a1c1),
        green: RGB(0xa3be8c), yellow: RGB(0xebcb8b), orange: RGB(0xd08770), red: RGB(0xbf616a),
        cyan: RGB(0x8fbcbb), teal: RGB(0x8fbcbb))

    public static let rosePine = Palette(
        id: .rosePine, name: "Rosé Pine", tagline: "Muted rose and gold",
        bgDark: RGB(0x12101c), bg: RGB(0x191724), surface: RGB(0x26233a), line: RGB(0x403d52),
        fg: RGB(0xe0def4), muted: RGB(0x908caa), accent: RGB(0xc4a7e7), accent2: RGB(0xebbcba),
        green: RGB(0x9ccfd8), yellow: RGB(0xf6c177), orange: RGB(0xebbcba), red: RGB(0xeb6f92),
        cyan: RGB(0x9ccfd8), teal: RGB(0x31748f))

    public static let sunset = Palette(
        id: .sunset, name: "Sunset", tagline: "Warm dusk glow",
        bgDark: RGB(0x140f1a), bg: RGB(0x1b1423), surface: RGB(0x2a1f36), line: RGB(0x4a3a5c),
        fg: RGB(0xf5e6f0), muted: RGB(0x9a86a6), accent: RGB(0xff8a5c), accent2: RGB(0xff5c8a),
        green: RGB(0x8fdc9a), yellow: RGB(0xffd166), orange: RGB(0xff9f43), red: RGB(0xff5c7a),
        cyan: RGB(0x6ad5ff), teal: RGB(0x5ce1c6))
}
