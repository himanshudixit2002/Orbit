import Foundation
@testable import OrbitCore
import Testing

@Suite struct WindowLayoutTests {
    typealias Frame = YabaiWindow.Frame
    let left = Frame(x: 4, y: 44, w: 954, h: 1032)
    let right = Frame(x: 962, y: 44, w: 954, h: 1032)

    @Test func yabaisAnswersAreRead() {
        let windows = Data("""
        [{"id":2593,"app":"Safari","title":"YouTube","space":2,"display":1,"frame":{"x":0.0,"y":0.0,"w":1920.0,"h":1080.0},
          "is-floating":false,"is-minimized":false,"is-hidden":false},
         {"id":7,"app":"Notes","title":"","space":1,"frame":{"x":1,"y":2,"w":3,"h":4},"is-minimized":true},
         {"id":"broken"}]
        """.utf8)
        let parsed = YabaiWindow.parse(windows)
        #expect(parsed.map(\.id) == [2593])
        #expect(parsed.first?.frame == Frame(x: 0, y: 0, w: 1920, h: 1080))
        let spaces = YabaiSpace.parse(Data(#"[{"index":1,"type":"bsp","is-visible":false},{"index":2,"type":"float","is-visible":true}]"#.utf8))
        #expect(spaces == [YabaiSpace(index: 1, layout: .tiles), YabaiSpace(index: 2, layout: .free, isVisible: true)])
    }

    @Test func aCaptureReadsLeftToRightAndSkipsEmptyDesktops() {
        let windows = [YabaiWindow(id: 2, app: "Warp", space: 1, frame: right), YabaiWindow(id: 1, app: "Antigravity IDE", space: 1, frame: left)]
        let layout = WindowLayout.capture(name: "Coding", windows: windows, spaces: [YabaiSpace(index: 1, layout: .tiles), YabaiSpace(index: 2, layout: .stack)])
        #expect(layout.desktops.count == 1)
        #expect(layout.desktops[0].windows.map(\.app) == ["Antigravity IDE", "Warp"])
        #expect(layout.summary == "1 desktop: Antigravity IDE, Warp")
    }

    @Test func theSameArrangementNeedsNothing() {
        let windows = [YabaiWindow(id: 1, app: "Antigravity IDE", space: 1, frame: left), YabaiWindow(id: 2, app: "Warp", space: 1, frame: right)]
        let spaces = [YabaiSpace(index: 1, layout: .tiles)]
        let layout = WindowLayout.capture(name: "Coding", windows: windows, spaces: spaces)
        #expect(LayoutPlanner.plan(layout, windows: windows, spaces: spaces) == LayoutPlan())
    }

    @Test func swappedWindowsAreSwappedBack() {
        let spaces = [YabaiSpace(index: 1, layout: .tiles)]
        let saved = WindowLayout.capture(name: "Coding", windows: [YabaiWindow(id: 1, app: "Antigravity IDE", space: 1, frame: left),
                                                                    YabaiWindow(id: 2, app: "Warp", space: 1, frame: right)], spaces: spaces)
        let now = [YabaiWindow(id: 11, app: "Warp", space: 1, frame: left), YabaiWindow(id: 12, app: "Antigravity IDE", space: 1, frame: right)]
        #expect(LayoutPlanner.plan(saved, windows: now, spaces: spaces).steps == [.swap(11, 12)])
    }

    @Test func stylesFloatingAndFramesComeBack() {
        let note = Frame(x: 100, y: 120, w: 400, h: 300)
        let saved = WindowLayout(name: "Writing", desktops: [
            WindowLayout.Desktop(index: 1, layout: .stack, windows: [
                .init(app: "Pages", title: "Draft", floating: false, frame: left),
                .init(app: "Notes", title: "", floating: true, frame: note)
            ])
        ])
        let now = [YabaiWindow(id: 1, app: "Pages", title: "Draft", space: 1, frame: left),
                   YabaiWindow(id: 2, app: "Notes", space: 1, frame: right)]
        let plan = LayoutPlanner.plan(saved, windows: now, spaces: [YabaiSpace(index: 1, layout: .tiles)])
        #expect(plan.steps == [.spaceLayout(space: 1, .stack), .toggleFloat(window: 2), .move(window: 2, x: 100, y: 120), .resize(window: 2, w: 400, h: 300)])
        #expect(plan.reshapes)
    }

    @Test func windowsElsewhereOrClosedAreSaidNotMoved() {
        let saved = WindowLayout(name: "Coding", desktops: [
            WindowLayout.Desktop(index: 1, layout: .tiles, windows: [
                .init(app: "Warp", title: "", floating: false, frame: left),
                .init(app: "Xcode", title: "", floating: false, frame: right)
            ]),
            WindowLayout.Desktop(index: 5, layout: .tiles, windows: [.init(app: "Mail", title: "", floating: false, frame: left)])
        ])
        let now = [YabaiWindow(id: 3, app: "Warp", space: 2, frame: left)]
        let plan = LayoutPlanner.plan(saved, windows: now, spaces: [YabaiSpace(index: 1, layout: .tiles), YabaiSpace(index: 2, layout: .tiles)])
        #expect(plan.steps.isEmpty)
        #expect(plan.notes == ["Warp is on desktop 2, not 1: macOS doesn't let Orbit move windows between desktops.",
                               "Xcode isn't open.", "Desktop 5 isn't there any more."])
    }

    @Test func titlesPickTheRightWindowOfAnApp() {
        let spaces = [YabaiSpace(index: 1, layout: .tiles)]
        let saved = WindowLayout(name: "Two", desktops: [WindowLayout.Desktop(index: 1, layout: .tiles, windows: [
            .init(app: "Warp", title: "server", floating: false, frame: left), .init(app: "Warp", title: "tests", floating: false, frame: right)
        ])])
        let now = [YabaiWindow(id: 1, app: "Warp", title: "tests", space: 1, frame: left), YabaiWindow(id: 2, app: "Warp", title: "server", space: 1, frame: right)]
        #expect(LayoutPlanner.plan(saved, windows: now, spaces: spaces).steps == [.swap(1, 2)])
    }

    @Test func desktopStylesGoInTheConfigAndLoadForgivingly() throws {
        var settings = OrbitSettings()
        settings.tiling.spaceLayouts = [SpaceLayout(space: 3, layout: .free), SpaceLayout(space: 2, layout: .stack)]
        let rc = YabaiConfig.render(settings, barReserved: nil)
        #expect(rc.contains("yabai -m config --space 2 layout stack\nyabai -m config --space 3 layout float"))
        #expect(settings.tiling.layout(of: 2) == .stack && settings.tiling.layout(of: 1) == .tiles)
        let json = #"{"tiling": {"layout": "stack", "spaceLayouts": [{"space": 2, "layout": "spiral"}, {"space": 4, "layout": "bsp"}]}}"#
        let loaded = try OrbitSettings.decode(Data(json.utf8))
        #expect(loaded.tiling.layout == .stack)
        #expect(loaded.tiling.spaceLayouts == [SpaceLayout(space: 4, layout: .tiles)])
    }

    @Test func arrangementsHaveLinks() throws {
        let url = try #require(OrbitLink.url(for: .arrangeWindows("Coding Day"), token: "t"))
        #expect(url.absoluteString == "orbit://arrange/Coding%20Day?token=t")
        #expect(OrbitLink.command(from: url) == .arrangeWindows("Coding Day"))
        #expect(OrbitLink.command(from: URL(string: "orbit://arrange")!) == nil)
    }
}
