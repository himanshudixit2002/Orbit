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

@Suite struct HyperActionTests {
    func binding(_ action: HyperAction, app: String = "", path: String = "", id: String? = nil) -> HyperBinding {
        var binding = HyperBinding(key: "k", appName: app, appPath: path, bundleID: id)
        binding.action = action
        return binding
    }

    @Test func eachKindOfKeyRunsTheRightCommand() {
        #expect(KarabinerConfig.launchCommand(binding(.app, app: "Warp", id: "dev.warp.Warp-Stable")) == "open -b dev.warp.Warp-Stable")
        #expect(KarabinerConfig.launchCommand(binding(.website("https://github.com/notifications"))) == "open https://github.com/notifications")
        #expect(KarabinerConfig.launchCommand(binding(.folder("/Users/me/Developer/Orbit"), app: "Antigravity IDE", id: "com.google.antigravity-ide"))
                == "open -b com.google.antigravity-ide /Users/me/Developer/Orbit")
        #expect(KarabinerConfig.launchCommand(binding(.folder("/tmp/My Project"))) == "open '/tmp/My Project'")
        let toggle = KarabinerConfig.launchCommand(binding(.orbit(.toggleFeature(.tiling)))) { OrbitLink.url(for: $0, token: "t0k")?.absoluteString }
        #expect(toggle == "open -g 'orbit://toggle/tiling?token=t0k'")
        #expect(binding(.orbit(.toggleFeature(.tiling))).label == "switch window tiling on or off")
        #expect(binding(.website("https://github.com/x")).label == "github.com")
    }

    @Test func theTapTimeoutIsWrittenAndOldKeysStillLoad() throws {
        var settings = KeyboardSettings()
        settings.tapTimeout = 225
        let data = try KarabinerConfig.patched(nil, settings: settings)
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let profile = try #require((root["profiles"] as? [[String: Any]])?.first)
        let parameters = (profile["complex_modifications"] as? [String: Any])?["parameters"] as? [String: Any]
        #expect(parameters?["basic.to_if_alone_timeout_milliseconds"] as? Int == 225)
        let old = #"{"key": "t", "appName": "Warp", "appPath": "/Applications/Warp.app"}"#
        #expect(try JSONDecoder().decode(HyperBinding.self, from: Data(old.utf8)).action == .app)
        let round = try JSONDecoder().decode(HyperBinding.self, from: JSONEncoder().encode(binding(.orbit(.stopMode))))
        #expect(round.action == .orbit(.stopMode))
    }

    @Test func tilingOptionsReachTheConfigAndDefaultsStayTheSame() {
        var settings = OrbitSettings()
        let plain = YabaiConfig.render(settings, barReserved: nil)
        #expect(plain.contains("window_placement      second_child") && plain.contains("split_ratio           0.50"))
        settings.tiling.newWindowsFirst = true
        settings.tiling.splitRatio = 0.6
        settings.tiling.autoBalance = true
        settings.tiling.focusFollowsMouse = .autofocus
        let text = YabaiConfig.render(settings, barReserved: nil)
        #expect(text.contains("window_placement      first_child"))
        #expect(text.contains("split_ratio           0.60"))
        #expect(text.contains("auto_balance          on"))
        #expect(text.contains("focus_follows_mouse   autofocus"))
        #expect(YabaiConfig.floatingPattern(["Calculator", "C++ (beta)"]) == #"^(Calculator|C\+\+ \(beta\))$"#)
    }
}
