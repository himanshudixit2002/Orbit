import Darwin
import Foundation
import OrbitCore

/// When this Mac started and when you logged in, read from the kernel and the login records. Read-only.
public enum StartupProbe {
    /// When macOS started.
    public static func bootTime() -> Date? {
        var time = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &time, &size, nil, 0) == 0, time.tv_sec > 0 else { return nil }
        return Date(timeIntervalSince1970: Double(time.tv_sec) + Double(time.tv_usec) / 1e6)
    }

    /// When `user` last logged in on the Mac's own screen (what `who` lists as "console").
    public static func loginTime(user: String = NSUserName()) -> Date? {
        setutxent()
        defer { endutxent() }
        var latest: Date?
        while let entry = getutxent()?.pointee {
            guard Int32(entry.ut_type) == USER_PROCESS,
                  text(entry.ut_line) == "console", text(entry.ut_user) == user else { continue }
            let date = Date(timeIntervalSince1970: Double(entry.ut_tv.tv_sec) + Double(entry.ut_tv.tv_usec) / 1e6)
            if latest.map({ date > $0 }) ?? true { latest = date }
        }
        return latest
    }

    private static func text<T>(_ field: T) -> String {
        withUnsafeBytes(of: field) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }
}
