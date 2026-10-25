import Foundation

/// Colour files for the terminal tools, generated from a palette so they all match.
public enum TerminalThemes {
    public static let themeName = "orbit"

    public static func batConfig() -> String {
        """
        # Managed by Orbit (Style page): bat and git diffs use Orbit's theme.
        --theme="\(themeName)"
        --italic-text=always

        """
    }

    /// A TextMate theme for bat (and delta, which reads bat's themes).
    public static func bat(_ p: Palette) -> String {
        func rule(_ name: String, _ scope: String, _ color: RGB, _ style: String? = nil) -> String {
            let font = style.map { "<key>fontStyle</key><string>\($0)</string>" } ?? ""
            return "    <dict><key>name</key><string>\(name)</string><key>scope</key><string>\(scope)</string>\n"
                + "      <key>settings</key><dict><key>foreground</key><string>\(color.hex)</string>\(font)</dict></dict>"
        }
        let rules = [
            rule("Comment", "comment, punctuation.definition.comment", p.muted, "italic"),
            rule("String", "string, punctuation.definition.string", p.green),
            rule("Escape", "constant.character.escape, string.regexp", p.teal),
            rule("Number, constant", "constant.numeric, constant.language, constant.other, support.constant", p.orange),
            rule("Keyword", "keyword, storage.type, storage.modifier, keyword.control", p.accent2),
            rule("Operator", "keyword.operator, punctuation.accessor, punctuation.separator", p.cyan),
            rule("Function", "entity.name.function, support.function, meta.function-call variable.function, variable.function", p.accent),
            rule("Type", "entity.name.type, entity.name.class, support.type, support.class, entity.other.inherited-class", p.cyan),
            rule("Parameter", "variable.parameter", p.yellow),
            rule("Builtin variable", "variable.language, support.variable", p.red),
            rule("Property", "variable.other.property, variable.other.member, meta.object-literal.key, support.type.property-name", p.teal),
            rule("Tag", "entity.name.tag, meta.tag punctuation.definition.tag", p.red),
            rule("Attribute", "entity.other.attribute-name", p.accent2),
            rule("Heading", "markup.heading, entity.name.section", p.accent, "bold"),
            rule("Bold", "markup.bold", p.orange, "bold"),
            rule("Italic", "markup.italic", p.accent2, "italic"),
            rule("Link", "markup.underline.link, string.other.link", p.teal),
            rule("Inline code", "markup.raw, markup.inline.raw", p.cyan),
            rule("Inserted", "markup.inserted, meta.diff.header.to-file", p.green),
            rule("Deleted", "markup.deleted, meta.diff.header.from-file", p.red),
            rule("Changed", "markup.changed, meta.diff.range", p.yellow),
            rule("Invalid", "invalid, invalid.illegal", p.red)
        ]
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <!-- Managed by Orbit: the \(p.name) theme for bat and git diffs. -->
        <plist version="1.0">
        <dict>
          <key>name</key><string>\(themeName)</string>
          <key>settings</key>
          <array>
            <dict>
              <key>settings</key>
              <dict>
                <key>background</key><string>\(p.bg.hex)</string>
                <key>foreground</key><string>\(p.fg.hex)</string>
                <key>caret</key><string>\(p.fg.hex)</string>
                <key>selection</key><string>\(p.surface.mixed(with: p.accent, 0.25).hex)</string>
                <key>lineHighlight</key><string>\(p.surface.hex)</string>
                <key>gutter</key><string>\(p.bg.hex)</string>
                <key>gutterForeground</key><string>\(p.line.hex)</string>
                <key>invisibles</key><string>\(p.line.hex)</string>
              </dict>
            </dict>
        \(rules.joined(separator: "\n"))
          </array>
          <key>uuid</key><string>5f4a6a1c-3b7e-4c2d-9e61-0b1700000001</string>
        </dict>
        </plist>

        """
    }

    public static func btop(_ p: Palette) -> String {
        let entries: [(String, RGB?)] = [
            ("main_bg", nil), ("main_fg", p.fg), ("title", p.fg), ("hi_fg", p.accent),
            ("selected_bg", p.surface.mixed(with: p.accent, 0.25)), ("selected_fg", p.fg), ("inactive_fg", p.muted),
            ("graph_text", p.fg), ("meter_bg", p.line), ("proc_misc", p.cyan), ("cpu_box", p.accent),
            ("mem_box", p.green), ("net_box", p.accent2), ("proc_box", p.cyan), ("div_line", p.line),
            ("temp_start", p.green), ("temp_mid", p.yellow), ("temp_end", p.red),
            ("cpu_start", p.cyan), ("cpu_mid", p.accent), ("cpu_end", p.accent2),
            ("free_start", p.green), ("free_mid", p.teal), ("free_end", p.cyan),
            ("cached_start", p.accent), ("cached_mid", p.cyan), ("cached_end", p.teal),
            ("available_start", p.yellow), ("available_mid", p.orange), ("available_end", p.red),
            ("used_start", p.red), ("used_mid", p.orange), ("used_end", p.yellow),
            ("download_start", p.cyan), ("download_mid", p.accent), ("download_end", p.accent2),
            ("upload_start", p.green), ("upload_mid", p.yellow), ("upload_end", p.red),
            ("process_start", p.cyan), ("process_mid", p.accent), ("process_end", p.accent2)
        ]
        return "# Managed by Orbit: the \(p.name) theme for btop.\n"
            + entries.map { "theme[\($0.0)]=\"\($0.1?.hex ?? "")\"" }.joined(separator: "\n") + "\n"
    }

    /// btop.conf with its colour theme pointed at Orbit's (other lines kept).
    public static func btopConf(_ existing: String?) -> String {
        let line = "color_theme = \"\(themeName)\""
        guard let existing, !existing.isEmpty else { return line + "\n" }
        var lines = existing.components(separatedBy: "\n")
        if let i = lines.firstIndex(where: { $0.hasPrefix("color_theme") }) {
            lines[i] = line
        } else {
            lines.insert(line, at: min(1, lines.count))
        }
        return lines.joined(separator: "\n")
    }

    public static func lazygit(_ p: Palette) -> String {
        """
        # Managed by Orbit (Style page): lazygit in the \(p.name) theme.
        gui:
          nerdFontsVersion: "3"
          border: rounded
          showIcons: true
          theme:
            activeBorderColor: ["\(p.accent.hex)", bold]
            inactiveBorderColor: ["\(p.line.hex)"]
            searchingActiveBorderColor: ["\(p.orange.hex)", bold]
            optionsTextColor: ["\(p.accent.hex)"]
            selectedLineBgColor: ["\(p.surface.mixed(with: p.accent, 0.25).hex)"]
            inactiveViewSelectedLineBgColor: ["\(p.surface.hex)"]
            cherryPickedCommitFgColor: ["\(p.accent.hex)"]
            cherryPickedCommitBgColor: ["\(p.accent2.hex)"]
            markedBaseCommitFgColor: ["\(p.accent.hex)"]
            markedBaseCommitBgColor: ["\(p.yellow.hex)"]
            unstagedChangesColor: ["\(p.red.hex)"]
            defaultFgColor: ["\(p.fg.hex)"]

        """
    }

    public static func fastfetch(_ p: Palette) -> String {
        #"""
        // Managed by Orbit (Style page): the `hi` system splash in the \#(p.name) theme.
        {
          "$schema": "https://github.com/fastfetch-cli/fastfetch/raw/dev/doc/json_schema.json",
          "logo": {
            "type": "builtin",
            "source": "macos_small",
            "color": { "1": "\#(p.green.ansi)", "2": "\#(p.yellow.ansi)", "3": "\#(p.orange.ansi)", "4": "\#(p.red.ansi)", "5": "\#(p.accent2.ansi)", "6": "\#(p.accent.ansi)" },
            "padding": { "top": 1, "left": 2, "right": 3 }
          },
          "display": {
            "separator": "  ",
            "color": { "keys": "\#(p.accent.ansi)", "title": "\#(p.accent2.ansi)" },
            "key": { "width": 11 }
          },
          "modules": [
            { "type": "title", "format": "{user-name}@{host-name}" },
            { "type": "custom", "format": "\u001b[\#(p.line.ansi)m──────────────────────────────" },
            { "type": "os", "key": " os" },
            { "type": "host", "key": " host" },
            { "type": "cpu", "key": " cpu", "showPeCoreCount": true },
            { "type": "gpu", "key": " gpu" },
            { "type": "memory", "key": " memory" },
            { "type": "disk", "key": " disk", "folders": "/System/Volumes/Data", "format": "{size-used} / {size-total} ({size-percentage})" },
            { "type": "uptime", "key": " uptime" },
            { "type": "packages", "key": " packages" },
            { "type": "shell", "key": " shell" },
            { "type": "terminal", "key": " terminal" },
            { "type": "localip", "key": " local ip", "showIpv6": false },
            "break",
            { "type": "colors", "symbol": "circle", "paddingLeft": 2 }
          ]
        }

        """#
    }

    public static func tmux(_ p: Palette) -> String {
        """
        # Managed by Orbit (Style page): tmux colours in the \(p.name) theme.
        set -g status-style "bg=\(p.bg.hex),fg=\(p.fg.hex)"
        set -g status-left "#[fg=\(p.accent.hex),bold] #S #[fg=\(p.muted.hex)]│ "
        set -g status-right "#[fg=\(p.muted.hex)]│ #[fg=\(p.yellow.hex)]#(whoami) #[fg=\(p.muted.hex)]│ #[fg=\(p.green.hex)] %H:%M #[fg=\(p.muted.hex)]│ #[fg=\(p.accent2.hex)]%d-%b"
        setw -g window-status-format "#[fg=\(p.muted.hex)] #I:#W "
        setw -g window-status-current-format "#[fg=\(p.accent.hex),bold] #I:#W "
        set -g pane-border-style "fg=\(p.line.hex)"
        set -g pane-active-border-style "fg=\(p.accent.hex)"
        set -g message-style "bg=\(p.bg.hex),fg=\(p.accent.hex),bold"

        """
    }

    public static let tmuxMarkerStart = "# >>> Orbit theme (added by Orbit; remove these lines to stop it)"
    public static let tmuxMarkerEnd = "# <<< Orbit theme"

    /// `~/.tmux.conf` with Orbit's include block before the TPM line (or at the end), added once.
    public static func tmuxConfWithInclude(_ conf: String) -> String {
        guard !conf.contains(tmuxMarkerStart) else { return conf }
        let block = "\(tmuxMarkerStart)\nsource-file -q ~/.config/tmux/orbit-theme.conf\n\(tmuxMarkerEnd)"
        var lines = conf.components(separatedBy: "\n")
        if let tpm = lines.firstIndex(where: { $0.hasPrefix("# Initialize TPM") || $0.hasPrefix("run '~/.tmux/plugins/tpm/tpm'") }) {
            lines.insert(block, at: tpm)
            return lines.joined(separator: "\n")
        }
        return conf + (conf.hasSuffix("\n") || conf.isEmpty ? "" : "\n") + block + "\n"
    }

    /// `~/.tmux.conf` without Orbit's block, as it was before the block was added.
    public static func tmuxConfWithoutInclude(_ conf: String) -> String {
        guard let start = conf.range(of: tmuxMarkerStart + "\n"),
              let end = conf.range(of: tmuxMarkerEnd + "\n", range: start.upperBound..<conf.endIndex) else { return conf }
        var out = conf
        out.removeSubrange(start.lowerBound..<end.upperBound)
        return out
    }
}
