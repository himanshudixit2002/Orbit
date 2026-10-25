import Foundation

public enum TmuxPlugins {
    /// The plugins tmux.conf asks for, by folder name: `set -g @plugin 'tmux-plugins/tmux-yank'` → "tmux-yank".
    public static func declared(in conf: String) -> [String] {
        conf.split(separator: "\n").compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#"), line.hasPrefix("set") || line.hasPrefix("set-option"), line.contains("@plugin") else { return nil }
            guard let start = line.firstIndex(where: { $0 == "'" || $0 == "\"" }) else { return nil }
            let rest = line[line.index(after: start)...]
            guard let end = rest.firstIndex(of: line[start]) else { return nil }
            let repo = rest[..<end]
            return repo.split(separator: "/").last.map(String.init)
        }
    }
}
