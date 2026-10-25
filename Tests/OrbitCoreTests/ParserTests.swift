import Foundation
import Testing
@testable import OrbitCore

@Suite struct ParserTests {
    @Test func loadedButIdleAgent() throws {
        let result = CommandResult(status: 0, stdout: try fixture("launchctl-print-sorter.txt"), ok: true)
        guard case .loaded(let running, let pid, _) = LaunchctlParser.run(result) else {
            Issue.record("expected a loaded agent")
            return
        }
        #expect(!running)
        #expect(pid == nil)
        #expect(LaunchctlParser.run(result).isLoaded)
        #expect(!LaunchctlParser.run(result).isRunning)
    }

    @Test func missingAgent() throws {
        let result = CommandResult(status: 113, stderr: try fixture("launchctl-print-missing.txt"), ok: true)
        #expect(LaunchctlParser.run(result) == .notLoaded)
    }

    @Test func runningAgent() {
        let text = "gui/501/sh.brew.borders = {\n\tstate = running\n\tpid = 751\n\tlast exit code = (never exited)\n}"
        #expect(LaunchctlParser.run(CommandResult(status: 0, stdout: text, ok: true)) == .loaded(running: true, pid: 751, lastExit: nil))
    }

    @Test func nestedStateLinesDontHideARunningAgent() {
        // Real output from this Mac: endpoint sections repeat "state = active" after the service's own state.
        let text = """
        gui/501/sh.brew.borders = {
        \tstate = running
        \tprogram = /opt/homebrew/opt/borders/bin/borders
        \tpid = 751
        \tendpoints = {
        \t\t"git.felix.borders" = {
        \t\t\tport = 0x1234
        \t\t\tstate = active
        \t\t}
        \t}
        \tevent triggers = {
        \t\tstate = active
        \t}
        }
        """
        #expect(LaunchctlParser.run(CommandResult(status: 0, stdout: text, ok: true)).isRunning)
    }

    @Test func disabledList() {
        let text = "disabled services = {\n\t\"com.asmvik.yabai\" => disabled\n\t\"com.foo\" => enabled\n\t\"com.old\" => true\n}"
        let parsed = LaunchctlParser.disabled(text)
        #expect(parsed["com.asmvik.yabai"] == true)
        #expect(parsed["com.foo"] == false)
        #expect(parsed["com.old"] == true)
    }

    @Test func brewServices() throws {
        let services = BrewServiceInfo.parse(Data(try fixture("brew-services.json").utf8))
        #expect(services.first { $0.name == "borders" }?.running == true)
        #expect(services.first { $0.name == "sketchybar" }?.running == false)
        #expect(services.first { $0.name == "borders" }?.serviceName == "sh.brew.borders")
    }

    @Test func sorterLog() throws {
        let log = SorterLog.parse(try fixture("sort-downloads.log"))
        #expect(log.entries.count == 3)
        #expect(log.entries.map(\.folder) == ["Documents", "Documents", "Archives"])
        #expect(log.lastError != nil)
        #expect(!log.isBlocked(), "files were sorted after the old permission error")
    }

    @Test func sorterBlockedWhenTheErrorIsNewest() {
        let text = "2026-10-25 10:00:00  a.pdf -> Documents/a.pdf\n2026-10-25 11:00:00  cannot read /Users/x/Downloads: give zsh access"
        #expect(SorterLog.parse(text).isBlocked())
    }

    @Test func sorterNotBlockedOnceItGetsInAgain() throws {
        let text = "2026-10-25 11:00:00  cannot read /Users/x/Downloads: give zsh access"
        let log = SorterLog.parse(text)
        let error = try #require(log.lastError).date
        // Permission granted, then a run with nothing to sort: no new log line, but a fresh mark.
        #expect(!log.isBlocked(checkedAt: error.addingTimeInterval(3600)))
        #expect(log.isBlocked(checkedAt: error.addingTimeInterval(-3600)))
    }

    @Test func karabinerDriver() throws {
        #expect(SystemExtensionsParser.karabiner(try fixture("systemextensionsctl.txt")) == .missing)
        let enabled = "*\t*\tG43BCU2T37\torg.pqrs.Karabiner-DriverKit-VirtualHIDDevice (1.8.0/1.8.0)\tKarabiner\t[activated enabled]"
        #expect(SystemExtensionsParser.karabiner(enabled) == .enabled)
        let waiting = "\t\tG43BCU2T37\torg.pqrs.Karabiner-DriverKit-VirtualHIDDevice (1.8.0/1.8.0)\tKarabiner\t[activated waiting for user]"
        #expect(SystemExtensionsParser.karabiner(waiting) == .waitingForApproval)
    }

    @Test func quickLook() throws {
        #expect(PluginKitParser.parse(try fixture("pluginkit-syntax.txt")) == .notRegistered)
        #expect(PluginKitParser.parse("+    org.sbarex.SourceCodeSyntaxHighlight.QuickLookExtension(2.1.32)") == .enabled)
        #expect(PluginKitParser.parse("-    org.sbarex.SourceCodeSyntaxHighlight.QuickLookExtension(2.1.32)") == .disabled)
    }

    @Test func helperMessages() {
        #expect(HelperLogClassifier.classify("yabai: could not access accessibility features! abort..") == .needsAccessibility)
        #expect(HelperLogClassifier.classify("skhd: must be run with accessibility access! abort..") == .needsAccessibility)
        #expect(HelperLogClassifier.classify("skhd: secure keyboard entry is enabled by (512) '1Password'! abort..")
                == .secureInput(app: "1Password"))
        #expect(HelperLogClassifier.classify("yabai: 'display has separate spaces' is disabled! abort..") == .separateSpacesOff)
        #expect(HelperLogClassifier.classify("yabai: could not acquire lock-file! abort..") == .duplicate)
        #expect(HelperLogClassifier.classify("all good") == nil)
    }
}

@Suite struct SettingsTests {
    @Test func oldSettingsFillInNewKeys() throws {
        let saved = #"{"theme":"nord","tiling":{"gap":4}}"#
        let settings = try OrbitSettings.decode(Data(saved.utf8))
        #expect(settings.theme == .nord)
        #expect(settings.tiling.gap == 4)
        #expect(settings.tiling.padding == 12)
        #expect(settings.bar == BarSettings())
    }

    @Test func roundTrip() throws {
        var settings = OrbitSettings()
        settings.glow.width = 4
        settings.keyboard.hyperApps.removeLast()
        #expect(try OrbitSettings.decode(settings.encoded()) == settings)
    }

    @Test func everyThemeIsReadable() {
        for palette in Palette.all {
            #expect(palette.fg.contrast(with: palette.bg) >= 4.5, "\(palette.name) text")
            #expect(palette.accent.contrast(with: palette.bgDark) >= 3, "\(palette.name) glow")
            #expect(palette.muted.contrast(with: palette.bgDark) >= 2.5, "\(palette.name) dim text")
        }
    }

    @Test func shellQuoting() {
        #expect(Shell.quote("plain-file_1.txt") == "plain-file_1.txt")
        #expect(Shell.quote("Google Chrome") == "'Google Chrome'")
        #expect(Shell.quote("it's") == #"'it'\''s'"#)
    }
}
