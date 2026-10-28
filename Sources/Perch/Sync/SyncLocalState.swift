import Foundation

/// 一条记录在本机的同步状态。存在 `SyncState/records/<kind>/<UUID>.json`。
struct SyncRecordState: Codable, Equatable {
    /// 本机写进自己文件夹的版本。
    var own: SyncRecord?
    /// 本机文件夹里这条记录当前的文件名(带版本)。下次写新版本后删掉它。
    var ownFileName: String?
    /// 其他设备的最新版本(设备 ID → 记录)。读过一次就缓存在这里,合并时不用再
    /// 去同步文件夹里读(那边的文件可能又被 iCloud 云盘移回只在云端)。
    var remote: [String: SyncRecord] = [:]
    /// 上一次合并后的各字段,也就是 Core Data 里此刻「应该」是什么。导出时拿本地值
    /// 和它比:不一样就是本机改过,要打新时间戳写出去;一样就是导入写进去的,不写 ——
    /// 这样不需要区分是谁保存的,也不会把刚收到的修改又写回去。
    var base: [String: SyncField] = [:]
    var baseVersion = VersionVector()
    /// 合并结果是已删除。
    var isDeleted = false

    /// 参与合并的全部版本。本机设备 ID 由调用方给:不能从时间戳里推,冲突副本和
    /// 「同步冲突」分组的时间戳带的是别的设备 ID 或固定值。
    func versions(ownDevice: String) -> [DeviceVersion] {
        var all = remote.map { DeviceVersion(deviceID: $0.key, record: $0.value) }
        if let own { all.append(DeviceVersion(deviceID: ownDevice, record: own)) }
        return all
    }

    /// 有没有任何一个版本带删除标记。
    var hasDeletionMarker: Bool {
        own?.deleted != nil || remote.values.contains { $0.deleted != nil }
    }
}

/// 本机同步状态的整体:各记录状态 + 时钟 + 远端文件缓存。全部在主线程读写,
/// 落盘交给调用方放到后台队列(`persist…` 只生成要写的数据)。
final class SyncLocalState {
    struct Key: Hashable, Codable {
        let kind: SyncFolder.Kind
        let id: UUID
    }

    struct Meta: Codable {
        var clockMillis: Int64 = 0
        var clockCounter: Int = 0
        /// 其他设备记录文件的 大小 + 修改时间,相对路径为键。没变就不重读。
        var remoteStats: [String: SyncFolder.FileStat] = [:]
    }

    let directory: URL
    private(set) var records: [Key: SyncRecordState] = [:]
    var meta = Meta()
    private var dirtyKeys: Set<Key> = []
    private var metaDirty = false

    init(directory: URL) {
        self.directory = directory
    }

    private var recordsDirectory: URL { directory.appendingPathComponent("records", isDirectory: true) }
    private var metaURL: URL { directory.appendingPathComponent("meta.json") }

    private func url(for key: Key) -> URL {
        recordsDirectory
            .appendingPathComponent(key.kind.rawValue, isDirectory: true)
            .appendingPathComponent(key.id.uuidString + ".json")
    }

    /// 启动时读一次。坏掉的文件跳过 —— 那条记录下次合并时按「从没同步过」处理,
    /// 内容相同的版本不算冲突,所以最坏是多写一次文件,不会凭空生成冲突副本。
    func load() {
        let fm = FileManager.default
        let decoder = JSONDecoder()
        for kind in SyncFolder.Kind.allCases {
            let dir = recordsDirectory.appendingPathComponent(kind.rawValue)
            for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where name.hasSuffix(".json") {
                guard let id = UUID(uuidString: String(name.dropLast(5))),
                      let data = try? Data(contentsOf: dir.appendingPathComponent(name)),
                      let state = try? decoder.decode(SyncRecordState.self, from: data) else { continue }
                records[Key(kind: kind, id: id)] = state
            }
        }
        if let data = try? Data(contentsOf: metaURL),
           let decoded = try? decoder.decode(Meta.self, from: data) {
            meta = decoded
        }
    }

    subscript(key: Key) -> SyncRecordState? {
        records[key]
    }

    func update(_ key: Key, _ change: (inout SyncRecordState) -> Void) {
        var state = records[key] ?? SyncRecordState()
        let before = state
        change(&state)
        guard state != before else { return }
        records[key] = state
        dirtyKeys.insert(key)
    }

    func markMetaDirty() { metaDirty = true }

    var allKeys: [Key] { Array(records.keys) }

    func keys(of kind: SyncFolder.Kind) -> [Key] {
        records.keys.filter { $0.kind == kind }
    }

    /// 取出要落盘的内容并清空脏标记。返回的闭包在后台队列执行。
    func takePendingWrites() -> (() -> Void)? {
        guard !dirtyKeys.isEmpty || metaDirty else { return nil }
        let encoder = JSONEncoder()
        var files: [(URL, Data)] = []
        for key in dirtyKeys {
            if let state = records[key], let data = try? encoder.encode(state) {
                files.append((url(for: key), data))
            }
        }
        if metaDirty, let data = try? encoder.encode(meta) {
            files.append((metaURL, data))
        }
        dirtyKeys.removeAll()
        metaDirty = false
        return {
            let fm = FileManager.default
            for (url, data) in files {
                try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? data.write(to: url, options: .atomic)
            }
        }
    }
}
