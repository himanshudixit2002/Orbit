import Foundation

/// Which folder in Downloads a kind of file goes to.
public struct DownloadRule: Codable, Sendable, Equatable, Identifiable {
    public var folder: String
    /// Lower-case, without the dot.
    public var extensions: [String]

    public var id: String { folder }

    public init(folder: String, extensions: [String]) {
        self.folder = folder
        self.extensions = extensions
    }

    private enum CodingKeys: String, CodingKey { case folder, extensions }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        folder = try c.decode(String.self, forKey: .folder)
        extensions = c.value(.extensions, or: [])
    }

    /// The hourly sorter's table from before Orbit.
    public static let defaults: [DownloadRule] = [
        DownloadRule(folder: "Documents", extensions: "pdf doc docx txt md rtf pages key numbers ppt pptx xls xlsx csv epub tex".split(separator: " ").map(String.init)),
        DownloadRule(folder: "Images", extensions: "png jpg jpeg gif webp heic svg tiff bmp ico avif".split(separator: " ").map(String.init)),
        DownloadRule(folder: "Media", extensions: "mp3 wav m4a aac flac mp4 mov mkv avi webm".split(separator: " ").map(String.init)),
        DownloadRule(folder: "Archives", extensions: "zip tar gz tgz bz2 xz rar 7z".split(separator: " ").map(String.init)),
        DownloadRule(folder: "Installers", extensions: ["dmg", "pkg", "app"]),
        DownloadRule(folder: "Code", extensions: "json yaml yml toml py js ts tsx sh html css sql ipynb go rs java c cpp h swift dart".split(separator: " ").map(String.init)),
        DownloadRule(folder: "Links", extensions: ["webloc", "url"])
    ]
}

public struct DownloadSettings: Codable, Sendable, Equatable {
    /// Sort each download as soon as it's finished, while Orbit runs (the hourly pass is the backup).
    public var instant = true
    /// A download counts as finished once it hasn't changed for this long.
    public var settleSeconds = 10
    public var rules = DownloadRule.defaults
    /// Where files no rule names go.
    public var otherFolder = "Other"

    public init() {}
}

/// Decides which loose files in Downloads move where. Never overwrites: a name that's taken gets
/// " (2)", " (3)"… as the hourly sorter always did.
public enum DownloadSorter {
    public struct Item: Sendable, Equatable {
        public var name: String
        public var isFile: Bool
        public var modified: Date

        public init(name: String, isFile: Bool, modified: Date) {
            self.name = name
            self.isFile = isFile
            self.modified = modified
        }
    }

    public struct Move: Sendable, Equatable {
        public var name: String
        public var folder: String
        /// The name in the folder (differs when the name was taken).
        public var destination: String

        public var path: String { "\(folder)/\(destination)" }
    }

    /// Hidden files and downloads still in progress stay where they are.
    public static func skips(_ name: String) -> Bool {
        if name.hasPrefix(".") { return true }
        return [".crdownload", ".download", ".part", ".partial", ".tmp"].contains { name.lowercased().hasSuffix($0) }
    }

    public static func folder(for name: String, in settings: DownloadSettings) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        return settings.rules.first { $0.extensions.contains(ext) }?.folder ?? settings.otherFolder
    }

    /// "report.pdf" → "report (2).pdf", "notes" → "notes (2)", until one is free.
    public static func freeName(_ name: String, taken: (String) -> Bool) -> String {
        guard taken(name) else { return name }
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        for n in 2... {
            let candidate = ext.isEmpty ? "\(name) (\(n))" : "\(base) (\(n)).\(ext)"
            if !taken(candidate) { return candidate }
        }
        return name
    }

    /// The files to move now (finished: unchanged for `settle`), and when to look again for the rest.
    /// `taken` says whether a name is already used in a folder.
    public static func plan(_ items: [Item], settings: DownloadSettings, now: Date, settle: TimeInterval,
                            taken: (_ folder: String, _ name: String) -> Bool) -> (moves: [Move], lookAgain: Date?) {
        var moves: [Move] = []
        var lookAgain: Date?
        var claimed = Set<String>()
        for item in items.sorted(by: { $0.name.localizedStandardCompare($1.name) == .orderedAscending })
        where item.isFile && !skips(item.name) {
            let ready = item.modified.addingTimeInterval(settle)
            guard ready <= now else {
                lookAgain = min(lookAgain ?? ready, ready)
                continue
            }
            let folder = folder(for: item.name, in: settings)
            let destination = freeName(item.name) { taken(folder, $0) || claimed.contains("\(folder)/\($0)") }
            claimed.insert("\(folder)/\(destination)")
            moves.append(Move(name: item.name, folder: folder, destination: destination))
        }
        return (moves, lookAgain)
    }

    /// A line in sort-downloads.log, as the hourly sorter writes it.
    public static func logLine(_ move: Move, at date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return "\(formatter.string(from: date))  \(move.name) -> \(move.path)"
    }
}

