import SwiftUI
import WidgetKit

/// Orbit's desktop widgets and Control Center switches. Sandboxed: it only reads the snapshot Orbit
/// writes, and every action it offers runs in Orbit itself.
@main
struct OrbitWidgets: WidgetBundle {
    var body: some Widget {
        StatusWidget()
        ModesWidget()
        TilingControl()
        GlowControl()
        MenuBarControl()
        CapsLockControl()
        SortDownloadsControl()
        ModeControl()
    }
}
