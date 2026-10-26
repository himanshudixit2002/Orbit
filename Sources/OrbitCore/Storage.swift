import Foundation

/// One part of the disk on the Storage page: what it holds and how much.
public struct StorageArea: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable, CaseIterable {
        case apps, developer, projects, files, media, iCloud, appData, home, trash, system, free
    }

    public var kind: Kind
    public var size: Int64
    /// macOS keeps it from Orbit (Full Disk Access is off), so its size is counted in "macOS and the rest".
    public var hidden: Bool

    public init(kind: Kind, size: Int64, hidden: Bool = false) {
        self.kind = kind
        self.size = size
        self.hidden = hidden
    }

    public var id: Kind { kind }
}

extension StorageArea.Kind {
    public var title: String {
        switch self {
        case .apps: "Apps"
        case .developer: "Developer tools"
        case .projects: "Your projects"
        case .files: "Desktop, Documents and Downloads"
        case .media: "Photos, movies and music"
        case .iCloud: "iCloud Drive on this Mac"
        case .appData: "Apps' own data"
        case .home: "The rest of your home folder"
        case .trash: "Trash"
        case .system: "macOS and the rest"
        case .free: "Free"
        }
    }

    public var symbol: String {
        switch self {
        case .apps: "square.grid.2x2.fill"
        case .developer: "hammer.fill"
        case .projects: "folder.fill"
        case .files: "doc.fill"
        case .media: "photo.fill"
        case .iCloud: "icloud.fill"
        case .appData: "tray.full.fill"
        case .home: "house.fill"
        case .trash: "trash.fill"
        case .system: "apple.logo"
        case .free: "circle.dashed"
        }
    }

    /// What's in it, in a line.
    public var blurb: String {
        switch self {
        case .apps: "Everything in Applications."
        case .developer: "Homebrew, Flutter, Android and Xcode tools, package caches."
        case .projects: "Your code folders, with their build folders."
        case .files: "What you keep and download."
        case .media: "The Photos library, movies and music."
        case .iCloud: "Files from iCloud Drive kept on this Mac."
        case .appData: "Mail, messages, chats, and what each app stores for itself."
        case .home: "Other folders in your home folder, such as AI models and tools' own data."
        case .trash: "Gone for good only when you empty it."
        case .system: "macOS itself, its caches, and anything Orbit can't see into."
        case .free: "Room to spare."
        }
    }
}

public enum StorageMap {
    /// Where each area lives: "~/…" in the home folder, else an absolute path.
    public static func paths(_ kind: StorageArea.Kind) -> [String] {
        switch kind {
        case .apps: ["/Applications", "~/Applications"]
        case .developer:
            ["/opt/homebrew", "~/Library/Android", "~/Library/Developer", "/Library/Developer", "~/.gradle", "~/.cargo", "~/.rustup",
             "~/go", "~/.npm", "~/.cache", "~/.bun", "~/.nvm", "~/.pyenv", "~/.pub-cache", "~/flutter", "~/.local", "~/.android",
             "~/.cocoapods", "~/.m2", "~/.dartServer", "~/.vscode", "~/.antigravity", "~/.claude", "~/.codex",
             "~/.colima", "~/.lima", "~/.docker", "~/.ollama", "~/.minikube", "~/.vagrant.d", "~/.rbenv", "~/.sdkman",
             "~/.deno", "~/.yarn",
             // Xcode's simulators: macOS keeps each runtime as one disk image here.
             "/System/Library/AssetsV2/com_apple_MobileAsset_iOSSimulatorRuntime",
             "/System/Library/AssetsV2/com_apple_MobileAsset_watchOSSimulatorRuntime",
             "/System/Library/AssetsV2/com_apple_MobileAsset_tvOSSimulatorRuntime",
             "/System/Library/AssetsV2/com_apple_MobileAsset_xrOSSimulatorRuntime"]
        case .projects: ["~/Developer", "~/Projects", "~/Code", "~/src", "~/StudioProjects", "~/AndroidStudioProjects"]
        case .files: ["~/Desktop", "~/Documents", "~/Downloads"]
        case .media: ["~/Pictures", "~/Movies", "~/Music"]
        case .iCloud: ["~/Library/Mobile Documents"]
        case .appData: ["~/Library"]
        case .trash: ["~/.Trash"]
        case .home, .system, .free: []
        }
    }

