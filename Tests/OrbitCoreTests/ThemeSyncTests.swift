import Foundation
@testable import OrbitCore
import Testing

@Suite struct ThemeSyncTests {
    let userSettings = """
    {
        // my editor
        "editor.fontSize": 14,
        "workbench.colorCustomizations": {
            "statusBar.background": "#000000",
            "[Monokai]": { "editor.background": "#111111" }
        }
    }
    """

    @Test func theEditorsOwnThemeIsUsedWhenItHasOne() {
        let changes = EditorTheme.changes(.tokyoNight, installed: ["Tokyo Night", "Default Dark Modern"], current: [:])
        #expect(changes == [EditorTheme.themeKey: .set(.string("Tokyo Night"))])
    }

    @Test func otherwiseOrbitsColoursGoOverTheDarkThemeAndNothingElse() throws {
        let current = try JSONKeyPatch.values(EditorTheme.keys, in: userSettings)
        let changes = EditorTheme.changes(.sunset, installed: ["Tokyo Night"], current: current)
        #expect(changes[EditorTheme.themeKey] == .set(.string("Default Dark Modern")))
        guard case .set(let colors)? = changes[EditorTheme.colorsKey], let setting = colors.objectValue else {
            Issue.record("no colours")
            return
        }
        #expect(setting["statusBar.background"] == .string("#000000"))
        #expect(setting["[Monokai]"] == .object(["editor.background": .string("#111111")]))
        #expect(setting["[Default Dark Modern]"]?.objectValue?["editor.background"] == .string(Palette.sunset.bg.hex))

        // Switched on and off again, the file holds what it held, comments and all.
        let on = try JSONKeyPatch.apply(changes, to: userSettings).text
        let removal = EditorTheme.removal(orbitTheme: EditorTheme.base, before: nil, current: try JSONKeyPatch.values(EditorTheme.keys, in: on))
        let off = try JSONKeyPatch.apply(removal, to: on).text
        #expect(try JSONKeyPatch.values(EditorTheme.keys, in: off) == current)
        #expect(off.contains("// my editor"))
    }

    @Test func aThemeYouPickedYourselfIsLeftAlone() {
        let mine: [String: JSONValue] = [EditorTheme.themeKey: .string("Solarized Dark")]
        let orbits: [String: JSONValue] = [EditorTheme.themeKey: .string("Tokyo Night")]
        #expect(EditorTheme.removal(orbitTheme: "Tokyo Night", before: "Monokai", current: mine).isEmpty)
        #expect(EditorTheme.removal(orbitTheme: "Tokyo Night", before: "Monokai", current: orbits) == [EditorTheme.themeKey: .set(.string("Monokai"))])
        #expect(EditorTheme.removal(orbitTheme: "Tokyo Night", before: nil, current: orbits) == [EditorTheme.themeKey: .remove])
    }

    @Test func themeNamesComeFromExtensionManifests() {
        let manifest = Data(#"{"contributes":{"themes":[{"id":"Tokyo Night","label":"Tokyo Night"},{"label":"%themeLabel%"},{"label":"Nord"}]}}"#.utf8)
        #expect(EditorTheme.themeNames(inManifest: manifest) == ["Tokyo Night", "Nord"])
        #expect(EditorTheme.themeNames(inManifest: Data("{}".utf8)).isEmpty)
    }

    @Test func objectsAreWrittenOneEntryALineInTheFilesOwnIndent() throws {
        let text = try JSONKeyPatch.apply(["b": .set(.object(["z": .int(1), "a": .array([.string("x")])]))], to: "{\n    \"a\": 1\n}\n").text
        #expect(text == "{\n    \"b\": {\n        \"a\": [\n            \"x\"\n        ],\n        \"z\": 1\n    },\n    \"a\": 1\n}\n")
    }

    @Test func warpAndTheAccentFollowThePalette() {
        let warp = WarpTheme.render(.nord)
        #expect(warp.contains("name: Orbit"))
        #expect(warp.contains("background: '\(Palette.nord.bg.hex)'"))
        #expect(MacAccent.matching(.sunset) == .orange)
        #expect(MacAccent.matching(.dracula).rawValue == 5)
    }

    @Test func olderSettingsLoadWithThemeSyncOff() throws {
        let settings = try OrbitSettings.decode(Data(#"{"version": 2, "theme": "nord"}"#.utf8))
        #expect(settings.themeSync == ThemeSyncSettings())
        #expect(settings.theme == .nord)
    }
}
