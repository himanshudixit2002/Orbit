import CryptoKit
import Foundation

/// The config files Orbit writes, and how to tell whether someone has edited one since.
public enum ManagedFile: String, Codable, CaseIterable, Sendable {
    case yabairc, bordersrc, sketchybarrc, sketchybarColors, karabiner, batTheme, batConfig, btopTheme,
         lazygit, fastfetch, tmuxTheme, sorterScript, warpTheme

    /// Scripts, which must stay runnable.
    public var isExecutable: Bool {
        [.yabairc, .bordersrc, .sketchybarrc, .sketchybarColors, .sorterScript].contains(self)
    }

    /// Orbit 1's files: the first baseline looked at these (and no others) before it kept a list.
    public static let first: [ManagedFile] = [.yabairc, .bordersrc, .sketchybarrc, .sketchybarColors, .karabiner, .batTheme,
                                              .batConfig, .btopTheme, .lazygit, .fastfetch, .tmuxTheme]

    public func url(_ paths: Paths) -> URL {
        switch self {
        case .yabairc: paths.yabairc
        case .bordersrc: paths.bordersrc
        case .sketchybarrc: paths.sketchybarrc
        case .sketchybarColors: paths.sketchybarColors
        case .karabiner: paths.karabinerJSON
        case .batTheme: paths.batTheme
        case .batConfig: paths.batConfig
        case .btopTheme: paths.btopTheme
        case .lazygit: paths.lazygitConfig
        case .fastfetch: paths.fastfetchConfig
        case .tmuxTheme: paths.tmuxTheme
        case .sorterScript: paths.sorterScript
        case .warpTheme: paths.warpTheme
        }
    }

    public var title: String {
        switch self {
        case .yabairc: "Window tiling settings"
        case .bordersrc: "Window glow settings"
        case .sketchybarrc: "Menu bar layout"
        case .sketchybarColors: "Menu bar colours"
        case .karabiner: "Caps Lock keys"
        case .batTheme, .batConfig: "Terminal code colours"
        case .btopTheme: "Activity monitor colours"
        case .lazygit: "Git app colours"
        case .fastfetch: "System splash colours"
        case .tmuxTheme: "Terminal window colours"
        case .sorterScript: "Downloads sorter"
        case .warpTheme: "Warp colours"
        }
    }

    /// Files whose owner app rewrites them itself, so a changed hash isn't a hand edit.
    public var ownerRewrites: Bool { self == .karabiner }

    /// Hashes of the versions written before Orbit existed: replacing these needs no question.
    public var knownHashes: Set<String> {
        switch self {
        case .yabairc: ["6bc607900353d6e02ca2af11f3dc5f5ea2008d151d227c89968a108ef16f7a47"]
        case .bordersrc: ["501148b706f4bccab15b882b5f51dcfaa36d6ad63eaaa63321d102d7c176ecec"]
        case .sketchybarrc: ["418d4ac83fddce1353e76e8a7216f423435e96c705f952ce9111e690111967ad"]
        case .sketchybarColors: ["3277de9565465c5f4318a9dfacf79017f179aa481977e74bbd4469bffd2abeeb"]
        case .batConfig: ["e22d59f5ba023ed11ba781727fb7ccace7be1fd644aa0b36b675af0c0f108890"]
        case .lazygit: ["6c49af3dbf7ce9f4e9468d1859653775a20abea06d1d587d90c148be8ef01b55"]
        case .fastfetch: ["1f0c3b92d74d841337edee95cd127bb4462be47c0d87ae81883a59910a7ec53a"]
        case .sorterScript: ["35951a697a700c8bc5ed13209802c4d5124e38db68288b2f26759681a17f99ec"]
        default: []
        }
    }
}

public enum Hashing {
    public static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// What Orbit last wrote to each file, so it can tell an edit made outside the app.
public struct FileRegistry: Codable, Sendable, Equatable {
    public var lastWritten: [ManagedFile: String] = [:]
    /// What the real Orbit last wrote, which practice mode accepts too (it reads the real files until it
    /// has copies of its own). Not saved.
    public var alsoWritten: [ManagedFile: String] = [:]

    public init() {}

    private enum CodingKeys: String, CodingKey { case lastWritten }

    public enum Verdict: Sendable, Equatable {
        case safe          // missing, written by Orbit, or a known earlier version
        case editedByHand  // changed since: ask before replacing
    }

    public func verdict(for file: ManagedFile, current: Data?, adoptable: Set<String> = []) -> Verdict {
        guard let current else { return .safe }
        let hash = Hashing.sha256(current)
        if file.ownerRewrites { return .safe }
        if lastWritten[file] == hash || alsoWritten[file] == hash || file.knownHashes.contains(hash) || adoptable.contains(hash) { return .safe }
        return .editedByHand
    }
}
