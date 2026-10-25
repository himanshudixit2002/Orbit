import Foundation
import Testing
@testable import OrbitCore

/// Reads a file captured from this Mac before Orbit existed.
func fixture(_ name: String) throws -> String {
    let url = try #require(Bundle.module.resourceURL?.appending(path: "Fixtures/\(name)"))
    return try String(contentsOf: url, encoding: .utf8)
}

func lines(_ text: String, starting prefix: String) -> [String] {
    text.split(separator: "\n").map(String.init).filter { $0.hasPrefix(prefix) }
}

@Suite struct YabaiConfigTests {
    @Test func defaultsKeepEveryTilingSettingFromBeforeOrbit() throws {
        let before = try fixture("yabairc")
        let generated = YabaiConfig.render(OrbitSettings(), barReserved: 40)
        #expect(lines(generated, starting: "yabai -m config") == lines(before, starting: "yabai -m config"))
        #expect(lines(generated, starting: "yabai -m signal") == lines(before, starting: "yabai -m signal"))
        #expect(lines(generated, starting: "refocus=") == lines(before, starting: "refocus="))
    }

    @Test func floatingAppsKeepTheOldListAndAddOrbit() throws {
        let before = try fixture("yabairc")
        func floating(_ text: String) -> Set<String> {
            // Before Orbit the rule had no label; Orbit names it so it can change it live.
            guard let line = lines(text, starting: "yabai -m rule --add").first(where: { $0.contains("app=\"^(") }),
                  let open = line.range(of: "^("), let close = line.range(of: ")$") else { return [] }
            return Set(line[open.upperBound..<close.lowerBound].split(separator: "|").map(String.init))
        }
        let old = floating(before)
        let new = floating(YabaiConfig.render(OrbitSettings(), barReserved: 40))
        #expect(old.isSubset(of: new))
        #expect(new.subtracting(old) == ["Orbit"])
    }

    @Test func barOffFreesTheTopOfTheScreen() {
        let text = YabaiConfig.render(OrbitSettings(), barReserved: nil)
        #expect(text.contains("external_bar          all:0:0"))
    }

    @Test func liveSettingsReachTheFile() {
        var settings = OrbitSettings()
        settings.tiling = TilingSettings()
        settings.tiling.layout = .stack
        settings.tiling.gap = 4
        settings.tiling.padding = 20
        let text = YabaiConfig.render(settings, barReserved: 40)
        #expect(text.contains("yabai -m config layout                stack"))
        #expect(text.contains("yabai -m config window_gap            4"))
        #expect(text.contains("yabai -m config top_padding           20"))
    }

    @Test func appNamesAreEscapedForTheRegex() {
        var settings = OrbitSettings()
        settings.floatingApps = ["Plain", "C++ (beta)"]
        #expect(YabaiConfig.render(settings, barReserved: nil).contains(#"app="^(Plain|C\+\+ \(beta\))$""#))
    }
}

@Suite struct BordersConfigTests {
    @Test func defaultsMatchTheGlowFromBeforeOrbit() throws {
        let before = try fixture("bordersrc")
        let oldOptions = before.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.contains("=") && !$0.hasPrefix("#") && !$0.hasPrefix("options") }
            .map { $0.replacingOccurrences(of: "\"", with: "") }
        #expect(BordersConfig.options(GlowSettings(), palette: .tokyoNight) == oldOptions)
    }

    @Test func plainColourWhenGlowIsOff() {
        var glow = GlowSettings()
        glow.glow = false
        glow.useThemeColor = false
        glow.customColor = RGB(0xff0000)
        glow.width = 3
        let options = BordersConfig.options(glow, palette: .tokyoNight)
        #expect(options.contains("active_color=0xffff0000"))
        #expect(options.contains("width=3.0"))
    }

    @Test func renderedFileQuotesTheValuesBashNeedsQuoted() {
        let text = BordersConfig.render(GlowSettings(), palette: .tokyoNight)
        #expect(text.contains(#"  active_color="glow(0xff7aa2f7)""#))
        #expect(text.contains(#"  blacklist="uihost,Raycast""#))
        #expect(text.contains("  hidpi=on\n"))
    }
}

@Suite struct SketchyBarConfigTests {
    @Test func tokyoNightColoursMatchTheBarFromBeforeOrbit() throws {
        let before = try fixture("sketchybar-colors.sh")
        #expect(lines(SketchyBarConfig.colors(.tokyoNight), starting: "export") == lines(before, starting: "export"))
    }

    @Test func everyItemIsThereByDefault() {
        let rc = SketchyBarConfig.rc(BarSettings())
        for item in ["apple", "space.$i", "front_app", "spotify", "clock", "wifi", "volume", "memory", "cpu"] {
            #expect(rc.contains("--add item \(item) ") || rc.contains("--add space \(item) "), "missing \(item)")
        }
        #expect(rc.contains("--add bracket stats cpu memory volume wifi"))
        #expect(rc.contains("click_script=\"open orbit://panel\""))
    }

