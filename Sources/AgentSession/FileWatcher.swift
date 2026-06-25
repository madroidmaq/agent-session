import Foundation
import CoreServices

// 监听 ~/.claude/projects 整棵树的变化，聚合 + 防抖后回调一次（主线程）。
final class FileWatcher {
    private let path: String
    private let onChange: ([String]?) -> Void
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "dev.madroid.agentsession.fswatch")
    private var debounce: DispatchSourceTimer?
    private var pendingPaths = Set<String>()
    private var pendingUnknown = false

    init(path: String, onChange: @escaping ([String]?) -> Void) {
        self.path = path
        self.onChange = onChange
    }

    func start() {
        var ctx = FSEventStreamContext(version: 0,
                                       info: Unmanaged.passUnretained(self).toOpaque(),
                                       retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, numEvents, eventPaths, eventFlags, _ in
            guard let info = info else { return }
            let watcher = Unmanaged<FileWatcher>.fromOpaque(info).takeUnretainedValue()
            if (0..<numEvents).contains(where: { watcher.isImprecise(eventFlags[$0]) }) {
                watcher.scheduleDebounced(paths: nil)
                return
            }
            let rawPaths = eventPaths.assumingMemoryBound(to: UnsafePointer<CChar>.self)
            let paths = (0..<numEvents).map { String(cString: rawPaths[$0]) }
            watcher.scheduleDebounced(paths: paths)
        }
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        guard let s = FSEventStreamCreate(kCFAllocatorDefault, callback, &ctx,
                                          [path] as CFArray,
                                          FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                                          1.0, flags) else { return }
        stream = s
        FSEventStreamSetDispatchQueue(s, queue)
        FSEventStreamStart(s)
    }

    private func isImprecise(_ flags: FSEventStreamEventFlags) -> Bool {
        let imprecise = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs
            | kFSEventStreamEventFlagUserDropped
            | kFSEventStreamEventFlagKernelDropped
            | kFSEventStreamEventFlagEventIdsWrapped
            | kFSEventStreamEventFlagRootChanged
            | kFSEventStreamEventFlagMount
            | kFSEventStreamEventFlagUnmount)
        return flags & imprecise != 0
    }

    private func scheduleDebounced(paths: [String]?) {
        DispatchQueue.main.async {
            if let paths {
                self.pendingPaths.formUnion(paths)
            } else {
                self.pendingUnknown = true
                self.pendingPaths.removeAll()
            }
            self.debounce?.cancel()
            let t = DispatchSource.makeTimerSource(queue: .main)
            t.schedule(deadline: .now() + 1.0)
            t.setEventHandler { [weak self] in
                guard let self = self else { return }
                let paths = self.pendingUnknown ? nil : Array(self.pendingPaths)
                self.pendingUnknown = false
                self.pendingPaths.removeAll()
                self.onChange(paths)
            }
            t.resume()
            self.debounce = t
        }
    }

    func stop() {
        guard let s = stream else { return }
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
        stream = nil
    }
}
