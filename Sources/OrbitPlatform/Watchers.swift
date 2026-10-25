import CoreServices
import Foundation

/// Tells when files change in some folders (FSEvents), so Orbit re-checks only when something happened
/// instead of asking every few seconds. Bursts arrive together after `latency`.
public final class FileWatcher: @unchecked Sendable {
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "com.himanshudixit.orbit.files")
    private let changed: @Sendable ([String]) -> Void

    /// Folders that don't exist are left out. `changed` gets the paths that changed.
    public init(folders: [URL], latency: TimeInterval = 0.5, changed: @escaping @Sendable ([String]) -> Void) {
        self.changed = changed
        let existing = folders.map { $0.path(percentEncoded: false) }.filter { FileManager.default.fileExists(atPath: $0) }
        guard !existing.isEmpty else { return }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<FileWatcher>.fromOpaque(info).takeUnretainedValue()
            let changed = (unsafeBitCast(paths, to: NSArray.self) as? [String]) ?? []
            watcher.changed(Array(changed.prefix(count)))
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents)
        stream = FSEventStreamCreate(nil, callback, &context, existing as CFArray,
                                     FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags)
        if let stream {
            FSEventStreamSetDispatchQueue(stream, queue)
            FSEventStreamStart(stream)
        }
    }

    deinit {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }
}

/// Tells the moment a process ends (a helper crashing, say), without polling.
public final class ExitWatcher: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.himanshudixit.orbit.exits")
    private var sources: [Int32: DispatchSourceProcess] = [:]   // only touched on `queue`
    private let exited: @Sendable (Int32) -> Void

    public init(exited: @escaping @Sendable (Int32) -> Void) { self.exited = exited }

    /// Watches exactly these processes from now on.
    public func watch(_ pids: Set<Int32>) {
        queue.async { [self] in
            for (pid, source) in sources where !pids.contains(pid) {
                source.cancel()
                sources[pid] = nil
            }
            for pid in pids where sources[pid] == nil {
                let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
                source.setEventHandler { [weak self] in
                    guard let self else { return }
                    sources[pid]?.cancel()
                    sources[pid] = nil
                    exited(pid)
                }
                sources[pid] = source
                source.resume()
            }
        }
    }

    deinit { sources.values.forEach { $0.cancel() } }
}