/// The hourly sorter (~/.local/bin/sort-downloads), written from the same rules as Orbit's instant
/// sorting. It stands down while Orbit sorts (Orbit's pid file names a running process).
public enum SorterScript {
    public static func render(_ settings: DownloadSettings) -> String {
        func clean(_ ext: String) -> String { ext.lowercased().filter { $0.isLetter || $0.isNumber } }
        let cases = settings.rules.compactMap { rule -> String? in
            let extensions = rule.extensions.map(clean).filter { !$0.isEmpty }
            guard !extensions.isEmpty else { return nil }
            return "    \(extensions.joined(separator: "|"))) echo \(Shell.quote(rule.folder)) ;;"
        }
        return """
        #!/bin/zsh
        # Managed by Orbit (Files page): files loose items in ~/Downloads into subfolders by type. Runs hourly
        # via ~/Library/LaunchAgents/com.himanshu.sort-downloads.plist; safe to run by hand. While Orbit is
        # running it sorts each download as soon as it's finished, and this backup pass stands down.
        # Never deletes or overwrites. Leaves folders, hidden files, in-progress downloads, and anything
        # newer than an hour (so browsers can still find it).
        setopt null_glob extended_glob
        DL=$HOME/Downloads
        AGE_MIN=${SORT_DOWNLOADS_MIN_AGE:-60}

        pid=$(/bin/cat "$HOME/Library/Application Support/Orbit/instant-sort.pid" 2>/dev/null)
        if [[ $pid == <-> ]] && (( pid > 0 )) && kill -0 $pid 2>/dev/null; then
          exit 0
        fi

        category() {
          case ${1:l} in
        \(cases.joined(separator: "\n"))
            *) echo \(Shell.quote(settings.otherFolder)) ;;
          esac
        }

        if ! /bin/ls "$DL" >/dev/null 2>&1; then
          echo "$(date '+%F %T')  cannot read $DL: give zsh access under Privacy & Security > Files and Folders"
          exit 1
        fi
        # Got in: leave a mark, so Orbit can tell an old permission error is over even when there's nothing to sort.
        /usr/bin/touch "$HOME/Library/Logs/sort-downloads.checked"

        KEEP="$HOME/Library/Application Support/Orbit/downloads-keep.txt"
        now=$(date +%s)
        for f in $DL/*(.N); do
          name=${f:t}
          case $name in
            .*|*.crdownload|*.download|*.part|*.partial|*.tmp) continue ;;
          esac
          # Put back by hand in Orbit: stays.
          [[ -f $KEEP ]] && /usr/bin/grep -qxF -- "$name" "$KEEP" && continue
          (( now - $(/usr/bin/stat -f %m "$f") < AGE_MIN * 60 )) && continue
          dir=$DL/$(category "${name:e}")
          mkdir -p "$dir"
          dst=$dir/$name
          ext=${name:e}
          n=2
          while [[ -e $dst ]]; do
            if [[ -n $ext ]]; then dst="$dir/${name:r} ($n).$ext"; else dst="$dir/$name ($n)"; fi
            (( n++ ))
          done
          mv -n "$f" "$dst" && echo "$(date '+%F %T')  $name -> ${dst#$DL/}"
        done
        exit 0

        """
    }
}
