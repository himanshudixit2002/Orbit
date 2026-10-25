import AppKit
import Carbon.HIToolbox
import OrbitCore

/// The one global shortcut (it opens the command palette), through Carbon's `RegisterEventHotKey`:
/// unlike a global key monitor it needs no Accessibility permission. A shortcut another app already
/// owns simply doesn't register, and `registered` says so.
final class HotKey {
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    var onPress: (() -> Void)?
    private(set) var registered = false

    /// Carbon calls a C function with nothing reliable to point back to us, so the live one is kept here.
    nonisolated(unsafe) private static weak var current: HotKey?

    func register(_ setting: HotKeySetting) {
        unregister()
        guard setting.enabled else { return }
        Self.current = self
        installHandler()
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: OSType(0x4F52_4254), id: 1)  // "ORBT"
        if RegisterEventHotKey(setting.keyCode, setting.modifiers, id, GetApplicationEventTarget(), 0, &ref) == noErr, let ref {
            self.ref = ref
            registered = true
        }
    }

    func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
        registered = false
        if let handler { RemoveEventHandler(handler) }
        handler = nil
    }

    private func installHandler() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ -> OSStatus in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { HotKey.current?.onPress?() }
            }
            return noErr
        }, 1, &spec, nil, &handler)
    }
}
