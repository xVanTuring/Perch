import Foundation
import CoreServices

/// 监听同步文件夹的变化(FSEvents)。另一台 Mac 的文件到达本机时,占位文件出现会触发
/// 「改名」事件(方案第 10 节验证过)。本机自己文件夹里的变化(自己写的)不通知。
final class SyncFolderWatcher {
    private var stream: FSEventStreamRef?
    private let root: URL
    private let ignoredPrefix: String
    private let onChange: () -> Void

    init(root: URL, ignoring ownDirectory: URL, onChange: @escaping () -> Void) {
        self.root = root
        self.ignoredPrefix = ownDirectory.resolvingSymlinksInPath().path + "/"
        self.onChange = onChange
    }

    deinit { stop() }

    func start() {
        guard stream == nil else { return }
        var context = FSEventStreamContext(version: 0,
                                           info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<SyncFolderWatcher>.fromOpaque(info).takeUnretainedValue()
            let list = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            watcher.handle(Array(list.prefix(count)))
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents
                                             | kFSEventStreamCreateFlagUseCFTypes)
        guard let stream = FSEventStreamCreate(kCFAllocatorDefault, callback, &context,
                                               [root.path] as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                                               0.5, flags) else {
            NSLog("Perch sync: FSEventStreamCreate failed for %@", root.path)
            return
        }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    private func handle(_ paths: [String]) {
        let relevant = paths.contains { path in
            let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
            return !(resolved + "/").hasPrefix(ignoredPrefix) && !resolved.hasPrefix(ignoredPrefix)
        }
        if relevant { onChange() }
    }
}
