import Foundation

/// 正文的版本向量。设计见 docs/icloud-drive-sync.md 第 3 节。
///
/// 每台设备改一次正文,就把自己那一项加 1,并带上它当时已经看到的其他设备的计数。
/// 两个版本:一个的每一项都 ≤ 另一个 → 一先一后;各有一项更大 → 互相不知道对方
/// (同时修改)。时间戳只能排先后,分不出这两种情况,所以正文要单独用它。
///
/// 存盘形式是 `{"<设备 ID>": 计数}`。
struct VersionVector: Hashable {
    private(set) var counts: [String: Int]

    init(_ counts: [String: Int] = [:]) {
        self.counts = counts.filter { $0.value > 0 }
    }

    enum Order: Equatable {
        case equal
        /// self 在 other 之前(other 包含了 self 的全部修改)
        case before
        /// self 在 other 之后
        case after
        case concurrent
    }

    func compare(_ other: VersionVector) -> Order {
        var selfAhead = false
        var otherAhead = false
        for device in Set(counts.keys).union(other.counts.keys) {
            let mine = counts[device] ?? 0
            let theirs = other.counts[device] ?? 0
            if mine > theirs { selfAhead = true }
            if theirs > mine { otherAhead = true }
        }
        switch (selfAhead, otherAhead) {
        case (false, false): return .equal
        case (false, true):  return .before
        case (true, false):  return .after
        case (true, true):   return .concurrent
        }
    }

    /// 逐项取最大:合并后的向量包含两边见过的全部修改。
    func merged(with other: VersionVector) -> VersionVector {
        VersionVector(counts.merging(other.counts, uniquingKeysWith: max))
    }

    /// 本机改了一次正文。
    func incremented(for deviceID: String) -> VersionVector {
        var next = counts
        next[deviceID, default: 0] += 1
        return VersionVector(next)
    }
}

extension VersionVector: Codable {
    init(from decoder: Decoder) throws {
        self.init(try decoder.singleValueContainer().decode([String: Int].self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(counts)
    }
}
