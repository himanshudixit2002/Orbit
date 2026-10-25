import Foundation
@testable import OrbitCore
import Testing

@Suite struct DoctorRulesTests {
    func app(_ name: String, version: String, days: Double, running: Bool = false) -> DoctorFacts.AppCopy {
        DoctorFacts.AppCopy(name: name, path: "/Applications/\(name).app", bundleID: "com.google.antigravity", version: version,
                            modified: Date(timeIntervalSince1970: days * 86_400), size: 410_000_000, running: running)
    }

    @Test func eachProblemOnThisMacIsFound() {
        var facts = DoctorFacts()
        facts.capsLockOn = true
        facts.missingHyperApps = [HyperBinding(key: "p", appName: "Postman", appPath: "/Applications/Postman.app")]
        facts.apps = [app("Antigravity", version: "2.26.0", days: 300), app("Antigravity 2", version: "2.3.1", days: 200)]
        facts.launchAgents = [
            DoctorFacts.LaunchAgent(path: "/u/Library/LaunchAgents/com.google.keystone.agent.plist", label: nil, program: nil, programExists: false),
            DoctorFacts.LaunchAgent(path: "/u/Library/LaunchAgents/com.google.keystone.xpcservice.plist", label: nil, program: nil, programExists: false)
        ]
        facts.servicesAtLogin = [DoctorFacts.Service(formula: "mongodb-community", memory: 42_000_000),
                                 DoctorFacts.Service(formula: "sketchybar", memory: 17_000_000)]
        facts.tmuxManagerInstalled = true
        facts.tmuxPluginsMissing = ["tmux-sensible", "tmux-resurrect"]
        facts.projectsNotInGit = ["Products/Vitals", "Sip"]
        facts.cheatSheetStale = true
        let found = Doctor.findings(facts)
        #expect(found.map(\.title) == [
            "Caps Lock + P opens Postman, which isn't installed",
            "tmux's plugins were never installed",
            "2 empty login items are left over",
            "Antigravity 2 is an older copy of Antigravity",
            "2 projects aren't in git",
            "MongoDB starts at every login",
            "The shortcut cheat sheet is out of date"
        ])
        #expect(found.first?.fix == .removeHyperKey("p"))
        #expect(found.first { $0.title.hasPrefix("Antigravity 2") }?.fix == .trash(["/Applications/Antigravity 2.app"]))
        #expect(found.first { $0.title.hasPrefix("MongoDB") }?.detail.contains("42 MB") == true)
        // Orbit's own services are meant to start at login.
        #expect(!found.contains { $0.title.contains("sketchybar") })
    }

    @Test func ignoredFindingsStayHiddenAndRunningCopiesAreLeftAlone() {
        var facts = DoctorFacts()
        facts.apps = [app("Antigravity", version: "2.26.0", days: 300), app("Antigravity 2", version: "2.3.1", days: 200, running: true)]
        facts.projectsNotInGit = ["Sip"]
        #expect(Doctor.findings(facts).map(\.id) == ["not-in-git"])
        #expect(Doctor.findings(facts, ignored: ["not-in-git"]).isEmpty)
        // Caps Lock superpowers off: its shortcuts don't matter.
        facts.missingHyperApps = [HyperBinding(key: "p", appName: "Postman", appPath: "/x")]
        #expect(!Doctor.findings(facts).contains { $0.id == "hyper-p" })
    }

    @Test func tmuxPluginsAreReadFromTheConf() {
        let conf = """
        set -g @plugin 'tmux-plugins/tpm'
        set -g @plugin "tmux-plugins/tmux-yank"          # copy
        # set -g @plugin 'tmux-plugins/old-one'
        set-option -g @plugin 'catppuccin/tmux'
        set -g mouse on
        """
        #expect(TmuxPlugins.declared(in: conf) == ["tpm", "tmux-yank", "tmux"])
    }
}

@Suite struct CheatSheetTests {
    let sheet = """
    WINDOW TILING CHEAT SHEET            (⌥ = option key)
    =====================================================

    TERMINAL       ⌥ return               open Warp

    CAPS LOCK      tap                    Escape
    HYPER          hold Caps Lock + …     T Warp      B Chrome
                                          P Postman

    MOUSE          hold ⌥ + drag          move
    """

    @Test func onlyTheCapsLockParagraphIsRewritten() {
        let bindings = [HyperBinding(key: "t", appName: "Warp", appPath: ""), HyperBinding(key: "b", appName: "Google Chrome", appPath: ""),
                        HyperBinding(key: "i", appName: "Antigravity IDE", appPath: ""), HyperBinding(key: "o", appName: "Orbit", appPath: "")]
        let block = CheatSheet.block(capsLock: true, bindings: bindings, palette: .standard,
                                     extras: [CheatSheet.Extra(keys: "⌘⇧ 0", does: "opens cursor")])
        #expect(block == [
            "CAPS LOCK      tap                    Escape",
            "HYPER          hold Caps Lock + …     T Warp       B Chrome     I Antigravity",
            "                                      O Orbit",
            "ORBIT          Caps Lock + space      command palette (⌘K in Orbit)",
            "               ⌘⇧ 0                   opens cursor"
        ])
        let updated = CheatSheet.update(sheet, block: block)
        #expect(updated.hasPrefix("WINDOW TILING CHEAT SHEET"))
        #expect(updated.contains("TERMINAL       ⌥ return               open Warp"))
        #expect(updated.hasSuffix("\n\nMOUSE          hold ⌥ + drag          move"))
        #expect(!updated.contains("Postman"))
        #expect(CheatSheet.update(updated, block: block) == updated)
    }

    @Test func aSheetWithoutTheParagraphGetsItAtTheEnd() {
        let block = CheatSheet.block(capsLock: false, bindings: [], palette: nil)
        #expect(CheatSheet.update("MY NOTES\n", block: block) == "MY NOTES\n\nCAPS LOCK                             plain Caps Lock (superpowers are off in Orbit)\n")
        #expect(CheatSheet.update(nil, block: block).hasPrefix("KEYBOARD CHEAT SHEET"))
    }
}
