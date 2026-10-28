import Foundation

/// 测试用的小工具:用很短的写法构造时间戳和设备版本。
enum T {
    static func ts(_ millis: Int64, _ device: String, _ counter: Int = 0) -> HLCTimestamp {
        HLCTimestamp(millis: millis, counter: counter, deviceID: device)
    }

    /// 一台设备上的一个笔记版本。`content` = (正文, 时间, 版本向量)。
    static func note(_ id: UUID,
                     on device: String,
                     content: (String, Int64, [String: Int])? = nil,
                     fields: [String: (SyncValue, Int64)] = [:],
                     deleted: Int64? = nil) -> DeviceVersion {
        var record = SyncRecord(id: id)
        for (name, entry) in fields {
            record.fields[name] = SyncField(value: entry.0, hlc: ts(entry.1, device))
        }
        if let content {
            record.fields[SyncFieldName.content] = SyncField(value: .string(content.0),
                                                             hlc: ts(content.1, device))
            record.contentVersion = VersionVector(content.2)
        }
        record.deleted = deleted.map { ts($0, device) }
        return DeviceVersion(deviceID: device, record: record)
    }
}