    /// Folders in ~/Library counted elsewhere, so "Apps' own data" leaves them out.
    public static let libraryCountedElsewhere: Set<String> = ["Android", "Developer", "Mobile Documents"]
    /// The folders in ~/Library Orbit looks in without Full Disk Access: ones macOS never asks about.
    /// Looking into some of the others (apps' containers) makes macOS ask about every app.
    public static let libraryWithoutFullAccess: Set<String> = ["Application Support", "Caches", "Logs", "Preferences", "Saved Application State",
                                                               "WebKit", "HTTPStorages", "Fonts", "Autosave Information", "LaunchAgents",
                                                               "Services", "Sounds", "Spelling", "Screen Savers", "Frameworks"]
    /// Areas only Full Disk Access lets Orbit look into (looking without it would bring up macOS's questions).
    public static let needsFullAccess: Set<StorageArea.Kind> = [.files, .media, .iCloud, .trash]

    /// The whole disk, biggest areas first: what was measured, then macOS and everything Orbit couldn't
    /// see as the rest of what's used, then free space. Areas Orbit couldn't look into show as hidden.
    public static func areas(measured: [StorageArea.Kind: Int64], hidden: Set<StorageArea.Kind>, used: Int64, free: Int64) -> [StorageArea] {
        let seen = measured.filter { !hidden.contains($0.key) && $0.value > 0 }
        let parts = seen.map { StorageArea(kind: $0.key, size: $0.value) }.sorted { ($0.size, $0.kind.rawValue) > ($1.size, $1.kind.rawValue) }
        let rest = max(0, used - seen.values.reduce(0, +))
        let hiddenAreas = StorageArea.Kind.allCases.filter(hidden.contains).map { StorageArea(kind: $0, size: 0, hidden: true) }
        return parts + [StorageArea(kind: .system, size: rest)] + hiddenAreas + [StorageArea(kind: .free, size: max(0, free))]
    }
}

/// An app in Applications, how big it is and when it was last opened.
public struct InstalledAppSize: Sendable, Equatable, Identifiable {
    public var name: String
    public var path: String
    public var bundleID: String?
    public var size: Int64
    public var lastUsed: Date?
    /// You can move it to the Trash yourself; apps the App Store installed belong to macOS, which asks
    /// for your password to remove them.
    public var removable: Bool
    public var running: Bool

    public init(name: String, path: String, bundleID: String?, size: Int64, lastUsed: Date?, removable: Bool, running: Bool) {
        self.name = name
        self.path = path
        self.bundleID = bundleID
        self.size = size
        self.lastUsed = lastUsed
        self.removable = removable
        self.running = running
    }

    public var id: String { path }

    /// "Opened today", "Last opened 3 weeks ago", "Not opened since July", "Never opened".
    public func lastUsedText(now: Date = Date(), calendar: Calendar = .current) -> String {
        guard let lastUsed else { return "Never opened" }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: lastUsed), to: calendar.startOfDay(for: now)).day ?? 0
        switch days {
        case ..<1: return "Opened today"
        case 1: return "Opened yesterday"
        case 2..<14: return "Last opened \(days) days ago"
        case 14..<60: return "Last opened \(days / 7) weeks ago"
        default:
            let month = lastUsed.formatted(.dateTime.month(.wide).year())
            let sameYear = calendar.component(.year, from: lastUsed) == calendar.component(.year, from: now)
            return "Not opened since \(sameYear ? lastUsed.formatted(.dateTime.month(.wide)) : month)"
        }
    }

    /// Not opened for two months or more (or never).
    public func unused(now: Date = Date()) -> Bool {
        lastUsed.map { now.timeIntervalSince($0) > 60 * 86_400 } ?? true
    }
}

/// A big file somewhere in your home folder.
public struct LargeFile: Sendable, Equatable, Identifiable {
    public var path: String
    public var size: Int64
    public var modified: Date?

    public init(path: String, size: Int64, modified: Date?) {
        self.path = path
        self.size = size
        self.modified = modified
    }

    public var id: String { path }
    public var name: String { URL(fileURLWithPath: path).lastPathComponent }

    /// Inside a bundle or library (an app, the Photos library, an iMovie library…): part of something
    /// bigger, never moved on its own.
    public var package: String? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard let index = parts.dropLast().firstIndex(where: { part in LargeFiles.packageTypes.contains { part.hasSuffix($0) } }) else { return nil }
        return parts[...index].joined(separator: "/")
    }

    /// Yours to move to the Trash: in your home folder, not part of a bundle, not app data in ~/Library
    /// and not in a tool's hidden folder (a model, a cache: the tool's to manage).
    public func movable(home: String) -> Bool {
        guard package == nil, path.hasPrefix(home + "/"), !path.hasPrefix(home + "/Library/") else { return false }
        return !path.dropFirst(home.count + 1).split(separator: "/").dropLast().contains { $0.hasPrefix(".") }
    }
}

