import Foundation
import CryptoKit

/// 某台设备文件夹里的一个记录版本。
struct DeviceVersion: Hashable {
    let deviceID: String
    let record: SyncRecord
}

/// 合并结果:一条记录在所有设备上的最终状态。
struct MergedRecord: Equatable {
    let id: UUID
    let isDeleted: Bool
    /// 每个字段的最终值和胜出的时间戳。已删除时为空。
    let fields: [String: SyncField]
    /// 正文版本向量:所有版本的合并(包括落选的)。本机下次改正文时在它上面加 1,
    /// 新版本就同时盖过两边,冲突自然消失。分组和图片为空。
    let contentVersion: VersionVector
    /// 这条记录本身是冲突副本(带 `conflictOf` 字段)。
    let isConflictCopy: Bool
    /// 这次合并发现的、需要生成的冲突副本,按 UUID 排序。
    let conflictCopies: [ConflictCopy]

    func value(_ field: String) -> SyncValue? { fields[field]?.value }
}

/// 一条要生成的冲突副本。每台 Mac 对同一个落选版本算出的副本完全一样(UUID、正文、
/// 时间戳都一样),所以两台都生成、都写进自己的文件夹也只会合并成一条。
///
/// 调用方只在这个 UUID 还不存在时生成 —— 已经存在说明生成过,用户可能已经改过它。
struct ConflictCopy: Equatable {
    let id: UUID
    let originalID: UUID
    /// 说明行 + 空行 + 落选版本的完整正文。
    let content: String
    /// 落选版本所在的设备。
    let sourceDeviceID: String
    /// 落选版本的时间戳。副本的各字段都用它,保证每台 Mac 写出的记录一模一样。
    let hlc: HLCTimestamp

    /// 写进本机文件夹的记录。
    func makeRecord() -> SyncRecord {
        let date = SyncValue.date(hlc.date)
        // 笔记的每个同步字段都给出固定值:缺了哪个,收到副本的设备就会把本地默认值
        // 当成自己的修改再写一遍。
        let fields: [String: SyncValue] = [
            SyncFieldName.content: .string(content),
            SyncFieldName.conflictOf: .uuid(originalID),
            SyncFieldName.groupID: .uuid(DeterministicUUID.conflictGroupID),
            SyncFieldName.createdAt: date,
            SyncFieldName.updatedAt: date,
            SyncFieldName.colorIndex: .int(0),
            SyncFieldName.isTrashed: .bool(false),
            SyncFieldName.trashedAt: .null,
            SyncFieldName.isArchived: .bool(false),
            SyncFieldName.archivedAt: .null,
            SyncFieldName.reminderDate: .null,
        ]
        return SyncRecord(id: id,
                          fields: fields.mapValues { SyncField(value: $0, hlc: hlc) },
                          contentVersion: VersionVector())
    }
}

/// 生成冲突副本时需要的外部信息。
struct ConflictContext {
    /// 设备 ID → 设备名(来自各设备的 `device.json`)。找不到时用设备 ID 前 8 位。
    var deviceNames: [String: String] = [:]
    /// 这个 UUID 有没有删除标记。用户删掉的冲突副本不再生成。
    var isTombstoned: (UUID) -> Bool = { _ in false }
}

/// 合并规则。设计见 docs/icloud-drive-sync.md 第 4 节。
///
/// 全部是纯函数:结果只取决于输入的版本集合,与顺序、重复无关。每台 Mac 读到
/// 同一组文件就算出同一个结果,不需要互相协调。
enum SyncMerge {

    /// 分组、图片:每个字段取时间戳最大的;有删除标记、且没有比它更晚的字段 → 已删除。
    static func mergeRecord(_ versions: [DeviceVersion]) -> MergedRecord? {
        guard let id = versions.first?.record.id else { return nil }
        let versions = sameRecord(versions, id: id)

        let fields = latestFields(versions, excluding: [])
        if let deleted = latestDeletion(versions),
           fields.values.allSatisfy({ $0.hlc <= deleted }) {
            return deletedRecord(id)
        }
        return MergedRecord(id: id, isDeleted: false, fields: fields,
                            contentVersion: VersionVector(), isConflictCopy: false,
                            conflictCopies: [])
    }

