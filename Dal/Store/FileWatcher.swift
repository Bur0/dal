import Foundation
import CoreServices

/// Watches a working tree (including .git) with FSEvents and reports the changed paths.
final class FileWatcher {
    private var stream: FSEventStreamRef?
    private let onChange: ([String]) -> Void

    init(paths: [String], onChange: @escaping ([String]) -> Void) {
        self.onChange = onChange
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<FileWatcher>.fromOpaque(info).takeUnretainedValue()
            let list = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            watcher.handle(Array(list.prefix(count)))
        }
        let flags = UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents
                           | kFSEventStreamCreateFlagNoDefer)
        stream = FSEventStreamCreate(nil, callback, &context, paths as CFArray,
                                     FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3, flags)
        if let stream {
            FSEventStreamSetDispatchQueue(stream, .main)
            FSEventStreamStart(stream)
        }
    }

    private func handle(_ paths: [String]) {
        let relevant = paths.filter { path in
            if path.contains("/.git/objects/") || path.contains("/.git/logs/") { return false }
            if path.hasSuffix(".lock") { return false }
            if path.hasSuffix("/.DS_Store") { return false }
            return true
        }
        if !relevant.isEmpty { onChange(relevant) }
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit { stop() }
}
