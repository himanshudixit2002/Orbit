import Foundation
@testable import OrbitCore
import Testing

@Suite struct MenuBarV2Tests {
    @Test func theUsualLayoutIsTheBarFromBefore() {
        let bar = BarSettings()
        #expect(bar.items(on: .left) == [.spaces, .frontApp])
        #expect(bar.items(on: .center) == [.spotify])
        #expect(bar.items(on: .right) == [.cpu, .memory, .volume, .network, .clock])
    }

    @Test func itemsMoveAlongTheirSideAndToOthers() {
        var bar = BarSettings()
        bar.move(.cpu, by: 1)
        #expect(bar.items(on: .right) == [.memory, .cpu, .volume, .network, .clock])
        bar.move(.memory, by: -1)
        #expect(bar.items(on: .right).first == .memory)
        bar.setSide(.clock, .left)
        #expect(bar.items(on: .left) == [.spaces, .frontApp, .clock])
        bar.setShown(.disk, true)
        #expect(bar.items(on: .right) == [.disk, .memory, .cpu, .volume, .network])
    }

    @Test func numbersApartGetTheirOwnPill() {
        var bar = BarSettings()
        bar.move(.clock, by: -1)
        bar.move(.clock, by: -1)
        #expect(bar.items(on: .right) == [.cpu, .memory, .clock, .volume, .network])
        let rc = SketchyBarConfig.rc(bar)
        #expect(rc.contains("--add bracket stats cpu memory "))
        #expect(rc.contains("--add bracket stats2 volume wifi "))
    }

    @Test func rightSideItemsAreAddedRightToLeft() throws {
        let rc = SketchyBarConfig.rc(BarSettings())
        let clock = try #require(rc.range(of: "--add item clock right"))
        let cpu = try #require(rc.range(of: "--add item cpu right"))
        #expect(clock.lowerBound < cpu.lowerBound)
    }

    @Test func positionClockAndEmptyDesktopsReachTheBar() {
        var bar = BarSettings()
        bar.position = .bottom
        bar.clockFormat = .time12
        bar.hideEmptySpaces = true
        let rc = SketchyBarConfig.rc(bar)
        #expect(rc.contains("--bar position=bottom "))
        #expect(rc.contains(#"label="$(date "+%-I:%M %p")""#))
        #expect(rc.contains("--add item spaces_shown left"))
        bar.showSpaces = false
        #expect(!SketchyBarConfig.rc(bar).contains("spaces_shown"))
    }

    @Test func everyItemHasItsScript() {
        var bar = BarSettings()
        for item in BarItem.allCases { bar.setShown(item, true) }
        let rc = SketchyBarConfig.rc(bar)
        for name in ["mode", "git", "music", "services", "disk"] { #expect(rc.contains("--add item \(name) "), "missing \(name)") }
        #expect(rc.contains("--add bracket stats services disk cpu memory volume wifi "))
        let called = Set(rc.matches(of: /\$PLUGINS\/([a-z_]+\.sh)/).map { String($0.1) })
        #expect(called.isSubset(of: Set(SketchyBarConfig.plugins.keys)))
    }

    @Test func aLayoutFromANewerOrbitStillLoads() throws {
        let json = #"{"bar": {"layout": [{"item": "weather", "side": "left"}, {"item": "clock", "side": "left"}], "clockFormat": "fancy", "position": "bottom"}}"#
        let settings = try OrbitSettings.decode(Data(json.utf8))
        #expect(settings.bar.items(on: .left).first == .clock)
        #expect(settings.bar.items(on: .right) == [.cpu, .memory, .volume, .network])
        #expect(settings.bar.clockFormat == .dayDateTime)
        #expect(settings.bar.position == .bottom)
    }

    @Test func tilingKeepsRoomAtTheBarsEdgeAndNudgesForGit() {
        var settings = OrbitSettings()
        settings.bar.position = .bottom
        settings.bar.showGit = true
        let rc = YabaiConfig.render(settings, barReserved: 40)
        #expect(rc.contains("all:0:40"))
        #expect(rc.contains("Keep windows above the menu bar"))
        #expect(rc.contains(YabaiConfig.barFocusSignal))
        #expect(!YabaiConfig.render(settings, barReserved: nil).contains("window_focused"))
        #expect(settings.bar.externalBar(on: true) == "all:0:40")
        #expect(BarSettings().externalBar(on: true) == "all:40:0")
    }

    @Test func theModeIsFedByName() {
        var bar = BarSettings()
        bar.showMode = true
        let on = BarFeedValues(cpu: 10, memory: "8.1G", clock: "x", mode: "Focus")
        let off = BarFeedValues(cpu: 10, memory: "8.1G", clock: "x", mode: nil)
        #expect(BarFeed.command(on, last: nil, bar: bar, palette: .tokyoNight)?.arguments.joined(separator: " ").contains("--set mode drawing=on label=Focus") == true)
        #expect(BarFeed.command(off, last: on, bar: bar, palette: .tokyoNight)?.arguments == ["--set", "mode", "drawing=off"])
        #expect(BarFeed.command(on, last: on, bar: bar, palette: .tokyoNight) == nil)
        var quiet = BarSettings()
        (quiet.showCPU, quiet.showMemory, quiet.showClock) = (false, false, false)
        #expect(!BarFeed.feeds(quiet))
        quiet.showMode = true
        #expect(BarFeed.feeds(quiet))
    }

    @Test func theBarsClockAndOrbitsReadTheSame() throws {
        let seconds = 1_761_400_000
        for format in ClockFormat.allCases {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/date")
            process.arguments = ["-u", "-r", "\(seconds)", "+" + format.strftime]
            process.environment = ["LC_ALL": "C"]
            let pipe = Pipe()
            process.standardOutput = pipe
            try process.run()
            process.waitUntilExit()
            let shell = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .newlines)
            let orbit = BarFeed.clockLabel(Date(timeIntervalSince1970: TimeInterval(seconds)), format: format, timeZone: TimeZone(identifier: "UTC")!)
            #expect(shell == orbit, "\(format)")
        }
    }
}
