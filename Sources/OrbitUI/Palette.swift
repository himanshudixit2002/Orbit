import AppKit
import OrbitCore
import OrbitPlatform
import SwiftUI

/// One thing the command palette can do.
struct PaletteItem: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let symbol: String
    var keywords = ""
    let action: () -> Void
}

extension AppModel {
    /// What the palette offers right now: each switch says which way it will go, the theme in use
    /// and the mode that's on are offered the other way round.
    func paletteItems() -> [PaletteItem] {
        func command(_ command: OrbitCommand) -> () -> Void {
            { [weak self] in Task { await self?.run(command, source: .palette) } }
        }
        var items: [PaletteItem] = []
        if let last = journal.last(where: { !$0.undone && !$0.actions.isEmpty }) {
            items.append(PaletteItem(id: "undo", title: "Undo “\(last.title)”", subtitle: "Puts back what that change did",
                                     symbol: "arrow.uturn.backward", keywords: "undo revert back") { [weak self] in self?.undo(last.id) })
        }
        for id in FeatureID.switchable where state(id) != .notInstalled {
            let on = state(id).isOn
            items.append(PaletteItem(id: "feature-\(id.rawValue)", title: "Turn \(on ? "off" : "on") \(id.inSentence)",
                                     subtitle: on ? "It's on now" : "It's off now", symbol: id.symbol,
                                     keywords: "\(id.title) \(id.shortTitle) switch toggle", action: command(.setFeature(id, on: !on))))
        }
        for mode in settings.modes {
            let active = modes.active?.modeID == mode.id
            items.append(PaletteItem(id: "mode-\(mode.id)", title: active ? "Stop \(mode.name) mode" : "Start \(mode.name) mode",
                                     subtitle: active ? "Puts back what it changed" : mode.blurb, symbol: mode.symbol,
                                     keywords: "mode", action: command(active ? .stopMode : .startMode(mode.id))))
        }
        for palette in Palette.all where palette.id != settings.theme {
            items.append(PaletteItem(id: "theme-\(palette.id.rawValue)", title: "Switch to \(palette.name)", subtitle: palette.tagline,
                                     symbol: "paintpalette.fill", keywords: "theme colours colors look", action: command(.setTheme(palette.id))))
        }
        items.append(PaletteItem(id: "sort", title: "Sort Downloads now", subtitle: "Into folders by type", symbol: "arrow.down.doc.fill",
                                 keywords: "downloads tidy files", action: command(.sortDownloads)))
        items.append(PaletteItem(id: "check", title: "Check everything again", subtitle: "A fresh, thorough look", symbol: "stethoscope",
                                 keywords: "status health refresh", action: command(.checkStatus)))
        items.append(PaletteItem(id: "setup", title: "Guided setup", subtitle: "Set up the Mac step by step", symbol: "wand.and.stars",
                                 keywords: "setup start", action: command(.open(.setup))))
        for page in Page.allCases {
            items.append(PaletteItem(id: "page-\(page.rawValue)", title: "Open \(page.title)", subtitle: page.blurb, symbol: page.symbol,
                                     keywords: "page go show", action: command(.open(.page(page)))))
        }
        for entry in SearchIndex.settings {
            items.append(PaletteItem(id: "setting-\(entry.id)", title: entry.title, subtitle: entry.detail, symbol: entry.symbol,
                                     keywords: entry.keywords, action: command(.open(.page(entry.page)))))
        }
        return items
    }

    public func showPalette() {
        commandPalette.show(self)
    }
}

enum PaletteFilter {
    /// Items containing every word typed, those whose title starts with it first. Nothing typed: the
    /// first few, which are the switches and modes.
    static func results(_ query: String, in items: [PaletteItem], limit: Int = 8) -> [PaletteItem] {
        func fold(_ s: String) -> String { s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) }
        let words = fold(query).split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return Array(items.prefix(limit)) }
        let phrase = words.joined(separator: " ")
        func rank(_ item: PaletteItem) -> Int {
            let title = fold(item.title)
            if title.hasPrefix(phrase) { return 0 }
            if title.split(separator: " ").contains(where: { $0.hasPrefix(words[0]) }) { return 1 }
            return 2
        }
        let matching = items.enumerated().filter { _, item in
            let text = fold("\(item.title) \(item.subtitle) \(item.keywords)")
            return words.allSatisfy(text.contains)
        }
        return matching.sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }.prefix(limit).map(\.element)
    }
}

