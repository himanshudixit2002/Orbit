import Foundation
@testable import OrbitCore
import Testing

@Suite struct ProfileTests {
    @Test func aProfileTravelsWithoutTheLinkToken() throws {
        var settings = OrbitSettings()
        settings.tiling.gap = 20
        let karabiner = #"{"shell_command": "open 'orbit://toggle/tiling?token=secret123'"}"#
        let profile = OrbitProfile.make(settings: settings, files: [.karabiner: karabiner, .yabairc: "yabai -m config window_gap 20\n"],
                                        edited: [.yabairc], token: "secret123", date: Date(timeIntervalSince1970: 1_761_400_000))
        let data = try profile.encoded()
        #expect(!String(decoding: data, as: UTF8.self).contains("secret123"))
        let read = try OrbitProfile.decode(data)
        #expect(read == profile)
        #expect(read.settings.tiling.gap == 20)
        #expect(read.files["karabiner"]?.contains(OrbitProfile.tokenPlaceholder) == true)
        #expect(read.editedText(.yabairc, token: "mine") == "yabai -m config window_gap 20\n")
        #expect(read.editedText(.karabiner, token: "mine") == nil)
    }

    @Test func thisMacKeepsWhatsItsOwn() {
        var theirs = OrbitSettings()
        theirs.setupCompleted = false
        theirs.openAtLogin = false
        theirs.themeSync.accent = true
        theirs.doctorIgnored = ["their-finding"]
        theirs.theme = .nord
        var mine = OrbitSettings()
        mine.setupCompleted = true
        mine.openAtLogin = true
        mine.doctorIgnored = ["mine"]
        let next = OrbitProfile(settings: theirs, files: [:], edited: []).settings(keepingLocal: mine)
        #expect(next.theme == .nord)
        #expect(next.setupCompleted && next.openAtLogin == true && !next.themeSync.accent && next.doctorIgnored == ["mine"])
        #expect(OrbitProfile(settings: theirs, files: [:], edited: []).changedSettings(from: mine) == ["theme"])
    }

    @Test func aNewerFormatIsTurnedAwayAndOlderSettingsLoad() throws {
        let newer = Data(#"{"format": 9, "exported": "2026-10-25T10:00:00Z", "settings": {}}"#.utf8)
        #expect(throws: OrbitProfile.TooNew.self) { try OrbitProfile.decode(newer) }
        let older = Data(#"{"format": 1, "exported": "2026-10-25T10:00:00Z", "settings": {"theme": "dracula"}}"#.utf8)
        let profile = try OrbitProfile.decode(older)
        #expect(profile.settings.theme == .dracula && profile.settings.bar == BarSettings() && profile.files.isEmpty)
    }

    @Test func settingsHaveNamesAndFiles() {
        #expect(OrbitProfile.title(ofSetting: "bar") == "Menu bar")
        #expect(OrbitProfile.files(forSetting: "glow") == [.bordersrc])
        #expect(OrbitProfile.files(forSetting: "modes").isEmpty)
    }
}
