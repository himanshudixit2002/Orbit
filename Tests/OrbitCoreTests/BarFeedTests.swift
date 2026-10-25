import Foundation
@testable import OrbitCore
import Testing

@Suite struct BarFeedTests {
    let palette = OrbitSettings().palette
    let bar = BarSettings()

    @Test func theFirstUpdateSetsEveryItemAndSlowsItsScript() throws {
        let values = BarFeedValues(cpu: 95, memory: "8.1G", clock: "Sun 25 Oct  14:05")
        let command = try #require(BarFeed.command(values, last: nil, bar: bar, palette: palette))
        #expect(command.executable == Tool.sketchybar)
        #expect(command.effect == .display)
        #expect(command.arguments == ["--set", "cpu", "label=95%", "icon.color=\(palette.red.argb())", "update_freq=60",
                                      "--set", "memory", "label=8.1G", "update_freq=60",
                                      "--set", "clock", "label=Sun 25 Oct  14:05", "update_freq=60"])
    }

    @Test func laterUpdatesSendOnlyWhatChanged() {
        let last = BarFeedValues(cpu: 12, memory: "8.1G", clock: "Sun 25 Oct  14:05")
        #expect(BarFeed.command(last, last: last, bar: bar, palette: palette) == nil)
        var next = last
        next.cpu = 75
        #expect(BarFeed.command(next, last: last, bar: bar, palette: palette)?.arguments
                == ["--set", "cpu", "label=75%", "icon.color=\(palette.yellow.argb())", "update_freq=60"])
    }

    @Test func itemsTheBarDoesNotShowAreLeftOut() {
        var bar = BarSettings()
        bar.showCPU = false
        bar.showClock = false
        let values = BarFeedValues(cpu: nil, memory: "8.1G", clock: "Sun 25 Oct  14:05")
        #expect(BarFeed.command(values, last: nil, bar: bar, palette: palette)?.arguments == ["--set", "memory", "label=8.1G", "update_freq=60"])
        bar.showMemory = false
        #expect(BarFeed.command(values, last: nil, bar: bar, palette: palette) == nil)
        #expect(BarFeed.handBack(bar) == nil)
    }

    @Test func quittingHandsTheItemsBackAtTheirUsualPace() {
        #expect(BarFeed.handBack(bar)?.arguments == ["--set", "cpu", "update_freq=3", "--set", "memory", "update_freq=5",
                                                    "--set", "clock", "update_freq=10"])
    }

    @Test func valuesReadLikeTheScriptsWriteThem() throws {
        #expect(BarFeed.cpuPercent(0.129) == 12)
        #expect(BarFeed.cpuPercent(1.4) == 100)
        #expect(BarFeed.cpuColor(70, palette: palette) == palette.green.argb())
        #expect(BarFeed.cpuColor(71, palette: palette) == palette.yellow.argb())
        #expect(BarFeed.cpuColor(91, palette: palette) == palette.red.argb())
        #expect(BarFeed.memoryLabel(8_697_308_774) == "8.1G")
        let utc = try #require(TimeZone(identifier: "UTC"))
        let afternoon = try #require(ISO8601DateFormatter().date(from: "2026-10-25T14:05:59Z"))
        #expect(BarFeed.clockLabel(afternoon, timeZone: utc) == "Sun 25 Oct  14:05")
        let morning = try #require(ISO8601DateFormatter().date(from: "2026-03-01T09:00:00Z"))
        #expect(BarFeed.clockLabel(morning, timeZone: utc) == "Sun 01 Mar  09:00")
    }

    @Test func theBarConfigStillRunsTheScriptsAtTheirUsualPace() {
        let rc = SketchyBarConfig.rc(BarSettings())
        #expect(rc.contains("update_freq=3 script=\"$PLUGINS/cpu.sh\""))
        #expect(rc.contains("update_freq=5 script=\"$PLUGINS/memory.sh\""))
        #expect(rc.contains("update_freq=10 script=\"$PLUGINS/clock.sh\""))
    }
}