    /// 笔记:在 `mergeRecord` 的规则上,正文用版本向量判断冲突,另外处理回收站和删除。
    static func mergeNote(_ versions: [DeviceVersion],
                          context: ConflictContext = ConflictContext()) -> MergedRecord? {
        guard let id = versions.first?.record.id else { return nil }
        let versions = sameRecord(versions, id: id)

        var fields = latestFields(versions, excluding: [SyncFieldName.content])
        let isConflictCopy = fields[SyncFieldName.conflictOf] != nil
        let contentVersion = versions
            .compactMap(\.record.contentVersion)
            .reduce(VersionVector()) { $0.merged(with: $1) }

        let content = resolveContent(id: id, versions: versions,
                                     isConflictCopy: isConflictCopy, context: context)
        if let winner = content.winner {
            fields[SyncFieldName.content] = winner
        }
        let contentClock = fields[SyncFieldName.content]?.hlc

        // 永久删除:正文在删除之后还改过 → 保留,放进回收站;否则删除。
        if let deleted = latestDeletion(versions) {
            guard let contentClock, contentClock > deleted else {
                return deletedRecord(id)
            }
            // 删除之后又明确改过回收站状态(比如用户把它从回收站恢复了)就按那次的来,
            // 不再强制放回回收站,也不再套下面的规则。
            if (fields[SyncFieldName.isTrashed]?.hlc).map({ $0 < deleted }) ?? true {
                fields[SyncFieldName.isTrashed] = SyncField(value: .bool(true), hlc: deleted)
                fields[SyncFieldName.trashedAt] = SyncField(value: .date(deleted.date), hlc: deleted)
                return MergedRecord(id: id, isDeleted: false, fields: fields,
                                    contentVersion: contentVersion,
                                    isConflictCopy: isConflictCopy,
                                    conflictCopies: content.copies)
            }
        }

        // 移进回收站之后正文又改过(另一台不知道它进了回收站)→ 移出回收站。
        if let trashed = fields[SyncFieldName.isTrashed], trashed.value == .bool(true),
           let contentClock, contentClock > trashed.hlc {
            fields[SyncFieldName.isTrashed] = SyncField(value: .bool(false), hlc: contentClock)
            fields[SyncFieldName.trashedAt] = SyncField(value: .null, hlc: contentClock)
        }

        return MergedRecord(id: id, isDeleted: false, fields: fields,
                            contentVersion: contentVersion,
                            isConflictCopy: isConflictCopy,
                            conflictCopies: content.copies)
    }

    // MARK: - 正文

    private struct ContentCandidate {
        let deviceID: String
        let text: String
        let hlc: HLCTimestamp
        let version: VersionVector
    }

    private static func resolveContent(id: UUID, versions: [DeviceVersion],
                                       isConflictCopy: Bool,
                                       context: ConflictContext)
        -> (winner: SyncField?, copies: [ConflictCopy]) {
        let candidates: [ContentCandidate] = versions.compactMap { v in
            guard let field = v.record.fields[SyncFieldName.content],
                  let text = field.value.stringValue else { return nil }
            return ContentCandidate(deviceID: v.deviceID, text: text, hlc: field.hlc,
                                    version: v.record.contentVersion ?? VersionVector())
        }

        // 去掉被别的版本「包含」的旧版本:剩下的互相都不知道对方。
        let latest = candidates.filter { c in
            !candidates.contains { $0.version.compare(c.version) == .after }
        }
        // 正文相同的不算冲突:同样的文字只留最新的那份。
        var byText: [String: ContentCandidate] = [:]
        for c in latest where byText[c.text].map({ isNewer(c, than: $0) }) ?? true {
            byText[c.text] = c
        }
        let ranked = byText.values.sorted { isNewer($0, than: $1) }
        guard let winner = ranked.first else { return (nil, []) }

        let winnerField = SyncField(value: .string(winner.text), hlc: winner.hlc)
        // 冲突副本本身再冲突:只取时间戳大的,不生成「副本的副本」。
        guard !isConflictCopy else { return (winnerField, []) }

        let copies = ranked.dropFirst().compactMap { loser -> ConflictCopy? in
            let copyID = DeterministicUUID.conflictCopy(of: id, content: loser.text)
            guard !context.isTombstoned(copyID) else { return nil }
            let name = context.deviceNames[loser.deviceID] ?? String(loser.deviceID.prefix(8))
            return ConflictCopy(id: copyID, originalID: id,
                                content: ConflictHeader.make(deviceName: name, date: loser.hlc.date)
                                    + "\n\n" + loser.text,
                                sourceDeviceID: loser.deviceID, hlc: loser.hlc)
        }
        return (winnerField, copies.sorted { $0.id.uuidString < $1.id.uuidString })
    }