/// Type what you want, press Return.
struct CommandPaletteView: View {
    let items: [PaletteItem]
    let close: () -> Void
    @State private var query = ""
    @State private var selection = 0
    @FocusState private var focused: Bool

    var body: some View {
        let results = PaletteFilter.results(query, in: items)
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "atom").font(.title2).foregroundStyle(.tint)
                TextField("Switch, theme, mode, page…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title2)
                    .focused($focused)
                    .onSubmit { run(results) }
                    .onKeyPress(.downArrow) {
                        selection = min(selection + 1, max(results.count - 1, 0))
                        return .handled
                    }
                    .onKeyPress(.upArrow) {
                        selection = max(selection - 1, 0)
                        return .handled
                    }
                    .onKeyPress(.escape) {
                        close()
                        return .handled
                    }
                    .onChange(of: query) { selection = 0 }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            if !results.isEmpty {
                Divider()
                VStack(spacing: 2) {
                    ForEach(Array(results.enumerated()), id: \.element.id) { index, item in
                        row(item, selected: index == selection)
                            .onTapGesture {
                                selection = index
                                run(results)
                            }
                    }
                }
                .padding(8)
            } else {
                Text("Nothing matches “\(query)”.").foregroundStyle(.secondary).padding(.bottom, 14)
            }
        }
        .frame(width: 620)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
        .onAppear { focused = true }
    }

    func row(_ item: PaletteItem, selected: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: item.symbol).frame(width: 22).foregroundStyle(selected ? .white : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).font(.body.weight(.medium)).lineLimit(1)
                Text(item.subtitle).font(.caption).foregroundStyle(selected ? .white.opacity(0.85) : .secondary).lineLimit(1)
            }
            Spacer()
            if selected { Image(systemName: "return").font(.caption).foregroundStyle(.white.opacity(0.8)) }
        }
        .foregroundStyle(selected ? .white : .primary)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(selected ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 10))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    func run(_ results: [PaletteItem]) {
        guard results.indices.contains(selection) else { return }
        close()
        results[selection].action()
    }
}

/// The palette's floating panel. It takes the keyboard without bringing Orbit to the front, so a
/// switch changes things where you are, and it goes away when you click elsewhere.
final class PaletteController {
    private var panel: PalettePanel?

    func show(_ model: AppModel) {
        let panel = panel ?? makePanel()
        self.panel = panel
        // A fresh view each time: an empty search, the first item selected.
        let view = CommandPaletteView(items: model.paletteItems()) { [weak panel] in panel?.orderOut(nil) }
        panel.contentView = NSHostingView(rootView: view.environment(model))
        panel.layoutIfNeeded()
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            let size = panel.contentView?.fittingSize ?? CGSize(width: 620, height: 400)
            panel.setFrame(CGRect(x: frame.midX - size.width / 2, y: frame.maxY - frame.height * 0.22 - size.height,
                                  width: size.width, height: size.height), display: true)
        }
        panel.makeKeyAndOrderFront(nil)
    }

    private func makePanel() -> PalettePanel {
        let panel = PalettePanel(contentRect: CGRect(x: 0, y: 0, width: 620, height: 400),
                                 styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        return panel
    }
}

final class PalettePanel: NSPanel {
    override var canBecomeKey: Bool { true }

    override func resignKey() {
        super.resignKey()
        orderOut(nil)
    }

    override func cancelOperation(_ sender: Any?) {
        orderOut(nil)
    }
}

extension AppModel {
    /// Registers the palette's shortcut (or removes it), from the settings.
    func applyHotKey() {
        guard !isSnapshot else { return }
        hotKey.onPress = { [weak self] in self?.showPalette() }
        hotKey.register(settings.hotKey ?? .standard)
        hotKeyRegistered = hotKey.registered
    }

    func setHotKey(_ hotKey: HotKeySetting) {
        ctx.store.updateSettings { $0.hotKey = hotKey }
        settings = ctx.store.settings
        applyHotKey()
    }
}
