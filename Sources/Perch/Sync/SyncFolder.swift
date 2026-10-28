import Foundation

/// 同步文件夹的目录结构和文件读写。设计见 docs/icloud-drive-sync.md 第 2、6 节。
///
/// ```
/// <根>/format.json
/// <根>/devices/<设备 ID>/device.json
/// <根>/devices/<设备 ID>/{groups,notes,images}/<UUID>.json
/// <根>/blobs/<UUID>.<扩展名>
/// ```
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
    }

    /// 其他设备文件夹里的一个记录文件。
    struct RemoteFile {
        let device: String
        let kind: Kind
        let id: UUID
        let url: URL
        let stat: FileStat
        /// 相对根目录的路径,作远端文件缓存的键。
        let relativePath: String
    }

    struct DeviceInfo: Codable, Equatable {
        var deviceID: String
        var name: String
        var appVersion: String
        var lastSeen: Date
    }

    var devicesDirectory: URL { root.appendingPathComponent("devices", isDirectory: true) }
    var blobsDirectory: URL { root.appendingPathComponent("blobs", isDirectory: true) }
    var formatURL: URL { root.appendingPathComponent("format.json") }

    func deviceDirectory(_ device: String) -> URL {
        devicesDirectory.appendingPathComponent(device, isDirectory: true)
    }

    func deviceInfoURL(_ device: String) -> URL {
        deviceDirectory(device).appendingPathComponent("device.json")
    }

    func recordURL(device: String, kind: Kind, id: UUID) -> URL {
        deviceDirectory(device)
            .appendingPathComponent(kind.rawValue, isDirectory: true)
            .appendingPathComponent(id.uuidString + ".json")
    }

    func blobURL(id: UUID, fileExtension: String) -> URL {
        let ext = fileExtension.isEmpty ? "bin" : fileExtension
        return blobsDirectory.appendingPathComponent("\(id.uuidString).\(ext)")
    }

    // MARK: - 准备

    enum PrepareError: LocalizedError {
        case parentMissing(URL)
        case newerFormat(Int)

        var errorDescription: String? {
            switch self {
            case .parentMissing(let url):
                return "Folder not found: \(url.path). Is iCloud Drive turned on?"
            case .newerFormat(let format):
                return "The sync folder uses format \(format), newer than this Perch understands (\(SyncFormat.current)). Update Perch on this Mac."
            }
        }
    }

    /// 建好本机设备的目录,写 / 检查 `format.json`。父目录不存在(比如 iCloud 云盘
    /// 没开)时报错,不去建 —— 否则会在本地建出一个永远不同步的文件夹。
    func prepare(device: String) throws {
        let fm = FileManager.default
        let parent = root.deletingLastPathComponent()
        guard fm.fileExists(atPath: parent.path) else { throw PrepareError.parentMissing(parent) }

        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: formatURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let format = json["format"] as? Int {
            guard format <= SyncFormat.current else { throw PrepareError.newerFormat(format) }
        } else {
            try write(Data("{\"format\":\(SyncFormat.current)}".utf8), to: formatURL)
        }
        for kind in Kind.allCases {
            try fm.createDirectory(at: deviceDirectory(device).appendingPathComponent(kind.rawValue),
                                   withIntermediateDirectories: true)
        }
        try fm.createDirectory(at: blobsDirectory, withIntermediateDirectories: true)
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

    func deviceIDs() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: devicesDirectory.path)) ?? []
        return names.filter { !$0.hasPrefix(".") }.sorted()
    }

    /// 列出其他设备的全部记录文件(只看大小和修改时间,不触发下载)。
    /// 文件名不是 `<UUID>.json` 的(比如 iCloud 云盘改名生成的 `xxx 2.json`)忽略。
    func scanRemoteFiles(excluding ownDevice: String) -> [RemoteFile] {
        let fm = FileManager.default
        var result: [RemoteFile] = []
        for device in deviceIDs() where device != ownDevice {
            for kind in Kind.allCases {
                let dir = deviceDirectory(device).appendingPathComponent(kind.rawValue)
                let names = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
                for name in names where name.hasSuffix(".json") {
                    guard let id = UUID(uuidString: String(name.dropLast(5))) else {
                        if !name.hasPrefix(".") { NSLog("Perch sync: ignoring %@/%@", dir.path, name) }
                        continue
                    }
                    let url = dir.appendingPathComponent(name)
                    guard let stat = Self.stat(url) else { continue }
                    result.append(RemoteFile(device: device, kind: kind, id: id, url: url, stat: stat,
                                             relativePath: "devices/\(device)/\(kind.rawValue)/\(name)"))
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
