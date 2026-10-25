import Foundation
@testable import OrbitCore
import Testing

@Suite struct OrbitLinkTests {
    func command(_ link: String) -> OrbitCommand? { OrbitLink.command(from: URL(string: link)!) }

    @Test func theDocumentedLinksMeanWhatTheySay() {
        #expect(command("orbit://page/monitor") == .open(.page(.monitor)))
        #expect(command("orbit://setup") == .open(.setup))
        #expect(command("orbit://panel") == .open(.panel))
        #expect(command("orbit://palette") == .open(.palette))
        #expect(command("orbit://toggle/tiling") == .toggleFeature(.tiling))
        #expect(command("orbit://on/glow") == .setFeature(.glow, on: true))
        #expect(command("orbit://off/menuBar") == .setFeature(.menuBar, on: false))
        #expect(command("orbit://off/menubar") == .setFeature(.menuBar, on: false))
        #expect(command("orbit://theme/nord") == .setTheme(.nord))
        #expect(command("orbit://mode/focus") == .toggleMode("focus"))
        #expect(command("orbit://mode/stop") == .stopMode)
        #expect(command("orbit://sort-downloads") == .sortDownloads)
        #expect(command("orbit://check") == .checkStatus)
        #expect(command("orbitdev://toggle/glow") == .toggleFeature(.glow))
    }

    @Test func anythingElseIsIgnored() {
        for link in ["orbit://restore", "orbit://undo/123", "orbit://cleanup", "orbit://toggle/raycast", "orbit://toggle/",
                     "orbit://page/nowhere", "orbit://theme/plaid", "orbit://mode", "https://page/monitor", "orbit:"] {
            #expect(command(link) == nil, "\(link)")
        }
    }

    @Test func linksRoundTrip() throws {
        let commands: [OrbitCommand] = [.open(.page(.health)), .open(.setup), .open(.panel), .open(.palette), .toggleFeature(.downloads),
                                        .setFeature(.capsLock, on: true), .setFeature(.tiling, on: false), .setTheme(.rosePine),
                                        .toggleMode("work"), .stopMode, .sortDownloads, .checkStatus]
        for original in commands {
            let url = try #require(OrbitLink.url(for: original))
            #expect(OrbitLink.command(from: url) == original, "\(url)")
        }
        #expect(OrbitLink.url(for: .toggleFeature(.raycast)) == nil)
        #expect(OrbitLink.url(for: .open(.page(.modes)), scheme: "orbitdev")?.absoluteString == "orbitdev://page/modes")
    }

    @Test func onlyOrbitsOwnPlacesCountAsForeground() {
        #expect(!CommandSource.window.isBackground && !CommandSource.panel.isBackground && !CommandSource.palette.isBackground)
        #expect(CommandSource.shortcut.isBackground && CommandSource.control.isBackground && CommandSource.link.isBackground)
        #expect(OrbitCommand.open(.panel).showsOrbit)
        #expect(!OrbitCommand.toggleFeature(.glow).showsOrbit)
    }
}

@Suite struct SnapshotTests {
    @Test func statesFoldIntoWhatAWidgetCanShow() {
        #expect(OrbitSnapshot.State(.on) == .on)
        #expect(OrbitSnapshot.State(.needsPermission(.accessibility, "Needs Accessibility")) == .attention)
        #expect(OrbitSnapshot.State(.blocked("Keeps stopping")) == .attention)
        #expect(OrbitSnapshot.State(.working("Starting…")) == .checking)
        #expect(OrbitSnapshot.State(.unknown) == .checking)
        #expect(OrbitSnapshot.State(.notInstalled) == .notInstalled)
    }

    @Test func aSnapshotKnowsWhenOrbitHasGone() {
        let now = Date()
        let fresh = OrbitSnapshot(written: now.addingTimeInterval(-60))
        #expect(fresh.isLive(now: now))
        #expect(!OrbitSnapshot(written: now.addingTimeInterval(-25 * 60)).isLive(now: now))
        #expect(!OrbitSnapshot(written: now, running: false).isLive(now: now))
    }

    @Test func contentIsComparedWhateverTheTime() {
        let features = [OrbitSnapshot.Feature(id: .tiling, state: .on), OrbitSnapshot.Feature(id: .glow, state: .attention, detail: "x")]
        let a = OrbitSnapshot(written: Date(timeIntervalSince1970: 0), features: features)
        var b = a
        b.written = Date()
        #expect(a.sameContent(as: b))
        b.activeMode = "focus"
        #expect(!a.sameContent(as: b))
        #expect(a.done == 1 && a.attention.map(\.id) == [.glow])
    }
}

@Suite struct HotKeyTests {
    @Test func shortcutsReadTheWayMenusShowThem() {
        #expect(HotKeySetting.standard.label == "Hyper + Space")
        let k = HotKeySetting(keyCode: 40, modifiers: HotKeySetting.control | HotKeySetting.option | HotKeySetting.command, key: "K")
        #expect(k.label == "⌃⌥⌘K")
        #expect(k.isUsable)
        #expect(!HotKeySetting(keyCode: 40, modifiers: HotKeySetting.command, key: "K").isUsable)
    }

    @Test func takenShortcutsAreCaught() {
        let spotlight = HotKeySetting(keyCode: 49, modifiers: HotKeySetting.command, key: "Space")
        #expect(HotKeyClash.check(spotlight, skhdrc: nil) == "macOS already uses ⌘Space for Spotlight.")
        let skhdrc = """
        # focus
        alt - h : yabai -m window --focus west
        hyper - space : yabai -m space --layout bsp
        cmd + shift - k : yabai -m window --swap north
        """
        #expect(HotKeyClash.check(.standard, skhdrc: skhdrc) == "Window tiling already uses Hyper + Space (in skhdrc).")
        let swapNorth = HotKeySetting(keyCode: 40, modifiers: HotKeySetting.command | HotKeySetting.shift, key: "K")
        #expect(HotKeyClash.check(swapNorth, skhdrc: skhdrc) != nil)
        #expect(HotKeyClash.check(.standard, skhdrc: "alt - h : yabai -m window --focus west") == nil)
    }

    @Test func someNoticesWaitLonger() {
        let now = Date()
        let sent = [NoticePolicy.Sent(key: "attention tiling", kind: "attention", at: now.addingTimeInterval(-3600))]
        #expect(NoticePolicy.allows(key: "attention tiling", kind: "attention", sent: sent, now: now))
        #expect(!NoticePolicy.allows(key: "attention tiling", kind: "attention", sent: sent, now: now, every: 6 * 3600))
    }
}