    /// 时间戳大的新;时间戳相同(正常情况下不会出现)时依次按设备 ID、正文决胜,
    /// 保证排序结果和输入顺序无关。
    private static func isNewer(_ a: ContentCandidate, than b: ContentCandidate) -> Bool {
        if a.hlc != b.hlc { return a.hlc > b.hlc }
        if a.deviceID != b.deviceID { return a.deviceID > b.deviceID }
        return a.text > b.text
    }

    // MARK: - 字段

    /// 每个字段取时间戳最大的。时间戳相同(同一条记录被原样写了两份,比如冲突副本)
    /// 而值不同时按值的文本决胜,保证结果和顺序无关。
    private static func latestFields(_ versions: [DeviceVersion],
                                     excluding excluded: Set<String>) -> [String: SyncField] {
        var result: [String: SyncField] = [:]
        for version in versions {
            for (name, field) in version.record.fields where !excluded.contains(name) {
                if let current = result[name], !isNewer(field, than: current) { continue }
                result[name] = field
            }
        }
        return result
    }

    private static func isNewer(_ a: SyncField, than b: SyncField) -> Bool {
        if a.hlc != b.hlc { return a.hlc > b.hlc }
        return String(describing: a.value) > String(describing: b.value)
    }

    /// 调用方按文件名把同一条记录的版本放在一起;文件里的 ID 和文件名对不上是坏文件,
    /// 调试时报出来,正式版里丢掉这个版本继续合并,不让一个坏文件弄崩 App。
    private static func sameRecord(_ versions: [DeviceVersion], id: UUID) -> [DeviceVersion] {
        assert(versions.allSatisfy { $0.record.id == id }, "SyncMerge: mixed record IDs")
        return versions.filter { $0.record.id == id }
    }

    private static func latestDeletion(_ versions: [DeviceVersion]) -> HLCTimestamp? {
        versions.compactMap(\.record.deleted).max()
    }

    private static func deletedRecord(_ id: UUID) -> MergedRecord {
        MergedRecord(id: id, isDeleted: true, fields: [:], contentVersion: VersionVector(),
                     isConflictCopy: false, conflictCopies: [])
    }
}

/// 冲突副本开头的说明行。固定格式:中英文都写,时间用 UTC —— 不能跟随本机语言和
/// 时区,否则两台 Mac 写出的文字不同,同一条副本又会被当成一次新冲突。
enum ConflictHeader {
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    static let prefix = "> 同步冲突 / Sync conflict — "

    static func make(deviceName: String, date: Date) -> String {
        let name = deviceName.replacingOccurrences(of: "\n", with: " ")
        return prefix + "\(name), \(formatter.string(from: date)) UTC"
    }

    /// 拆开冲突副本的正文:说明行(去掉开头的 `> `)和落选版本的原文。
    /// 不是以说明行开头的(不是冲突副本,或用户删掉了说明行)原样返回、说明行为 nil。
    static func split(_ content: String) -> (header: String?, body: String) {
        guard content.hasPrefix(prefix) else { return (nil, content) }
        let lines = content.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        let header = String(lines[0].dropFirst(2))
        var body = lines.count > 1 ? String(lines[1]) : ""
        if body.hasPrefix("\n") { body.removeFirst() }   // make() 在说明行后面空了一行
        return (header, body)
    }
}

/// 由名字算出的固定 UUID(UUID v5,SHA-1)。两台 Mac 对同一个名字算出同一个 UUID。
enum DeterministicUUID {
    /// Perch 专用的命名空间。不要改:改了以后算出的 UUID 全变,已生成的冲突副本和
    /// 「同步冲突」分组就对不上了。
    static let namespace = UUID(uuidString: "776BAE71-B440-4034-907C-5F7E14A61DB2")!

    /// 「同步冲突」分组。
    static let conflictGroupID = make("conflict-group")

    /// 冲突副本:由原笔记 UUID + 落选版本的正文决定。
    static func conflictCopy(of original: UUID, content: String) -> UUID {
        make("conflict-copy|\(original.uuidString)|\(content)")
    }

    static func make(_ name: String) -> UUID {
        var data = withUnsafeBytes(of: namespace.uuid) { Data($0) }
        data.append(Data(name.utf8))
        var bytes = Array(Insecure.SHA1.hash(data: data).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50   // version 5
        bytes[8] = (bytes[8] & 0x3F) | 0x80   // RFC 4122 variant
        return bytes.withUnsafeBufferPointer { NSUUID(uuidBytes: $0.baseAddress!) as UUID }
    }
}
