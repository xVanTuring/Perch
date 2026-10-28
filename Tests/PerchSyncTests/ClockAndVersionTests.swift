import XCTest

final class ClockAndVersionTests: XCTestCase {

    // MARK: 混合逻辑时钟

    func testTickIsMonotonicWithinTheSameMillisecond() {
        var clock = HybridLogicalClock(deviceID: "A")
        let a = clock.tick(wallMillis: 1000)
        let b = clock.tick(wallMillis: 1000)
        let c = clock.tick(wallMillis: 999)   // 系统时间往回调了
        XCTAssertLessThan(a, b)
        XCTAssertLessThan(b, c)
        XCTAssertEqual(c.millis, 1000)
    }

    func testObservingARemoteTimestampAheadMovesTheClockPastIt() {
        var clock = HybridLogicalClock(deviceID: "A")
        _ = clock.tick(wallMillis: 1000)
        let remote = T.ts(5000, "B", 3)   // 另一台 Mac 系统时间快了 4 秒
        clock.observe(remote, wallMillis: 1001)
        let next = clock.tick(wallMillis: 1002)
        XCTAssertGreaterThan(next, remote, "之后本机打出的时间戳必须比见过的都大")
    }

    func testTimestampStringRoundTripKeepsDashesInTheDeviceID() {
        let original = T.ts(1_730_106_245_123, "6F1C2D3E-0000-4000-8000-000000000001", 42)
        XCTAssertEqual(HLCTimestamp(original.description), original)
        XCTAssertNil(HLCTimestamp("garbage"))
    }

    func testDeviceIDBreaksTiesSoTimestampsNeverCompareEqual() {
        XCTAssertLessThan(T.ts(1000, "A"), T.ts(1000, "B"))
    }

    // MARK: 版本向量

    func testVersionVectorOrdering() {
        let base = VersionVector(["A": 1])
        let afterA = base.incremented(for: "A")              // {A:2}
        let afterB = base.incremented(for: "B")              // {A:1, B:1}
        XCTAssertEqual(base.compare(afterA), .before)
        XCTAssertEqual(afterA.compare(base), .after)
        XCTAssertEqual(afterA.compare(afterB), .concurrent)
        XCTAssertEqual(afterA.compare(VersionVector(["A": 2])), .equal)

        let joined = afterA.merged(with: afterB)              // {A:2, B:1}
        XCTAssertEqual(joined.compare(afterA), .after)
        XCTAssertEqual(joined.compare(afterB), .after)
    }

    func testZeroEntriesAreIgnored() {
        XCTAssertEqual(VersionVector(["A": 0]).compare(VersionVector()), .equal)
    }

    // MARK: 文件格式

    func testRecordEncodingIsStableAndRoundTrips() throws {
        var record = SyncRecord(id: UUID(uuidString: "6F1C2D3E-0000-4000-8000-000000000001")!)
        record.fields[SyncFieldName.content] = SyncField(value: .string("# 标题\n正文"), hlc: T.ts(10, "A"))
        record.fields[SyncFieldName.colorIndex] = SyncField(value: .int(3), hlc: T.ts(11, "A"))
        record.fields[SyncFieldName.isTrashed] = SyncField(value: .bool(false), hlc: T.ts(12, "A"))
        record.fields[SyncFieldName.reminderDate] = SyncField(value: .null, hlc: T.ts(13, "A"))
        record.contentVersion = VersionVector(["A": 2, "B": 1])
        record.deleted = T.ts(14, "A")

        let encoder = SyncRecord.makeEncoder()
        let first = try encoder.encode(record)
        let decoded = try JSONDecoder().decode(SyncRecord.self, from: first)
        XCTAssertEqual(decoded, record)
        XCTAssertEqual(try encoder.encode(decoded), first, "同样的内容必须编码出同样的字节")
    }

    func testDatesRoundTripToTheMillisecond() {
        let date = Date(timeIntervalSince1970: 1_730_106_245.123)
        XCTAssertEqual(SyncValue.date(date).dateValue?.timeIntervalSince1970 ?? 0,
                       date.timeIntervalSince1970, accuracy: 0.0005)
    }
}
