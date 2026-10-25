import AppKit
import Foundation
import OrbitCore

extension Actions {
    /// Fills in bundle ids so the Caps Lock shortcuts open apps by id (they survive renames).
    public func resolved(_ bindings: [HyperBinding]) -> [HyperBinding] {
        bindings.map { binding in
            var b = binding
            if b.bundleID == nil, !b.appPath.isEmpty, let bundle = Bundle(path: b.appPath) { b.bundleID = bundle.bundleIdentifier }
            return b
        }
    }

    public func applyKeyboard(_ keyboard: KeyboardSettings) async throws -> ActionOutcome {
        var settled = keyboard
        settled.hyperApps = resolved(keyboard.hyperApps)
        let current = ctx.files.read(paths.karabinerJSON)
        let scheme = ctx.mode == .practice ? "orbitdev" : "orbit"
        let token = ctx.store.linkToken
        let patched = try KarabinerConfig.patched(current, settings: settled) {
            OrbitLink.url(for: $0, scheme: scheme, token: token)?.absoluteString
        }
        let backups = backupFolder("keyboard")
        return await steps { undo in
            undo += changeSettings { $0.keyboard = settled }
            undo += try write(.karabiner, String(decoding: patched, as: UTF8.self), backups: backups)
            // The cheat sheet (⌥ /) follows, when there is one.
            if let sheet = ctx.files.read(paths.cheatSheet).map({ String(decoding: $0, as: UTF8.self) }) {
                let updated = CheatSheet.update(sheet, block: cheatSheetBlock())
                if updated != sheet { undo += try writePlain(paths.cheatSheet, updated, executable: false, backups: backups) }
            }
            return settled.capsLockEnabled ? "Caps Lock superpowers are on." : "Caps Lock is back to normal."
        }
    }
}

/// Installs Karabiner-Elements. Its installer needs the administrator password, which macOS asks
/// for in its own dialog; the install then runs in the background while Orbit watches for it to finish.
@MainActor
public final class KarabinerInstaller {
    public enum Step: Equatable, Sendable {
        case idle, downloading, checking, waitingForPassword, installing, finishing, done, failed(String)
    }

    public static let teamID = "G43BCU2T37"
    let ctx: SystemContext
    public private(set) var step: Step = .idle
    public var onChange: ((Step) -> Void)?

    public init(ctx: SystemContext) { self.ctx = ctx }

    func set(_ step: Step) {
        self.step = step
        onChange?(step)
    }

