import Foundation

/// How much a command changes on the Mac. Practice mode runs only `.readOnly` commands;
/// everything else goes to the practice log instead.
public enum SideEffect: String, Sendable, Codable, CaseIterable {
    case readOnly       // looks, never changes anything
    case userFiles      // writes the user's own config files or caches
    case systemSetting  // Dock, Finder, menu bar and other macOS settings
    case service        // starts, stops or reconfigures a background helper
    case appControl     // opens, installs or quits an app
    case display        // only updates what a running helper shows (the menu bar's numbers)
    case admin          // needs the administrator password
}

/// One program to run, with what's needed to run it safely and to explain it in plain English.
public struct Command: Sendable, Hashable {
    public var executable: String
    public var arguments: [String]
    public var effect: SideEffect
    public var summary: String
    public var timeout: TimeInterval
    /// Exit codes that count as success, such as "already running".
    public var okStatuses: Set<Int32>
    /// Off for commands whose children may keep the output pipe open (they'd never finish).
    public var captureOutput: Bool

    public init(_ executable: String, _ arguments: [String] = [], effect: SideEffect, summary: String,
                timeout: TimeInterval = 20, okStatuses: Set<Int32> = [0], captureOutput: Bool = true) {
        self.executable = executable
        self.arguments = arguments
        self.effect = effect
        self.summary = summary
        self.timeout = timeout
        self.okStatuses = okStatuses
        self.captureOutput = captureOutput
    }

    /// The command as you would type it in Terminal.
    public var commandLine: String {
        ([executable] + arguments).map(Shell.quote).joined(separator: " ")
    }
}

public struct CommandResult: Sendable, Equatable {
    public var status: Int32
    public var stdout: String
    public var stderr: String
    public var timedOut: Bool
    public var simulated: Bool
    public var ok: Bool

    public init(status: Int32, stdout: String = "", stderr: String = "", timedOut: Bool = false,
                simulated: Bool = false, ok: Bool) {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
        self.timedOut = timedOut
        self.simulated = simulated
        self.ok = ok
    }

    public static let simulatedSuccess = CommandResult(status: 0, simulated: true, ok: true)

    public static func launchFailure(_ message: String) -> CommandResult {
        CommandResult(status: -1, stderr: message, ok: false)
    }

    /// The most useful line to show when something went wrong.
    public var failureMessage: String {
        if timedOut { return "It took too long and was stopped." }
        let text = (stderr.isEmpty ? stdout : stderr).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.split(separator: "\n").last.map(String.init) ?? "It stopped with code \(status)."
    }
}

public enum Shell {
    /// Quotes `s` for a POSIX shell when it contains anything beyond plain characters.
    public static func quote(_ s: String) -> String {
        if !s.isEmpty, s.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || "@%_+=:,./-".unicodeScalars.contains($0) }) {
            return s
        }
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Escapes `s` for use inside a regular expression (yabai rules match app names by regex).
    public static func regexEscape(_ s: String) -> String {
        var out = ""
        for ch in s {
            if "\\^$.|?*+()[]{}".contains(ch) { out.append("\\") }
            out.append(ch)
        }
        return out
    }

    /// Escapes `s` for use between double quotes in a shell script, where " $ ` still mean something, and so
    /// does a backslash before one of them (or at the end). Other backslashes are kept by the shell as they
    /// are, so they're left alone and ordinary text comes out unchanged.
    public static func insideDoubleQuotes(_ s: String) -> String {
        let chars = Array(s)
        var out = ""
        for (i, ch) in chars.enumerated() {
            switch ch {
            case "$", "`", "\"":
                out += "\\" + String(ch)
            case "\\":
                out += i + 1 == chars.count || "$`\"\\\n".contains(chars[i + 1]) ? "\\\\" : "\\"
            default:
                out.append(ch)
            }
        }
        return out
    }

    /// Escapes `s` for an AppleScript string literal.
    public static func appleScriptString(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
