import Foundation

/// 同步文件夹的目录结构和文件读写。设计见 docs/icloud-drive-sync.md 第 2、6 节。
///
/// ```
/// <根>/format.json
/// <根>/<设备 ID>/device.json
/// <根>/<设备 ID>/{groups,notes,images}/<UUID>.<毫秒>-<计数>.json
/// <根>/<设备 ID>/blobs/<UUID>.<扩展名>
/// ```
///
/// 记录文件每次修改都写成**新文件**(文件名带版本),再删掉上一个:iCloud 云盘把「对方已下载过的
/// 文件被改写」要 40–60 秒才推给对方,新文件 3–4 秒就出现(方案第 10 节)。读的时候每台设备的
/// 每条记录只取版本最大的那个文件。
///
/// 根下面没有多台设备共用的文件夹:两台 Mac 同时建同名文件夹时,iCloud 云盘会把其中一个
/// 改名成「xxx 2」(方案第 10 节),所以每个文件夹都只由它的设备自己建。唯一共用的是根本身,
/// 它被改名时由 `mergeDuplicateRoots` 挪回来。
///
/// 这里的方法都会碰磁盘(iCloud 云盘上的文件可能要先下载),只在后台队列调用。
struct SyncFolder {
    let root: URL

    enum Kind: String, CaseIterable, Codable {
        // 顺序有意义:导入时先分组、再图片、最后笔记(笔记引用分组)。
        case groups, images, notes
    }

    /// 文件的大小和修改时间(纳秒)。只在云端的占位文件上这两项和原文件一致,
    /// 不用下载就能判断有没有变化(方案第 10 节验证过)。
    struct FileStat: Codable, Equatable {
        let size: Int64
        let mtimeNanos: Int64
        /// 文件名(带版本)。同一条记录换了新版本文件,名字一定不同。
        var name: String?
    }

    /// 其他设备文件夹里一条记录的当前文件(版本最大的那个)。
    struct RemoteFile {
        let device: String
        let kind: Kind
        let id: UUID
        let url: URL
        let stat: FileStat
        /// `<设备>/<kind>/<UUID>`,不带版本:远端文件缓存的键。换了版本文件键不变、
        /// stat 变了;这条记录在那台设备上一个文件都没有了,才算移除。
        let recordPath: String
    }

    struct DeviceInfo: Codable, Equatable {
        var deviceID: String
        var name: String
        var appVersion: String
        var lastSeen: Date
    }

    var formatURL: URL { root.appendingPathComponent("format.json") }

    func deviceDirectory(_ device: String) -> URL {
        root.appendingPathComponent(device, isDirectory: true)
    }

    func deviceInfoURL(_ device: String) -> URL {
        deviceDirectory(device).appendingPathComponent("device.json")
    }

    func recordDirectory(device: String, kind: Kind) -> URL {
        deviceDirectory(device).appendingPathComponent(kind.rawValue, isDirectory: true)
    }

    /// 记录文件名:`<UUID>.<毫秒>-<计数>.json`。版本取本机混合逻辑时钟的一次 tick ——
    /// 时钟持久保存、只往前走,本机同步状态丢了也不会写出比旧文件小的版本。
    static func recordFileName(id: UUID, version: HLCTimestamp) -> String {
        "\(id.uuidString).\(version.millis)-\(version.counter).json"
    }

    /// 解析记录文件名,返回 (UUID, 版本)。旧格式 `<UUID>.json` 当作版本 0。
    static func parseRecordFileName(_ name: String) -> (id: UUID, millis: Int64, counter: Int)? {
        guard name.hasSuffix(".json") else { return nil }
        let base = name.dropLast(5)
        let parts = base.split(separator: ".", maxSplits: 1)
        guard let first = parts.first, let id = UUID(uuidString: String(first)) else { return nil }
        guard parts.count == 2 else { return (id, 0, 0) }
        let version = parts[1].split(separator: "-")
        guard version.count == 2, let millis = Int64(version[0]), let counter = Int(version[1]) else {
            return nil
        }
        return (id, millis, counter)
    }