    @Test func hiddenItemsAreLeftOut() {
        var bar = BarSettings()
        bar.showCPU = false
        bar.showSpotify = false
        let rc = SketchyBarConfig.rc(bar)
        #expect(!rc.contains("--add item cpu"))
        #expect(!rc.contains("spotify"))
        #expect(rc.contains("--add bracket stats memory volume wifi"))
    }

    @Test func noStatsMeansNoBracket() {
        var bar = BarSettings()
        (bar.showCPU, bar.showMemory, bar.showVolume, bar.showNetwork) = (false, false, false, false)
        #expect(!SketchyBarConfig.rc(bar).contains("bracket"))
    }

    @Test func pluginsCoverEveryScriptTheBarCalls() {
        let rc = SketchyBarConfig.rc(BarSettings())
        let called = Set(rc.matches(of: /\$PLUGINS\/([a-z_]+\.sh)/).map { String($0.1) })
        #expect(called.isSubset(of: Set(SketchyBarConfig.plugins.keys)))
    }
}

@Suite struct KarabinerTests {
    @Test func replacesTheOldRulesWithOrbitsOwn() throws {
        let before = Data(try fixture("karabiner.json").utf8)
        let after = try KarabinerConfig.patched(before, settings: KeyboardSettings())
        let text = String(decoding: after, as: UTF8.self)
        #expect(text.contains(KarabinerConfig.capsLockDescription))
        #expect(text.contains(KarabinerConfig.hyperAppsDescription))
        #expect(!text.contains("\"Hyper + letter opens an app\""))
        #expect(KarabinerConfig.capsLockActive(in: after))
        #expect(KarabinerConfig.capsLockActive(in: before))
    }

    @Test func patchingTwiceChangesNothing() throws {
        let before = Data(try fixture("karabiner.json").utf8)
        let once = try KarabinerConfig.patched(before, settings: KeyboardSettings())
        let twice = try KarabinerConfig.patched(once, settings: KeyboardSettings())
        #expect(once == twice)
    }

    @Test func rulesAddedInKarabinerAreKept() throws {
        let mine: [String: Any] = ["description": "My own rule", "manipulators": []]
        let config: [String: Any] = ["profiles": [["name": "Default profile", "selected": true,
                                                   "complex_modifications": ["rules": [mine]]]]]
        let data = try JSONSerialization.data(withJSONObject: config)
        let off = KeyboardSettings.off
        let patched = try KarabinerConfig.patched(data, settings: off)
        #expect(String(decoding: patched, as: UTF8.self).contains("My own rule"))
        #expect(!KarabinerConfig.capsLockActive(in: patched))
    }

    @Test func launchesByBundleIDWhenKnown() {
        #expect(KarabinerConfig.launchCommand(HyperBinding(key: "t", appName: "Warp", appPath: "", bundleID: "dev.warp.Warp-Stable"))
                == "open -b dev.warp.Warp-Stable")
        #expect(KarabinerConfig.launchCommand(HyperBinding(key: "b", appName: "Google Chrome", appPath: ""))
                == "open -a 'Google Chrome'")
    }

    @Test func worksWithoutAnExistingFile() throws {
        let data = try KarabinerConfig.patched(nil, settings: KeyboardSettings())
        #expect(KarabinerConfig.capsLockActive(in: data))
    }

    @Test func leavesABrokenFileAlone() {
        #expect(throws: KarabinerConfig.Unreadable.self) {
            try KarabinerConfig.patched(Data("{ \"profiles\": [ oops".utf8), settings: KeyboardSettings())
        }
    }
}

extension KeyboardSettings {
    static var off: KeyboardSettings {
        var settings = KeyboardSettings()
        settings.capsLockEnabled = false
        return settings
    }
}

@Suite struct ConfigQuotingTests {
    /// An app name that would break out of naive quoting. Its payloads only print, so a failure is harmless.
    let tricky = #"Tom's "Mac" $(echo broke) `echo out` C++ \ end"#

    /// What a shell makes of `words`: its first word after expansion, exactly as a program would receive it.
    func firstWord(_ words: String, shell: String = "/bin/sh") throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-c", "set -- \(words); printf '%s' \"$1\""]
        let out = Pipe()
        process.standardOutput = out
        try process.run()
        process.waitUntilExit()
        return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }

    @Test func tilingRulesKeepAppNamesLiteral() throws {
        var settings = OrbitSettings()
        settings.floatingApps = [tricky]
        let rc = YabaiConfig.render(settings, barReserved: nil)
        let rule = try #require(rc.split(separator: "\n").first { $0.hasPrefix("yabai -m rule --add label=orbit-floating app=\"^(") })
        let argument = String(rule.dropFirst("yabai -m rule --add label=orbit-floating ".count))
        #expect(try firstWord(argument) == "app=^(" + Shell.regexEscape(tricky) + ")$")
    }

    @Test func glowSettingsKeepAppNamesLiteral() throws {
        var glow = GlowSettings()
        glow.ignoredApps = ["uihost", tricky]
        let rc = BordersConfig.render(glow, palette: Palette.named(.tokyoNight))
        let line = try #require(rc.split(separator: "\n").first { $0.contains("blacklist=") })
        #expect(try firstWord(line.trimmingCharacters(in: .whitespaces)) == "blacklist=uihost," + tricky)
    }
}
