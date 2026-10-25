import Foundation

/// yabai's config file: window tiling.
public enum YabaiConfig {
    /// - Parameter barReserved: room to keep free at the top for SketchyBar, or nil when the bar is off.
    public static func render(_ settings: OrbitSettings, barReserved: Int?) -> String {
        func config(_ key: String, _ value: String) -> String {
            "yabai -m config " + key.padding(toLength: 22, withPad: " ", startingAt: 0) + value
        }
        let tiling = settings.tiling
        let floating = settings.floatingApps.map { Shell.insideDoubleQuotes(Shell.regexEscape($0)) }.joined(separator: "|")
        let bar = barReserved.map {
            "# Keep windows below the menu bar (\(settings.bar.height)pt bar + \(settings.bar.yOffset)pt offset)\n"
                + config("external_bar", "all:\($0):0")
        } ?? "# No custom menu bar, so windows may use the top of the screen\n" + config("external_bar", "all:0:0")
        return """
        #!/usr/bin/env sh
        # Managed by Orbit (Windows page). Orbit notices hand edits and asks before replacing them;
        # put extra lines of your own in ~/.config/yabai/yabairc.local, which is read at the end.
        # Runs without disabling SIP, so it sticks to features that need no scripting addition.

        \(config("layout", tiling.layout.rawValue))
        \(config("window_placement", "second_child"))
        \(config("split_ratio", "0.50"))
        \(config("auto_balance", "off"))

        \(bar)

        # Breathing room around and between windows
        \(config("top_padding", "\(tiling.padding)"))
        \(config("bottom_padding", "\(tiling.padding)"))
        \(config("left_padding", "\(tiling.padding)"))
        \(config("right_padding", "\(tiling.padding)"))
        \(config("window_gap", "\(tiling.gap)"))

        # Hold option and drag: left button moves, right button resizes
        \(config("mouse_modifier", "alt"))
        \(config("mouse_action1", "move"))
        \(config("mouse_action2", "resize"))
        \(config("mouse_drop_action", "swap"))
        \(config("mouse_follows_focus", "off"))
        \(config("focus_follows_mouse", "off"))

        # Small utility windows float instead of tiling
        yabai -m rule --add app="^(\(floating))$" manage=off
        yabai -m rule --add app="^Finder$" title="^(Copy|Move|Connect|Info|Preferences|Settings).*" manage=off
        yabai -m rule --add title="^(Preferences|Settings|Open|Save)$" manage=off
        yabai -m rule --apply

        # After a window or app closes, focus whatever is under the mouse, else the first window
        refocus='yabai -m query --windows --window >/dev/null 2>&1 || yabai -m window --focus mouse >/dev/null 2>&1 || yabai -m window --focus "$(yabai -m query --windows --space | jq ".[0].id")" >/dev/null 2>&1'
        yabai -m signal --add event=window_destroyed active=yes action="$refocus"
        yabai -m signal --add event=application_terminated action="$refocus"

        [ -f "$HOME/.config/yabai/yabairc.local" ] && . "$HOME/.config/yabai/yabairc.local"
        echo "yabai configuration loaded"

        """
    }
}

/// JankyBorders: the glow around the active window.
public enum BordersConfig {
    /// The `key=value` arguments, as passed to `borders` to update it live.
    public static func options(_ glow: GlowSettings, palette: Palette) -> [String] {
        let color = glow.color(in: palette).argb()
        return [
            "style=\(glow.style.rawValue)",
            "width=\(String(format: "%.1f", glow.width))",
            "hidpi=on",
            "active_color=" + (glow.glow ? "glow(\(color))" : color),
            "inactive_color=\(palette.line.argb(0x26))",
            "blacklist=\(glow.ignoredApps.joined(separator: ","))"
        ]
    }

    public static func render(_ glow: GlowSettings, palette: Palette) -> String {
        let lines = options(glow, palette: palette).map { option -> String in
            guard let eq = option.firstIndex(of: "=") else { return option }
            let value = option[option.index(after: eq)...]
            // Anything a shell would read specially goes in quotes, with what's still special there escaped.
            let needsQuotes = value.contains { !($0.isLetter || $0.isNumber || "._:/%@+=-".contains($0)) }
            return needsQuotes ? "\(option[..<eq])=\"\(Shell.insideDoubleQuotes(String(value)))\"" : option
        }
        let colourNote = glow.useThemeColor ? "Colours follow the \(palette.name) theme." : "A custom glow colour."
        return """
        #!/bin/bash
        # Managed by Orbit (Windows page): a glowing outline around the window you're working in.
        # \(colourNote) Run this file to apply it again.
        options=(
        \(lines.map { "  " + $0 }.joined(separator: "\n"))
        )
        borders "${options[@]}"

        """
    }
}