    /// 启动时清理本机文件夹:同一条记录留下了不止一个版本文件(写完新的、删旧的之前退出了),
    /// 只留版本最大的。
    func removeStaleOwnVersions(device: String) {
        let fm = FileManager.default
        for kind in Kind.allCases {
            let dir = recordDirectory(device: device, kind: kind)
            var latest: [UUID: (name: String, millis: Int64, counter: Int)] = [:]
            var stale: [String] = []
            for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] {
                guard let parsed = Self.parseRecordFileName(name) else { continue }
                if let current = latest[parsed.id] {
                    if (parsed.millis, parsed.counter) > (current.millis, current.counter) {
                        stale.append(current.name)
                        latest[parsed.id] = (name, parsed.millis, parsed.counter)
                    } else {
                        stale.append(name)
                    }
                } else {
                    latest[parsed.id] = (name, parsed.millis, parsed.counter)
                }
            }
            for name in stale { try? fm.removeItem(at: dir.appendingPathComponent(name)) }
        }
    }

    /// 图片数据放在写它的设备自己的文件夹里。
    func blobURL(device: String, id: UUID, fileExtension: String) -> URL {
        let ext = fileExtension.isEmpty ? "bin" : fileExtension
        return deviceDirectory(device)
            .appendingPathComponent("blobs", isDirectory: true)
            .appendingPathComponent("\(id.uuidString).\(ext)")
    }

    /// 找一张图片的数据:先看 `preferred` 设备(图片记录所在的设备),再看其他设备。
    /// 两台用 CloudKit 同步过的 Mac 都有同一张图片时,两边各存一份,哪份都行。
    func findBlob(id: UUID, fileExtension: String, preferred: String) -> URL? {
        let fm = FileManager.default
        for device in [preferred] + deviceIDs().filter({ $0 != preferred }) {
            let url = blobURL(device: device, id: id, fileExtension: fileExtension)
            if fm.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    // MARK: - 准备

    enum PrepareError: LocalizedError {
        case parentMissing(URL)
        case newerFormat(Int)
        /// 用户在系统弹窗里拒绝了 Perch 访问 iCloud 云盘(或之后在系统设置里关掉了)。
        case noPermission

        var errorDescription: String? {
            switch self {
            case .parentMissing(let url):
                return L.t(.syncErrorFolderMissing, (url.path as NSString).abbreviatingWithTildeInPath)
            case .newerFormat:
                return L.t(.syncErrorNewerFormat)
            case .noPermission:
                return L.t(.syncErrorNoPermission)
            }
        }

        var isPermission: Bool {
            if case .noPermission = self { return true }
            return false
        }
    }

    /// 没有权限的错误:Cocoa 的读 / 写无权限,或底层的 EPERM / EACCES。
    static func isPermissionError(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain,
           ns.code == NSFileReadNoPermissionError || ns.code == NSFileWriteNoPermissionError {
            return true
        }
        if ns.domain == NSPOSIXErrorDomain, ns.code == Int(EPERM) || ns.code == Int(EACCES) {
            return true
        }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? Error {
            return isPermissionError(underlying)
        }
        return false
    }

    /// 建好本机设备的目录,写 / 检查 `format.json`。父目录不存在(比如 iCloud 云盘
    /// 没开)时报错,不去建 —— 否则会在本地建出一个永远不同步的文件夹。
    func prepare(device: String) throws {
        do {
            try prepareUnchecked(device: device)
        } catch let error as PrepareError {
            throw error
        } catch {
            throw Self.isPermissionError(error) ? PrepareError.noPermission : error
        }
    }

    private func prepareUnchecked(device: String) throws {
        let fm = FileManager.default
        let parent = root.deletingLastPathComponent()
        // 不能只用 fileExists:没有权限时它也返回 false,会被误报成「iCloud 云盘没打开」。
        // 真的列一次目录,看错误是「不存在」还是「没权限」。
        do {
            _ = try fm.contentsOfDirectory(atPath: parent.path)
        } catch {
            if Self.isPermissionError(error) { throw PrepareError.noPermission }
            throw PrepareError.parentMissing(parent)
        }

        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: formatURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let format = json["format"] as? Int {
            guard format <= SyncFormat.current else { throw PrepareError.newerFormat(format) }
        } else {
            try write(Data("{\"format\":\(SyncFormat.current)}".utf8), to: formatURL)
        }
        for sub in Kind.allCases.map(\.rawValue) + ["blobs"] {
            try fm.createDirectory(at: deviceDirectory(device).appendingPathComponent(sub),
                                   withIntermediateDirectories: true)
        }
    }

    /// 根被 iCloud 云盘改名的情况:两台 Mac 同时第一次开启同步,各建一个「Perch」,
    /// 其中一个可能变成「Perch 2」。把旁边「<根名> 2」…「<根名> 9」里的设备文件夹
    /// 挪回根里;同一台设备的文件夹两边都有时逐个文件挪,两边都有的文件留较新的。
    /// 只认名字是 UUID 的设备文件夹,别的东西不碰,挪空了才删掉那个多出来的根。
    func mergeDuplicateRoots() {
        let fm = FileManager.default
        let parent = root.deletingLastPathComponent()
        for n in 2...9 {
            let duplicate = parent.appendingPathComponent("\(root.lastPathComponent) \(n)", isDirectory: true)
            guard fm.fileExists(atPath: duplicate.path) else { continue }
            let devices = Self.deviceFolderNames(in: duplicate)
            guard !devices.isEmpty else { continue }
            NSLog("Perch sync: merging %@ back into %@", duplicate.path, root.path)
            for device in devices {
                Self.mergeTree(from: duplicate.appendingPathComponent(device),
                               into: root.appendingPathComponent(device))
            }
            let left = ((try? fm.contentsOfDirectory(atPath: duplicate.path)) ?? [])
                .filter { !$0.hasPrefix(".") && !$0.hasPrefix("format") }
            if left.isEmpty { try? fm.removeItem(at: duplicate) }
        }
    }

    private static func deviceFolderNames(in directory: URL) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { UUID(uuidString: $0) != nil }.sorted()
    }

    private static func mergeTree(from source: URL, into target: URL) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: target.path) else {
            try? fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.moveItem(at: source, to: target)
            return
        }
        for name in (try? fm.contentsOfDirectory(atPath: source.path)) ?? [] where !name.hasPrefix(".") {
            let from = source.appendingPathComponent(name)
            let to = target.appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            fm.fileExists(atPath: from.path, isDirectory: &isDirectory)
            if isDirectory.boolValue {
                mergeTree(from: from, into: to)
            } else if let existing = stat(to), let incoming = stat(from) {
                if incoming.mtimeNanos > existing.mtimeNanos {
                    _ = try? fm.replaceItemAt(to, withItemAt: from)
                } else {
                    try? fm.removeItem(at: from)
                }
            } else {
                try? fm.moveItem(at: from, to: to)
            }
        }
        try? fm.removeItem(at: source)
    }

    // MARK: - 写

    /// 先写到同步文件夹之外的临时文件,再整体替换目标 —— 临时文件不会被同步出去,
    /// 别的设备也不会读到写了一半的文件。
    func write(_ data: Data, to url: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let tmp = fm.temporaryDirectory.appendingPathComponent("perch-sync-" + UUID().uuidString)
        try data.write(to: tmp)
        do {
            if fm.fileExists(atPath: url.path) {
                _ = try fm.replaceItemAt(url, withItemAt: tmp)
            } else {
                try fm.moveItem(at: tmp, to: url)
            }
        } catch {
            try? fm.removeItem(at: tmp)
            throw error
        }
    }

    func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - 扫描

    static func stat(_ url: URL) -> FileStat? {
        var st = Darwin.stat()
        guard lstat(url.path, &st) == 0 else { return nil }
        let nanos = Int64(st.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(st.st_mtimespec.tv_nsec)
        return FileStat(size: Int64(st.st_size), mtimeNanos: nanos)
    }

    /// 根下名字是 UUID 的文件夹都是设备文件夹,别的(format.json、iCloud 云盘生成的
    /// 「xxx 2」之类)不管。
    func deviceIDs() -> [String] {
        Self.deviceFolderNames(in: root)
    }

    /// 列出其他设备每条记录的当前文件(只看大小和修改时间,不触发下载)。同一条记录有
    /// 好几个版本文件时(对方写了新的、旧的还没删掉)取版本最大的。文件名认不出来的
    /// (比如 iCloud 云盘改名生成的 `xxx 2.json`)忽略。
    func scanRemoteFiles(excluding ownDevice: String) -> [RemoteFile] {
        let fm = FileManager.default
        var result: [RemoteFile] = []
        for device in deviceIDs() where device != ownDevice {
            for kind in Kind.allCases {
                let dir = recordDirectory(device: device, kind: kind)
                var latest: [UUID: (name: String, millis: Int64, counter: Int)] = [:]
                for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where !name.hasPrefix(".") {
                    guard let parsed = Self.parseRecordFileName(name) else {
                        NSLog("Perch sync: ignoring %@/%@", dir.path, name)
                        continue
                    }
                    if let current = latest[parsed.id],
                       (current.millis, current.counter) >= (parsed.millis, parsed.counter) { continue }
                    latest[parsed.id] = (name, parsed.millis, parsed.counter)
                }
                for (id, file) in latest {
                    let url = dir.appendingPathComponent(file.name)
                    guard var stat = Self.stat(url) else { continue }
                    stat.name = file.name
                    result.append(RemoteFile(device: device, kind: kind, id: id, url: url, stat: stat,
                                             recordPath: "\(device)/\(kind.rawValue)/\(id.uuidString)"))
                }
            }
        }
        return result
    }

    func readDeviceInfos() -> [String: DeviceInfo] {
        let decoder = Self.makeDecoder()
        var result: [String: DeviceInfo] = [:]
        for device in deviceIDs() {
            if let data = try? Data(contentsOf: deviceInfoURL(device)),
               let info = try? decoder.decode(DeviceInfo.self, from: data) {
                result[device] = info
            }
        }
        return result
    }

    // MARK: - 读

    /// 并发读取。读只在云端的文件会触发下载并等待(单个约 0.4–1.4 秒),所以要并发:
    /// 实测 512 个文件并发 32 个用 20 秒,并发 8 个用 54 秒(方案第 10 节)。
    func readAll(_ urls: [URL], concurrency: Int = 32) -> [URL: Data] {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = concurrency
        let lock = NSLock()
        var result: [URL: Data] = [:]
        for url in urls {
            queue.addOperation {
                guard let data = try? Data(contentsOf: url) else { return }
                lock.lock()
                result[url] = data
                lock.unlock()
            }
        }
        queue.waitUntilAllOperationsAreFinished()
        return result
    }

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    static func makeEncoder() -> JSONEncoder {
        let encoder = SyncRecord.makeEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}
