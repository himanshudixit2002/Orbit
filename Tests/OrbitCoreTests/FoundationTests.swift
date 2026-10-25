import Foundation
@testable import OrbitCore
import Testing

@Suite struct SettingsCompatibilityTests {
    @Test func listsSavedByAnyOrbitStillLoad() throws {
        // A mode without fields a newer Orbit added, and with one it doesn't know; a Hyper key the same.
        let saved = """
        {"version": 1, "theme": "nord",
         "modes": [{"id": "study", "name": "Study", "symbol": "book", "blurb": "", "openApps": ["Notes"],
                    "quitApps": [], "hideOthers": true, "keepAwake": "system", "futureField": 42}],
         "keyboard": {"capsLockEnabled": true, "hyperApps": [{"key": "x", "appName": "Xcode", "appPath": "/Applications/Xcode.app"}]}}
        """
        let settings = try OrbitSettings.decode(Data(saved.utf8))
        #expect(settings.version == 2)
        #expect(settings.theme == .nord)
        #expect(settings.modes.map(\.id) == ["study"])
        #expect(settings.modes[0].tilingOn == false && settings.modes[0].openApps == ["Notes"])
        #expect(settings.keyboard.hyperApps.first?.appName == "Xcode")
    }

    @Test func undoPutsBackAnySettingIncludingModes() {
        var before = OrbitSettings()
        before.theme = .dracula
        var after = before
        after.modes.removeAll { $0.id == "chill" }
        after.bar.height = 40
        let undo = SettingsUndo(before: before, after: after)
        #expect(undo.changedFields == ["bar", "modes"])
        var later = after
        later.theme = .nord   // changed since by something else: stays
        undo.apply(to: &later)
        #expect(later.modes.map(\.id) == before.modes.map(\.id))
        #expect(later.bar.height == 34)
        #expect(later.theme == .nord)
    }

    @Test func historyWrittenByOrbitOneStillUndoes() throws {
        let legacy = #"{"theme": "dracula", "tiling": {"layout": "stack", "gap": 4, "padding": 6}}"#
        let undo = try JSONDecoder().decode(SettingsUndo.self, from: Data(legacy.utf8))
        #expect(undo.changedFields == ["theme", "tiling"])
        var settings = OrbitSettings()
        undo.apply(to: &settings)
        #expect(settings.theme == .dracula && settings.tiling.layout == .stack && settings.tiling.gap == 4)
        // And it's written back in the new form.
        let again = try JSONDecoder().decode(SettingsUndo.self, from: JSONEncoder().encode(undo))
        #expect(again == undo)
    }
}

@Suite struct JSONKeyPatchTests {
    let editorSettings = """
    {
        // Theme and fonts
        "workbench.colorTheme": "Default Dark Modern",
        "editor.fontSize": 14, /* bigger later */
        "files.exclude": {
            "**/.git": true, // keep this
        },
    }
    """

    @Test func aKeyChangesAndEverythingElseStays() throws {
        let result = try JSONKeyPatch.apply(["workbench.colorTheme": .set(.string("Tokyo Night"))], to: editorSettings)
        #expect(result.text == editorSettings.replacingOccurrences(of: "\"Default Dark Modern\"", with: "\"Tokyo Night\""))
        #expect(result.before == ["workbench.colorTheme": .string("Default Dark Modern")])
        #expect(result.absent.isEmpty)
    }

    @Test func aNewKeyGoesInAtTheTopAndComesOutAgain() throws {
        let added = try JSONKeyPatch.apply(["workbench.preferredDarkColorTheme": .set(.string("Nord"))], to: editorSettings)
        #expect(added.absent == ["workbench.preferredDarkColorTheme"])
        #expect(added.text.hasPrefix("{\n    \"workbench.preferredDarkColorTheme\": \"Nord\",\n    // Theme and fonts"))
        let removed = try JSONKeyPatch.apply(["workbench.preferredDarkColorTheme": .remove], to: added.text)
        #expect(removed.text == editorSettings)
    }

    @Test func removingTheLastKeyLeavesStrictJSON() throws {
        let plain = "{\n  \"a\": 1,\n  \"b\": [1, 2]\n}\n"
        let result = try JSONKeyPatch.apply(["b": .remove], to: plain)
        #expect(result.text == "{\n  \"a\": 1\n}\n")
        #expect(result.before == ["b": .array([.int(1), .int(2)])])
        #expect(try JSONSerialization.jsonObject(with: Data(result.text.utf8)) is [String: Any])
    }

    @Test func emptyAndMissingFilesGetTheKey() throws {
        #expect(try JSONKeyPatch.apply(["a": .set(.bool(true))], to: "").text == "{\n    \"a\": true\n}\n")
        #expect(try JSONKeyPatch.apply(["a": .set(.bool(true))], to: "{}").text == "{\n    \"a\": true\n}")
    }

    @Test func somethingThatIsntJSONIsLeftAlone() {
        #expect(throws: JSONKeyPatch.Unreadable.self) { try JSONKeyPatch.apply(["a": .set(.int(1))], to: "theme = dark") }
        #expect(throws: JSONKeyPatch.Unreadable.self) { try JSONKeyPatch.apply(["a": .set(.int(1))], to: "{ \"a\": 1") }
    }

    @Test func keysWithEscapesAreFoundExactly() throws {
        let text = #"{"say \"hi\"": "x", "say": "y"}"#
        let result = try JSONKeyPatch.apply(["say": .set(.string("z"))], to: text)
        #expect(result.text == #"{"say \"hi\"": "x", "say": "z"}"#)
    }
}

@Suite struct LinkTokenTests {
    @Test func changesCarryTheTokenAndShowingDoesnt() {
        #expect(OrbitLink.url(for: .toggleFeature(.tiling), token: "abc")?.absoluteString == "orbit://toggle/tiling?token=abc")
        #expect(OrbitLink.url(for: .open(.page(.home)), token: "abc")?.absoluteString == "orbit://page/home")
        let url = URL(string: "orbit://on/glow?token=abc")!
        #expect(OrbitLink.token(in: url) == "abc")
        #expect(OrbitLink.command(from: url) == .setFeature(.glow, on: true))
        #expect(OrbitCommand.setFeature(.menuBar, on: false).summary == "turn off the new menu bar")
    }
}