    public func install() async {
        set(.downloading)
        let fetch = await ctx.run(Commands.brewFetchCask("karabiner-elements", name: "Karabiner-Elements"))
        guard fetch.ok else { return set(.failed("The download didn't finish: \(fetch.failureMessage)")) }
        if ctx.mode == .practice {
            ctx.practiceLog.record("Would ask for your password and install Karabiner-Elements", "installer -pkg Karabiner-Elements.pkg -target /")
            return set(.done)
        }
        let cache = await ctx.run(Commands.brewCachePath(cask: "karabiner-elements"))
        let dmg = cache.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cache.ok, FileManager.default.fileExists(atPath: dmg) else { return set(.failed("Couldn't find the downloaded installer.")) }

        set(.checking)
        let attach = await ctx.run(Command(Tool.hdiutil, ["attach", "-nobrowse", "-readonly", "-noautoopen", "-plist", dmg],
                                           effect: .appControl, summary: "Open the Karabiner installer disk image", timeout: 60))
        guard attach.ok, let mount = Self.mountPoint(attach.stdout) else { return set(.failed("Couldn't open the installer disk image.")) }
        defer {
            Task { await ctx.run(Command(Tool.hdiutil, ["detach", mount, "-quiet"], effect: .appControl, summary: "Close the disk image", okStatuses: [0, 1])) }
        }
        guard let pkg = (try? FileManager.default.contentsOfDirectory(atPath: mount))?.first(where: { $0.hasSuffix(".pkg") }) else {
            return set(.failed("The disk image had no installer in it."))
        }
        let pkgPath = mount + "/" + pkg
        let signature = await ctx.run(Command(Tool.pkgutil, ["--check-signature", pkgPath], effect: .readOnly,
                                              summary: "Check the installer's signature", timeout: 30))
        guard signature.ok, signature.stdout.contains("(\(Self.teamID))") else {
            return set(.failed("The installer isn't signed by Karabiner's developer, so Orbit stopped."))
        }

        set(.waitingForPassword)
        // Let that step show before macOS's password dialog holds everything up.
        try? await Task.sleep(for: .milliseconds(200))
        // Running as root, the installer writes only into a folder it has just made for itself, so no
        // other program can plant a link there that sends root's writes somewhere else.
        let command = "dir=$(/usr/bin/mktemp -d /private/tmp/orbit-karabiner.XXXXXX) || exit 1; /bin/chmod 755 \"$dir\"; echo \"$dir\"; "
            + "(/usr/sbin/pkgutil --check-signature \(Shell.quote(pkgPath)) | /usr/bin/grep -q '(\(Self.teamID))' && "
            + "/usr/sbin/installer -pkg \(Shell.quote(pkgPath)) -target / > \"$dir/log\" 2>&1; "
            + "echo $? > \"$dir/status\") > /dev/null 2>&1 &"
        let source = "do shell script \(Shell.appleScriptString(command)) with prompt "
            + "\"Orbit needs your password to install Karabiner-Elements, the helper behind Caps Lock superpowers.\" "
            + "with administrator privileges"
        let script = await Self.runOnOwnThread(source)
        if let failure = script.errorNumber {
            let cancelled = failure == -128
            return set(.failed(cancelled ? "You cancelled the password prompt, so nothing was installed." : "macOS didn't run the installer."))
        }
        guard let dir = script.output?.trimmingCharacters(in: .whitespacesAndNewlines),
              dir.hasPrefix("/private/tmp/orbit-karabiner.") else {
            return set(.failed("macOS didn't run the installer."))
        }
        let status = dir + "/status"
        let log = dir + "/log"

        set(.installing)
        for _ in 0..<300 {
            if let text = try? String(contentsOfFile: status, encoding: .utf8) {
                let code = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1
                guard code == 0 else { return set(.failed("The installer stopped (code \(code)). Details: \(log)")) }
                set(.finishing)
                await ctx.run(Commands.openApp(at: "/Applications/Karabiner-Elements.app", name: "Karabiner-Elements"))
                return set(.done)
            }
            try? await Task.sleep(for: .seconds(1))
        }
        set(.failed("The installer is taking very long. Check \(log)."))
    }

    struct ScriptResult: Sendable {
        var output: String?
        /// AppleScript's error number, when it failed (-128: the user cancelled).
        var errorNumber: Int?
    }

    /// Runs an AppleScript on a thread of its own: one that asks for the password holds its thread until
    /// the user answers, which mustn't be the main thread (Orbit's window would freeze) or a shared one.
    /// While it waits, AppleScript still calls on the main run loop, so nothing may block the main thread
    /// on the result (awaiting it is fine).
    nonisolated static func runOnOwnThread(_ source: String) async -> ScriptResult {
        await withCheckedContinuation { done in
            let thread = Thread {
                var error: NSDictionary?
                let output = NSAppleScript(source: source)?.executeAndReturnError(&error)
                done.resume(returning: error.map { ScriptResult(output: nil, errorNumber: $0[NSAppleScript.errorNumber] as? Int ?? -1) }
                                       ?? ScriptResult(output: output?.stringValue))
            }
            thread.name = "Orbit AppleScript"
            thread.start()
        }
    }

    static func mountPoint(_ plist: String) -> String? {
        guard let data = plist.data(using: .utf8),
              let root = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let entities = root["system-entities"] as? [[String: Any]] else { return nil }
        return entities.compactMap { $0["mount-point"] as? String }.first
    }
}