public enum LargeFiles {
    /// The size worth listing.
    public static let atLeast: Int64 = 500_000_000
    static let packageTypes = [".app", ".photoslibrary", ".imovielibrary", ".fcpbundle", ".musiclibrary", ".tvlibrary", ".xcarchive",
                               ".logicx", ".band", ".photolibrary", ".aplibrary", ".utm", ".pvm", ".vmwarevm", ".bundle", ".framework"]
}

/// Where the Mac's memory goes, from macOS's own counts.
public struct MemoryBreakdown: Sendable, Equatable {
    public var total: UInt64 = 0
    /// What apps hold for themselves.
    public var apps: UInt64 = 0
    /// What macOS itself must keep (it can't be moved or compressed).
    public var wired: UInt64 = 0
    /// Squeezed to make room.
    public var compressed: UInt64 = 0
    /// Recently used files, kept to make things quick; handed back the moment an app needs memory.
    public var cached: UInt64 = 0
    public var free: UInt64 = 0
    public var swap: UInt64 = 0
    /// 1 normal, 2 warning, 4 critical.
    public var pressure = 1

    public init() {}

    /// Free right away, or as soon as something asks: free plus cached files.
    public var available: UInt64 { free + cached }

    /// How it's going, in a sentence.
    public var summary: String {
        let gb = { (bytes: UInt64) in ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory) }
        if pressure >= 4 {
            return "Memory is very tight: the Mac is moving memory to disk (\(gb(swap)) so far), which slows everything. Quit apps you're not using."
        }
        if pressure >= 2 {
            return "Memory is getting tight: macOS is squeezing apps' memory to make room. Quitting an app you're not using helps."
        }
        if tight {
            return "Memory has been tight: \(gb(swap)) was moved to disk, and getting it back is slow. Quitting an app you're not using helps."
        }
        return "Memory is fine: \(gb(available)) of \(gb(total)) is free or can be freed at once\(swap > 512 * 1_048_576 ? ", though \(gb(swap)) was moved to disk earlier" : "")."
    }

    /// Tight as the Speed check counts it: macOS says so, or it has moved a lot to disk.
    public var tight: Bool { SpeedCheck.memoryTight(pressure: pressure, swapUsed: swap) }
}

/// A virtual machine running on the Mac (Colima's Linux machine for containers, say) and the memory it holds.
public struct VirtualMachineUsage: Sendable, Equatable, Identifiable {
    public var pid: Int32
    public var name: String
    public var memory: UInt64
    /// Colima's: Orbit can stop it (and start it again with Undo).
    public var isColima: Bool

    public init(pid: Int32, name: String, memory: UInt64, isColima: Bool) {
        self.pid = pid
        self.name = name
        self.memory = memory
        self.isColima = isColima
    }

    public var id: Int32 { pid }
}

public enum VirtualMachines {
    /// macOS runs each virtual machine in a process of its own, outside any app, so the apps list misses them.
    /// Found by program: macOS cuts process names short ("com.apple.Virtu").
    public static func find(_ stats: [ProcessStat], colimaInstalled: Bool) -> [VirtualMachineUsage] {
        let colima = colimaInstalled && stats.contains { $0.name == "limactl" }
        return stats.filter { $0.path.hasSuffix("/com.apple.Virtualization.VirtualMachine") }.sorted { $0.memory > $1.memory }.enumerated().map { index, vm in
            // Colima's is the one limactl keeps running: with several machines, the biggest is taken as its.
            let isColima = colima && index == 0
            return VirtualMachineUsage(pid: vm.pid, name: isColima ? "Colima's Linux machine" : "A virtual machine", memory: vm.memory, isColima: isColima)
        }
    }
}

public enum IdleApps {
    /// Apps worth quitting to free memory: ones Orbit may quit, not used for an hour, holding a fair amount.
    public static let idleMinutes = 60.0
    public static let atLeast: UInt64 = 200 * 1_048_576

    public static func toQuit(_ apps: [AppUsage]) -> [AppUsage] {
        apps.filter { SpeedCheck.quittable($0) && !AppGrouping.isTerminal($0.path) && ($0.idleMinutes ?? 0) >= idleMinutes && $0.memory >= atLeast }
            .sorted { $0.memory > $1.memory }
    }
}