/// SketchyBar: the floating menu bar.
public enum SketchyBarConfig {
    /// Seconds between runs of the stats items' scripts (Orbit slows them while it feeds them: `BarFeed`).
    public static let cpuFrequency = 3
    public static let memoryFrequency = 5
    public static let clockFrequency = 10

    public static func colors(_ p: Palette) -> String {
        """
        #!/bin/zsh
        # Managed by Orbit: the \(p.name) palette shared by the bar and its plugins (format 0xAARRGGBB).
        export BAR_COLOR=\(p.bgDark.argb(0xd9))
        export BAR_BORDER=\(p.accent.argb(0x40))
        export PILL=\(p.surface.argb())
        export FG=\(p.fg.argb())
        export MUTED=\(p.muted.argb())
        export DARK=\(p.bg.argb())
        export BLUE=\(p.accent.argb())
        export CYAN=\(p.cyan.argb())
        export PURPLE=\(p.accent2.argb())
        export GREEN=\(p.green.argb())
        export AMBER=\(p.yellow.argb())
        export RED=\(p.red.argb())

        """
    }

    public static func rc(_ bar: BarSettings, spaces: Int = 10) -> String {
        var out = #"""
        #!/bin/zsh
        # Managed by Orbit (Menu Bar page). Orbit notices hand edits and asks before replacing them.
        # Left: desktops and the current app. Centre: the Spotify track. Right: system stats and clock.
        # Click the Apple logo to open Orbit's quick panel.

        source "$CONFIG_DIR/colors.sh"
        PLUGINS="$CONFIG_DIR/plugins"
        FONT="JetBrainsMono Nerd Font"

        sketchybar --bar position=top height=\#(bar.height) y_offset=\#(bar.yOffset) margin=10 corner_radius=12 \
                         color=$BAR_COLOR border_width=1 border_color=$BAR_BORDER \
                         blur_radius=30 shadow=on sticky=on padding_left=8 padding_right=8

        sketchybar --default icon.font="$FONT:Bold:14.0" icon.color=$FG \
                             label.font="$FONT:Semibold:12.0" label.color=$FG \
                             padding_left=3 padding_right=3 \
                             icon.padding_left=6 icon.padding_right=4 \
                             label.padding_left=2 label.padding_right=8 \
                             background.height=24 background.corner_radius=8 \
                             scroll_texts=on

        # ── Left ──────────────────────────────────────────────────────────────────────
        sketchybar --add item apple left \
                   --set apple icon=$'' icon.font="$FONT:Bold:16.0" icon.color=$BLUE \
                         icon.padding_right=8 label.drawing=off click_script="open orbit://panel"

        """#
        if bar.showSpaces {
            out += #"""
            for i in {1..\#(spaces)}; do
              sketchybar --add space space.$i left \
                         --set space.$i associated_space=$i icon=$i \
                               icon.padding_left=7 icon.padding_right=7 icon.color=$MUTED \
                               label.drawing=off background.color=$BLUE background.drawing=off \
                               background.height=22 script="$PLUGINS/space.sh"
            done

            """#
        }
        if bar.showFrontApp {
            out += #"""
            sketchybar --add item divider left \
                       --set divider icon=$'│' icon.color=$MUTED label.drawing=off padding_left=6 padding_right=2 \
                       --add item front_app left \
                       --set front_app icon=$'' icon.color=$PURPLE label.font="$FONT:Bold:12.0" \
                             script="$PLUGINS/front_app.sh" \
                       --subscribe front_app front_app_switched

            """#
        }
        if bar.showSpotify {
            out += #"""
            # ── Centre: Spotify ───────────────────────────────────────────────────────────
            sketchybar --add event spotify_change com.spotify.client.PlaybackStateChanged \
                       --add item spotify center \
                       --set spotify icon=$'' icon.color=$GREEN label.max_chars=42 drawing=off \
                             script="$PLUGINS/spotify.sh" \
                       --subscribe spotify spotify_change

            """#
        }
        out += "# ── Right (listed right to left) ──────────────────────────────────────────────\n"
        var stats: [String] = []
        if bar.showClock {
            out += #"""
            sketchybar --add item clock right \
                       --set clock icon=$'' icon.color=$BLUE update_freq=\#(clockFrequency) script="$PLUGINS/clock.sh"

            """#
        }
        if bar.showNetwork {
            stats.append("wifi")
            out += #"""
            sketchybar --add item wifi right \
                       --set wifi icon=$'' icon.color=$CYAN update_freq=30 script="$PLUGINS/wifi.sh" \
                       --subscribe wifi wifi_change system_woke

            """#
        }
        if bar.showVolume {
            stats.append("volume")
            out += #"""
            sketchybar --add item volume right \
                       --set volume icon.color=$PURPLE script="$PLUGINS/volume.sh" \
                       --subscribe volume volume_change

            """#
        }
        if bar.showMemory {
            stats.append("memory")
            out += #"""
            sketchybar --add item memory right \
                       --set memory icon=$'' icon.color=$AMBER update_freq=\#(memoryFrequency) script="$PLUGINS/memory.sh"

            """#
        }
        if bar.showCPU {
            stats.append("cpu")
            out += #"""
            sketchybar --add item cpu right \
                       --set cpu icon=$'' icon.color=$GREEN update_freq=\#(cpuFrequency) script="$PLUGINS/cpu.sh"

            """#
        }
        if !stats.isEmpty {
            out += """
            sketchybar --add bracket stats \(stats.reversed().joined(separator: " ")) \\
                       --set stats background.color=$PILL background.height=26 background.corner_radius=9

            """
        }
        out += "sketchybar --update\n"
        return out
    }

    /// The plugin scripts the bar runs. Orbit writes any that are missing.
    public static let plugins: [String: String] = [
        "space.sh": #"""
        #!/bin/zsh
        # Highlights the desktop you're on.
        source "$CONFIG_DIR/colors.sh"
        if [ "$SELECTED" = true ]; then
          sketchybar --set "$NAME" background.drawing=on icon.color=$DARK
        else
          sketchybar --set "$NAME" background.drawing=off icon.color=$MUTED
        fi

        """#,
        "front_app.sh": #"""
        #!/bin/zsh
        # Shows the app you're using.
        [ "$SENDER" = front_app_switched ] && sketchybar --set "$NAME" label="$INFO"

        """#,
        "spotify.sh": #"""
        #!/bin/zsh
        # Shows the playing Spotify track; hides itself when paused or stopped.
        state=$(\#(Tool.jq) -r '.["Player State"] // empty' <<<"$INFO" 2>/dev/null)
        if [ "$state" = Playing ]; then
          track=$(\#(Tool.jq) -r '"\(.Name) · \(.Artist)"' <<<"$INFO")
          sketchybar --set "$NAME" drawing=on label="$track"
        else
          sketchybar --set "$NAME" drawing=off
        fi

        """#,
        "clock.sh": #"""
        #!/bin/zsh
        sketchybar --set "$NAME" label="$(date '+%a %d %b  %H:%M')"

        """#,
        "wifi.sh": #"""
        #!/bin/zsh
        # Local IP of the active connection, or "offline".
        source "$CONFIG_DIR/colors.sh"
        iface=$(/sbin/route -n get default 2>/dev/null | awk '/interface:/ {print $2}')
        ip=$([ -n "$iface" ] && /usr/sbin/ipconfig getifaddr "$iface")
        if [ -n "$ip" ]; then
          sketchybar --set "$NAME" label="$ip" icon.color=$CYAN
        else
          sketchybar --set "$NAME" label="offline" icon.color=$RED
        fi

        """#,
        "volume.sh": #"""
        #!/bin/zsh
        # Volume level with a matching speaker icon.
        vol=${INFO:-$(osascript -e 'output volume of (get volume settings)')}
        if   (( vol == 0 )); then icon=$''
        elif (( vol < 50 )); then icon=$''
        else icon=$''; fi
        sketchybar --set "$NAME" icon="$icon" label="${vol}%"

        """#,
        "memory.sh": #"""
        #!/bin/zsh
        # Memory in use (apps + wired + compressed), as Activity Monitor counts it.
        used=$(vm_stat | awk '/page size/ {p=$8} /Anonymous/ {a=$3} /purgeable/ {g=$3} /wired/ {w=$4} /occupied by compressor/ {c=$5}
                              END {printf "%.1f", (a-g+w+c)*p/1073741824}')
        sketchybar --set "$NAME" label="${used}G"

        """#,
        "cpu.sh": #"""
        #!/bin/zsh
        # Total CPU use across all cores; turns amber then red when busy.
        source "$CONFIG_DIR/colors.sh"
        cpu=$(/bin/ps -A -o %cpu= | awk -v n=$(sysctl -n hw.ncpu) '{s+=$1} END {v=s/n; printf "%d", (v>100?100:v)}')
        color=$GREEN; (( cpu > 70 )) && color=$AMBER; (( cpu > 90 )) && color=$RED
        sketchybar --set "$NAME" label="${cpu}%" icon.color=$color

        """#
    ]
}
