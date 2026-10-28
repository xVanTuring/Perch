import Foundation

/// 同步文件夹里一个记录文件(`devices/<设备 ID>/notes|groups|images/<UUID>.json`)的内容。
/// 格式见 docs/icloud-drive-sync.md 第 3 节。笔记、分组、图片共用这个结构,
/// 只有笔记用到 `contentVersion`。
///
/// 一个文件只由一台设备写:里面是**这台设备**改过的字段和它们的时间戳,
/// 不是这条记录的完整状态。完整状态由 `SyncMerge` 把所有设备的文件合起来得到。
struct SyncRecord: Codable, Hashable {
    var format: Int = SyncFormat.current
    var id: UUID
    var fields: [String: SyncField] = [:]
    /// 只有笔记有:正文的版本向量。
    var contentVersion: VersionVector?
    /// 永久删除标记:删除时的时间戳。写了就永久保留(方案第 9 节第 3 条)。
    var deleted: HLCTimestamp?
}

struct SyncField: Codable, Hashable {
    var value: SyncValue
    var hlc: HLCTimestamp
}

enum SyncFormat {
    /// 读到比这个新的格式就停止同步、提示用户更新 Perch,不去改看不懂的数据。
    static let current = 1
}

/// 记录文件里出现的字段名。和 Core Data 属性名一致的地方保持一致,方便对照。
enum SyncFieldName {
    static let content = "content"
    static let createdAt = "createdAt"
    static let updatedAt = "updatedAt"
    static let groupID = "groupID"
    static let colorIndex = "colorIndex"
    static let displayOrder = "displayOrder"
    static let isTrashed = "isTrashed"
    static let trashedAt = "trashedAt"
    static let isArchived = "isArchived"
    static let archivedAt = "archivedAt"
    static let reminderDate = "reminderDate"
    /// 只出现在冲突副本上:原笔记的 UUID。Core Data 里没有这个字段,同步状态库记着它。
    static let conflictOf = "conflictOf"
}

/// 字段值。日期存成带毫秒的 ISO 8601 UTC 字符串、UUID 存成大写字符串 ——
/// 每台 Mac 写出来的文本完全一样,「内容相同不算冲突」才判断得准。
enum SyncValue: Hashable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)

    static func date(_ date: Date?) -> SyncValue {
        guard let date else { return .null }
        return .string(SyncDateFormat.string(from: date))
    }

    static func uuid(_ uuid: UUID?) -> SyncValue {
        guard let uuid else { return .null }
        return .string(uuid.uuidString)
    }

    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    var dateValue: Date? { stringValue.flatMap(SyncDateFormat.date(from:)) }

    var uuidValue: UUID? { stringValue.flatMap(UUID.init(uuidString:)) }
}

extension SyncValue: Codable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let b = try? container.decode(Bool.self) {
            self = .bool(b)
        } else if let i = try? container.decode(Int.self) {
            self = .int(i)
        } else if let d = try? container.decode(Double.self) {
            self = .double(d)
        } else {
            self = .string(try container.decode(String.self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:          try container.encodeNil()
        case .bool(let b):   try container.encode(b)
        case .int(let i):    try container.encode(i)
        case .double(let d): try container.encode(d)
        case .string(let s): try container.encode(s)
        }
    }
}

enum SyncDateFormat {
    private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    static func string(from date: Date) -> String { formatter.string(from: date) }
    static func date(from string: String) -> Date? { formatter.date(from: string) }
}

extension SyncRecord {
    /// 写文件用的编码器:键排序,同样的内容每次编码出同样的字节,
    /// 「本机文件没变就不重写」直接比字节即可。
    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        return encoder
    }
}
