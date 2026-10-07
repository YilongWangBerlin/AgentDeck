import CoreServices
import Foundation

/// Calls `onChange` shortly after anything changes below the watched directories. FSEvents coalesces
/// bursts of writes within `latency`, so a busy session triggers one rescan, not one per line.
///
/// Directories that do not exist when `start()` is called are not watched; the rescan on launch picks
/// up anything that appears later.
public final class LogWatcher: @unchecked Sendable {
    private let directories: [URL]
    private let latency: TimeInterval
    private let onChange: @Sendable () -> Void
    private let queue = DispatchQueue(label: "AgentDeck.LogWatcher")
    private let lock = NSLock()
    private var stream: FSEventStreamRef?

    public init(directories: [URL], latency: TimeInterval = 2, onChange: @escaping @Sendable () -> Void) {
        self.directories = directories
        self.latency = latency
        self.onChange = onChange
    }

    deinit { stop() }

    /// Returns false when none of the directories exist.
    @discardableResult
    public func start() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard stream == nil else { return true }

        let paths = directories.map(\.path).filter { FileManager.default.fileExists(atPath: $0) }
        guard !paths.isEmpty else { return false }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<LogWatcher>.fromOpaque(info).takeUnretainedValue().onChange()
        }
        guard let created = FSEventStreamCreate(
            nil, callback, &context, paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer)
        ) else { return false }

        FSEventStreamSetDispatchQueue(created, queue)
        guard FSEventStreamStart(created) else {
            FSEventStreamInvalidate(created)
            FSEventStreamRelease(created)
            return false
        }
        stream = created
        return true
    }

    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }
}
