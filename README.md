# Orbit

One native Mac app for everything that makes this Mac feel like yours: windows that arrange themselves, a glow on the one you're using, a floating menu bar, Caps Lock superpowers, Downloads that sort themselves, one-click themes and modes, and a faster, tidier Mac. Every change it makes can be undone.

Orbit lives in the menu bar. Its window opens when you want it and lets go of its memory when you close it.

## What it does

| Page | What you get |
| --- | --- |
| **Home** | Your Mac at a glance, quick switches, and Pause: one click switches off everything Orbit runs, one click brings it back exactly as it was. |
| **Style** | One look for the whole Mac in a click: theme, accent colour, wallpaper, terminal and editor colours. |
| **Windows** | Tiling with yabai and skhd, window layouts per desktop, and a glow on the window in front (JankyBorders). |
| **Menu Bar** | A floating SketchyBar menu bar with the items you choose, at the top or bottom. |
| **Keyboard** | Caps Lock as Escape when tapped and Hyper when held (Karabiner-Elements), Hyper + a letter to open an app. |
| **Files** | Downloads sorted the moment they land, with an hourly sorter as backup. |
| **Modes** | Work, Focus, Chill, Present or your own: apps, switches, theme, keep-awake, timers and schedules in one click. |
| **Shortcuts** | ⌘K / Hyper+Space command palette, Siri and Shortcuts, desktop widgets, Control Center switches and `orbit://` links. |
| **Developer** | Your projects with their git state, Homebrew services, and what's listening on which port. |
| **Monitor** | Processor, memory, disk and network, live. |
| **Speed** | Instant Mac (no waiting on window, sheet, Dock and Finder animations), a Speed check that finds what slows the Mac, the apps using the most, memory explained in plain words (with the virtual machines that hold it, such as Colima's), notices for apps left busy in the background, and how long each restart took. |
| **Storage** | Where your disk space goes, your apps by size and when you last opened them, the largest files, and caches that clear safely. |
| **Dock & Finder** | A tidy Dock and Finder options. |
| **Apps** | Helper apps (Raycast, AltTab, Ice, Syntax Highlight) and the permissions they need. |
| **Health & Undo** | The Doctor checks everything is working; the history undoes any change Orbit made. |

## The rules Orbit keeps

- **Every change has Undo**, from the history or the notice that reports it. A change cut short (Orbit quit, the Mac restarted) can still be undone.
- **Nothing is deleted for good.** What Orbit clears goes to the Trash; you empty it.
- **No password prompts.** Orbit never asks for an administrator password. What needs one (removing an App Store app, deleting system files) Orbit shows you in Finder.
- **You flip your own system settings.** For Siri, Full Disk Access and other privacy settings, Orbit opens the exact pane.
- **Edited by hand stays yours.** A config file you changed yourself is never overwritten without showing you the difference first.
- **Quiet and light.** At login Orbit starts in the menu bar and waits until the Mac has settled before doing anything optional.

## Performance

Measured on an iMac (M4, 16 GB), macOS 27:

- At rest in the menu bar: about 0.1% of one core, about one wake-up every eight seconds, and 21 MB of memory after launch.
- Its window lets go of every page when closed: 97 MB open, 77 MB once closed (what remains is SwiftUI's own fixed cost).
- Storage measures the 80 GB of folders it can see without Full Disk Access in 5 to 7 seconds, walking each folder's contents side by side, the way `du` does.
- Changes run one at a time, in the order they were asked for.

## Building

Needs macOS 27 and Xcode with the macOS 27 SDK. The helpers (yabai, skhd, SketchyBar, JankyBorders) come from Homebrew; Karabiner-Elements and the helper apps can be installed from inside Orbit.

```bash
Scripts/test.sh                 # unit tests, an app build and the code guards
Scripts/build.sh                # Orbit.app in .build/
Scripts/build.sh --dev          # "Orbit Dev": practice mode, changes nothing on the Mac
Scripts/install.sh --background # to /Applications, restarted quietly in the menu bar
```

`Orbit Dev` always runs in practice mode: changes are only written down (Health page), files go to a practice folder, and its state is kept apart from the real Orbit's. Use it to try anything.

## How it's put together

| Module | Role |
| --- | --- |
| `OrbitCore` | Pure logic: settings, themes, config generators, parsers, rules (Speed check, Storage, Pause). No system access. |
| `OrbitPlatform` | The only code that touches the system: processes, files, preferences, launchd, the change lane and its undo journal. |
| `OrbitUI` | The SwiftUI pages, menu bar panel, palette and guided setup. |
| `OrbitShared` | The status snapshot the sandboxed widget extension reads. |
| `OrbitIntents`, `OrbitWidgets` | App Intents (Siri, Shortcuts, Focus) and the widgets and Control Center switches, built by Xcode. |
