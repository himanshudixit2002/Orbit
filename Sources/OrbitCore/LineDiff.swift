import Foundation

/// A line-by-line comparison of two versions of a file, for the "show differences" view.
public enum LineDiff {
    public enum Kind: Sendable, Equatable {
        case same, removed, added
    }

    public struct Line: Sendable, Equatable {
        public let kind: Kind
        public let text: String

        public init(_ kind: Kind, _ text: String) {
            self.kind = kind
            self.text = text
        }
    }

    /// What changes going from `old` to `new`, found with a longest-common-subsequence table.
    public static func diff(_ old: String, _ new: String) -> [Line] {
        var a = old.components(separatedBy: "\n")
        var b = new.components(separatedBy: "\n")
        // A final newline isn't a line of its own.
        if a.last == "" { a.removeLast() }
        if b.last == "" { b.removeLast() }
        let n = a.count, m = b.count
        // Very large files: show them as replaced rather than spend seconds comparing.
        guard n * m <= 4_000_000 else { return a.map { Line(.removed, $0) } + b.map { Line(.added, $0) } }
        var table = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                table[i][j] = a[i] == b[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var out: [Line] = []
        var i = 0, j = 0
        while i < n, j < m {
            if a[i] == b[j] {
                out.append(Line(.same, a[i]))
                i += 1
                j += 1
            } else if table[i + 1][j] >= table[i][j + 1] {
                out.append(Line(.removed, a[i]))
                i += 1
            } else {
                out.append(Line(.added, b[j]))
                j += 1
            }
        }
        out += a[i...].map { Line(.removed, $0) }
        out += b[j...].map { Line(.added, $0) }
        return out
    }

    public enum Row: Sendable, Equatable {
        case line(Line)
        /// A run of unchanged lines folded away.
        case skipped(Int)
    }

    /// Folds long runs of unchanged lines, keeping `context` lines around each change.
    public static func condensed(_ lines: [Line], context: Int = 3) -> [Row] {
        let changed = lines.indices.filter { lines[$0].kind != .same }
        guard !changed.isEmpty else { return lines.isEmpty ? [] : [.skipped(lines.count)] }
        var keep = Set<Int>()
        for index in changed {
            for k in max(0, index - context)...min(lines.count - 1, index + context) { keep.insert(k) }
        }
        var rows: [Row] = []
        var skipped = 0
        for index in lines.indices {
            if keep.contains(index) {
                if skipped > 0 { rows.append(.skipped(skipped)) }
                skipped = 0
                rows.append(.line(lines[index]))
            } else {
                skipped += 1
            }
        }
        if skipped > 0 { rows.append(.skipped(skipped)) }
        return rows
    }
}

/// Where "Tidy the Desktop" puts each kind of file. Folders and apps on the Desktop are left alone.
public enum DesktopTidy {
    public enum Destination: String, CaseIterable, Sendable {
        case notes = "Documents/Notes"
        case media = "Documents/Media"
        case links = "Documents/Links"
        case other = "Documents/From Desktop"

        public var title: String {
            switch self {
            case .notes: "Notes"
            case .media: "Pictures, videos and audio"
            case .links: "Web links"
            case .other: "Everything else"
            }
        }

        public var symbol: String {
            switch self {
            case .notes: "note.text"
            case .media: "photo.on.rectangle.angled"
            case .links: "link"
            case .other: "tray.full.fill"
            }
        }
    }

    public static func destination(for fileName: String) -> Destination {
        switch (fileName as NSString).pathExtension.lowercased() {
        case "txt", "md", "markdown", "rtf", "rtfd":
            .notes
        case "png", "jpg", "jpeg", "heic", "gif", "webp", "tif", "tiff", "bmp", "svg", "mp4", "mov", "m4v", "mp3", "wav",
             "m4a", "aac", "flac", "aiff":
            .media
        case "webloc", "url", "inetloc":
            .links
        default:
            .other
        }
    }

    /// `name`, or `name 2`, `name 3`… so nothing already in the folder is overwritten.
    public static func freeName(_ fileName: String, taken: (String) -> Bool) -> String {
        guard taken(fileName) else { return fileName }
        let base = (fileName as NSString).deletingPathExtension
        let ext = (fileName as NSString).pathExtension
        var n = 2
        while true {
            let candidate = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
            if !taken(candidate) { return candidate }
            n += 1
        }
    }
}
