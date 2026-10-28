import Foundation

/// 混合逻辑时钟(HLC)的一个时间戳。设计见 docs/icloud-drive-sync.md 第 3 节。
///
/// 以系统时间(毫秒)为主,同一毫秒内用 `counter` 区分先后,最后用设备 ID 决胜 ——
/// 两个时间戳永远不会相等,合并时「取时间戳大的」总有唯一结果。
/// 存盘形式是字符串 `<毫秒>-<计数>-<设备 ID>`,例如 `00001730106245123-000002-A1B2…`。
/// 比较用结构体的 `<`,不要拿字符串比(计数位数不固定时字符串顺序不可靠)。
struct HLCTimestamp: Hashable, Comparable, CustomStringConvertible {
    let millis: Int64
    let counter: Int
    let deviceID: String

    static func < (a: HLCTimestamp, b: HLCTimestamp) -> Bool {
        if a.millis != b.millis { return a.millis < b.millis }
        if a.counter != b.counter { return a.counter < b.counter }
        return a.deviceID < b.deviceID
    }

    var description: String {
        String(format: "%017lld-%06d-", millis, counter) + deviceID
    }

    init(millis: Int64, counter: Int, deviceID: String) {
        self.millis = millis
        self.counter = counter
        self.deviceID = deviceID
    }

    /// 解析 `description` 的格式。设备 ID 里本身可能有 `-`(UUID),所以只切前两段。
    init?(_ string: String) {
        let parts = string.split(separator: "-", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3,
              let millis = Int64(parts[0]),
              let counter = Int(parts[1]),
              !parts[2].isEmpty else { return nil }
        self.init(millis: millis, counter: counter, deviceID: String(parts[2]))
    }

    /// 时间戳对应的系统时间(毫秒精度)。用于冲突副本说明行、`trashedAt` 之类。
    var date: Date { Date(timeIntervalSince1970: Double(millis) / 1000) }
}

extension HLCTimestamp: Codable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let value = HLCTimestamp(raw) else {
            throw DecodingError.dataCorruptedError(in: container,
                                                   debugDescription: "Bad HLC timestamp: \(raw)")
        }
        self = value
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

/// 本机的混合逻辑时钟。标准 HLC 算法:
/// - 本机事件(`tick`):取「上次时间」和「系统时间」较大者;没前进就计数加 1。
/// - 收到其他设备的时间戳(`observe`):再把对方的时间也算进来,保证之后本机打出的
///   时间戳一定比见过的都大 —— 两台 Mac 系统时间差几秒,先后顺序也不会乱。
///
/// `wallMillis` 由调用方传入(测试里可以固定),正式代码传当前时间。
struct HybridLogicalClock {
    let deviceID: String
    private(set) var millis: Int64
    private(set) var counter: Int

    init(deviceID: String, millis: Int64 = 0, counter: Int = 0) {
        self.deviceID = deviceID
        self.millis = millis
        self.counter = counter
    }

    static func currentWallMillis() -> Int64 {
        Int64((Date().timeIntervalSince1970 * 1000).rounded(.down))
    }

    mutating func tick(wallMillis: Int64 = currentWallMillis()) -> HLCTimestamp {
        if wallMillis > millis {
            millis = wallMillis
            counter = 0
        } else {
            counter += 1
        }
        return HLCTimestamp(millis: millis, counter: counter, deviceID: deviceID)
    }

    mutating func observe(_ remote: HLCTimestamp, wallMillis: Int64 = currentWallMillis()) {
        let next = max(millis, remote.millis, wallMillis)
        if next == millis && next == remote.millis {
            counter = max(counter, remote.counter) + 1
        } else if next == millis {
            counter += 1
        } else if next == remote.millis {
            counter = remote.counter + 1
        } else {
            counter = 0
        }
        millis = next
    }
}
