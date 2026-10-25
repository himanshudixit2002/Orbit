import Foundation
@testable import OrbitCore
import Testing

@Suite struct ModeScheduleTests {
    var london: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London")!
        return calendar
    }

    func date(_ text: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(identifier: "Europe/London")!
        formatter.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime, .withDashSeparatorInDate]
        return formatter.date(from: text)!
    }

    @Test func theNextStartIsTheNextChosenDayAtThatTime() {
        var schedule = ModeSchedule()
        schedule.enabled = true
        schedule.weekdays = [2]   // Mondays
        schedule.start = 9 * 60
        // Sunday 25 October 2026, noon → Monday 26 October, 09:00.
        #expect(schedule.nextStart(after: date("2026-10-25T12:00:00"), calendar: london) == date("2026-10-26T09:00:00"))
        // Already past 9 on a Monday → the next Monday.
        #expect(schedule.nextStart(after: date("2026-10-26T09:30:00"), calendar: london) == date("2026-11-02T09:00:00"))
        schedule.enabled = false
        #expect(schedule.nextStart(after: date("2026-10-25T12:00:00"), calendar: london) == nil)
    }

    @Test func aTimeTheClockSkipsMovesToTheNextOne() {
        var schedule = ModeSchedule()
        schedule.enabled = true
        schedule.weekdays = [1]   // Sundays
        schedule.start = 60 + 30  // 01:30, which doesn't exist on 29 March 2026 in London
        let next = schedule.nextStart(after: date("2026-03-28T12:00:00"), calendar: london)
        #expect(next == date("2026-03-29T02:00:00"))
    }

    @Test func theTimerStopsBeforeTheNextScheduledStart() throws {
        var focus = ModeDefinition.defaults[1]
        focus.schedule = ModeSchedule()
        focus.schedule?.enabled = true
        focus.schedule?.weekdays = Set(1...7)
        let now = date("2026-10-25T08:00:00")
        let active = ModeAlarm.Active(modeID: "work", started: now, endsAt: now.addingTimeInterval(25 * 60), bySchedule: false)
        let alarm = ModeAlarm.next(after: now, modes: [ModeDefinition.defaults[0], focus], active: active, calendar: london)
        #expect(alarm == .stop(modeID: "work", at: now.addingTimeInterval(25 * 60), reason: "its timer ended"))
        let later = ModeAlarm.next(after: now, modes: [ModeDefinition.defaults[0], focus], active: nil, calendar: london)
        #expect(later == .start(modeID: "focus", at: date("2026-10-25T09:00:00"), askFirst: true))
    }

    @Test func modesFromOrbitOneKeepTheirTilingSwitch() throws {
        let old = #"{"id": "work", "name": "Work", "symbol": "laptopcomputer", "blurb": "", "openApps": [], "quitApps": [], "hideOthers": false, "keepAwake": "system", "tilingOn": true}"#
        let mode = try JSONDecoder().decode(ModeDefinition.self, from: Data(old.utf8))
        #expect(mode.tiling == .on && mode.glow == .leave && mode.theme == nil && mode.schedule == nil)
        var richer = mode
        richer.theme = .nord
        richer.urls = ["https://linear.app"]
        richer.timerMinutes = 50
        richer.schedule = ModeSchedule()
        #expect(try JSONDecoder().decode(ModeDefinition.self, from: JSONEncoder().encode(richer)) == richer)
    }
}

@Suite struct DeveloperReadingTests {
    @Test func gitStatusSaysBranchDistanceAndChanges() {
        let text = """
        # branch.oid 4d7da41
        # branch.head main
        # branch.upstream origin/main
        # branch.ab +2 -1
        1 .M N... 100644 100644 100644 abc def Sources/App.swift
        ? notes.txt
        """
        #expect(GitStatus.parse(text) == GitStatus(branch: "main", upstream: "origin/main", ahead: 2, behind: 1, changes: 2))
        #expect(GitStatus.parse("# branch.oid (initial)\n# branch.head main\n") == GitStatus(branch: "main"))
    }

    @Test func listeningProcessesAreReadOncePerPort() {
        let text = "p598\ncrapportd\nf11\nn*:49152\nf12\nn*:49152\np4242\ncnode\nf20\nn127.0.0.1:3000\nf21\nn[::1]:3000\n"
        #expect(ListeningPort.parse(text) == [ListeningPort(pid: 4242, command: "node", port: 3000),
                                             ListeningPort(pid: 598, command: "rapportd", port: 49152)])
    }

    @Test func projectKindsComeFromTheirFiles() {
        #expect(ProjectKind.detect(["Orbit.xcodeproj", "Package.swift"]) == .xcode)
        #expect(ProjectKind.detect(["pubspec.yaml", "android"]) == .flutter)
        #expect(ProjectKind.detect(["package.json", "tsconfig.json"]) == .node)
        #expect(ProjectKind.detect(["README.md"]) == .other)
        #expect(ProjectKind.node.gitignore.contains("node_modules/"))
        #expect(ProjectKind.swift.gitignore.contains(".build/"))
    }
}

@Suite struct PortOwnerTests {
    @Test func ownersComeFromWhereTheProgramLives() {
        #expect(PortOwner.of(executable: "/System/Library/CoreServices/ControlCenter.app/Contents/MacOS/ControlCenter", parent: 1) == .macOS)
        #expect(PortOwner.of(executable: "/usr/libexec/rapportd", parent: 1) == .macOS)
        #expect(PortOwner.of(executable: "/Applications/Raycast.app/Contents/MacOS/Raycast", parent: 1) == .app("Raycast"))
        #expect(PortOwner.of(executable: "/Applications/Antigravity.app/Contents/Frameworks/Helper.app/Contents/MacOS/Helper", parent: 812) == .app("Antigravity"))
        #expect(PortOwner.of(executable: "/opt/homebrew/Cellar/mongodb-community/8.0.4/bin/mongod", parent: 1) == .background)
        #expect(PortOwner.of(executable: "/opt/homebrew/Cellar/node/24.1.0/bin/node", parent: 4100) == .yours)
        #expect(PortOwner.of(executable: "/Applications/Xcode.app/Contents/Developer/usr/bin/python3", parent: 4100) == .yours)
        #expect(PortOwner.of(executable: nil, parent: 4100) == .background)
        #expect(ListeningPort(pid: 9, command: "ControlCenter", port: 5000).knownUse == "AirPlay Receiver")
    }
}
