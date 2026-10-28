import XCTest

/// 按 docs/icloud-drive-sync.md 第 4 节的规则表逐条测。
final class SyncMergeTests: XCTestCase {
    private let id = UUID(uuidString: "11111111-2222-4333-8444-555555555555")!

    private func merge(_ versions: [DeviceVersion],
                       context: ConflictContext = ConflictContext()) -> MergedRecord {
        SyncMerge.mergeNote(versions, context: context)!
    }

    // MARK: 字段

    func testDifferentFieldsChangedOnTwoMacsAreBothKept() {
        let a = T.note(id, on: "A", fields: [SyncFieldName.colorIndex: (.int(3), 20)])
        let b = T.note(id, on: "B", fields: [SyncFieldName.groupID: (.string("G"), 30)])
        let merged = merge([a, b])
        XCTAssertEqual(merged.value(SyncFieldName.colorIndex), .int(3))
        XCTAssertEqual(merged.value(SyncFieldName.groupID), .string("G"))
    }

    func testSameFieldChangedOnTwoMacsTakesTheLaterTimestamp() {
        let a = T.note(id, on: "A", fields: [SyncFieldName.colorIndex: (.int(3), 20)])
        let b = T.note(id, on: "B", fields: [SyncFieldName.colorIndex: (.int(5), 30)])
        XCTAssertEqual(merge([a, b]).value(SyncFieldName.colorIndex), .int(5))
        XCTAssertEqual(merge([b, a]).value(SyncFieldName.colorIndex), .int(5))
    }

    // MARK: 正文

    func testSequentialEditsDoNotConflict() {
        // A 改到 v1;B 收到后再改(版本向量包含 A 的修改)
        let a = T.note(id, on: "A", content: ("v1", 10, ["A": 1]))
        let b = T.note(id, on: "B", content: ("v2", 20, ["A": 1, "B": 1]))
        let merged = merge([a, b])
        XCTAssertEqual(merged.value(SyncFieldName.content), .string("v2"))
        XCTAssertTrue(merged.conflictCopies.isEmpty)
    }

    func testOlderVersionWinsWhenItIsNewerInVersionEvenWithAnOlderTimestamp() {
        // B 的版本包含 A 的修改,即使时间戳更小也该用 B 的(系统时间不可靠)
        let a = T.note(id, on: "A", content: ("v1", 50, ["A": 1]))
        let b = T.note(id, on: "B", content: ("v2", 40, ["A": 1, "B": 1]))
        let merged = merge([a, b])
        XCTAssertEqual(merged.value(SyncFieldName.content), .string("v2"))
        XCTAssertTrue(merged.conflictCopies.isEmpty)
    }

    func testConcurrentEditsKeepTheNewerAndMakeAConflictCopyOfTheOther() {
        let a = T.note(id, on: "A", content: ("A 的版本", 20, ["A": 2]))
        let b = T.note(id, on: "B", content: ("B 的版本", 30, ["A": 1, "B": 1]))
        let context = ConflictContext(deviceNames: ["A": "iMac", "B": "MacBook Pro"])
        let merged = merge([a, b], context: context)

        XCTAssertEqual(merged.value(SyncFieldName.content), .string("B 的版本"))
        XCTAssertEqual(merged.conflictCopies.count, 1)
        let copy = merged.conflictCopies[0]
        XCTAssertEqual(copy.originalID, id)
        XCTAssertEqual(copy.sourceDeviceID, "A")
        XCTAssertTrue(copy.content.hasPrefix("> 同步冲突 / Sync conflict — iMac, "))
        XCTAssertTrue(copy.content.hasSuffix("\n\nA 的版本"))
        // 版本向量合并了两边:下次改正文时在它上面加 1,就同时盖过两边
        XCTAssertEqual(merged.contentVersion, VersionVector(["A": 2, "B": 1]))
    }

    func testTwoMacsComputeTheSameConflictCopy() {
        let a = T.note(id, on: "A", content: ("A 的版本", 20, ["A": 2]))
        let b = T.note(id, on: "B", content: ("B 的版本", 30, ["A": 1, "B": 1]))
        let context = ConflictContext(deviceNames: ["A": "iMac"])
        let onA = merge([a, b], context: context).conflictCopies
        let onB = merge([b, a], context: context).conflictCopies
        XCTAssertEqual(onA, onB)
        XCTAssertEqual(onA.first?.makeRecord(), onB.first?.makeRecord())
    }

    func testIdenticalTextIsNeverAConflict() {
        let a = T.note(id, on: "A", content: ("一样", 20, ["A": 1]))
        let b = T.note(id, on: "B", content: ("一样", 30, ["B": 1]))
        XCTAssertTrue(merge([a, b]).conflictCopies.isEmpty)
    }

    func testMacsThatDivergedBeforeEnablingSyncConflict() {
        // 2.8.0 以后两台各自改过、第一次开启同步时各自导出
        let a = T.note(id, on: "A", content: ("A 上改过", 20, ["A": 1]))
        let b = T.note(id, on: "B", content: ("B 上改过", 30, ["B": 1]))
        XCTAssertEqual(merge([a, b]).conflictCopies.count, 1)
    }

    func testThreeWayConflictMakesTwoCopies() {
        let a = T.note(id, on: "A", content: ("a", 10, ["A": 1]))
        let b = T.note(id, on: "B", content: ("b", 20, ["B": 1]))
        let c = T.note(id, on: "C", content: ("c", 30, ["C": 1]))
        let merged = merge([a, b, c])
        XCTAssertEqual(merged.value(SyncFieldName.content), .string("c"))
        XCTAssertEqual(Set(merged.conflictCopies.map(\.sourceDeviceID)), ["A", "B"])
    }

    func testDeletedConflictCopyIsNotGeneratedAgain() {
        let a = T.note(id, on: "A", content: ("A 的版本", 20, ["A": 1]))
        let b = T.note(id, on: "B", content: ("B 的版本", 30, ["B": 1]))
        let copyID = DeterministicUUID.conflictCopy(of: id, content: "A 的版本")
        let context = ConflictContext(isTombstoned: { $0 == copyID })
        XCTAssertTrue(merge([a, b], context: context).conflictCopies.isEmpty)
    }

    func testAConflictCopyNeverMakesCopiesOfItself() {
        let marker: [String: (SyncValue, Int64)] = [SyncFieldName.conflictOf: (.uuid(UUID()), 5)]
        let a = T.note(id, on: "A", content: ("改法一", 20, ["A": 1]), fields: marker)
        let b = T.note(id, on: "B", content: ("改法二", 30, ["B": 1]))
        let merged = merge([a, b])
        XCTAssertTrue(merged.isConflictCopy)
        XCTAssertTrue(merged.conflictCopies.isEmpty)
        XCTAssertEqual(merged.value(SyncFieldName.content), .string("改法二"))
    }

    func testEditingAfterAConflictResolvesIt() {
        let a = T.note(id, on: "A", content: ("A 的版本", 20, ["A": 1]))
        let b = T.note(id, on: "B", content: ("B 的版本", 30, ["B": 1]))
        let joined = merge([a, b]).contentVersion
        // A 看到冲突后再改:新版本向量 = 合并后的 + A 加 1
        let aEdited = T.note(id, on: "A", content: ("整理后的", 40, joined.incremented(for: "A").counts))
        let merged = merge([aEdited, b])
        XCTAssertEqual(merged.value(SyncFieldName.content), .string("整理后的"))
        XCTAssertTrue(merged.conflictCopies.isEmpty)
    }

    // MARK: 回收站

    func testEditAfterTrashOnAnotherMacTakesTheNoteOutOfTrash() {
        let a = T.note(id, on: "A", fields: [SyncFieldName.isTrashed: (.bool(true), 20),
                                             SyncFieldName.trashedAt: (.date(Date()), 20)])
        let b = T.note(id, on: "B", content: ("还在改", 30, ["B": 1]))
        let merged = merge([a, b])
        XCTAssertEqual(merged.value(SyncFieldName.isTrashed), .bool(false))
        XCTAssertEqual(merged.value(SyncFieldName.trashedAt), .null)
    }

    func testEditBeforeTrashLeavesTheNoteInTrash() {
        let a = T.note(id, on: "A", fields: [SyncFieldName.isTrashed: (.bool(true), 30)])
        let b = T.note(id, on: "B", content: ("早先的修改", 20, ["B": 1]))
        XCTAssertEqual(merge([a, b]).value(SyncFieldName.isTrashed), .bool(true))
    }

    // MARK: 永久删除

    func testDeletionWinsOverEarlierEdits() {
        let a = T.note(id, on: "A", content: ("v1", 10, ["A": 1]), deleted: 30)
        let b = T.note(id, on: "B", content: ("v2", 20, ["A": 1, "B": 1]))
        let merged = merge([a, b])
        XCTAssertTrue(merged.isDeleted)
        XCTAssertTrue(merged.fields.isEmpty)
    }

    func testEditAfterDeletionKeepsTheNoteInTrash() {
        let a = T.note(id, on: "A", content: ("v1", 10, ["A": 1]), deleted: 30)
        let b = T.note(id, on: "B", content: ("删除后还在改", 40, ["A": 1, "B": 1]))
        let merged = merge([a, b])
        XCTAssertFalse(merged.isDeleted)
        XCTAssertEqual(merged.value(SyncFieldName.content), .string("删除后还在改"))
        XCTAssertEqual(merged.value(SyncFieldName.isTrashed), .bool(true))
        XCTAssertEqual(merged.fields[SyncFieldName.trashedAt]?.hlc, T.ts(30, "A"))
    }

    func testRestoringFromTrashAfterDeletionSticks() {
        let a = T.note(id, on: "A", content: ("v1", 10, ["A": 1]), deleted: 30)
        let b = T.note(id, on: "B", content: ("删除后还在改", 40, ["A": 1, "B": 1]),
                       fields: [SyncFieldName.isTrashed: (.bool(false), 50)])
        XCTAssertEqual(merge([a, b]).value(SyncFieldName.isTrashed), .bool(false))
    }

    // MARK: 分组、图片

    func testGroupRenameTakesTheLaterOne() {
        let gid = UUID()
        func group(_ device: String, _ name: String, _ millis: Int64) -> DeviceVersion {
            var r = SyncRecord(id: gid)
            r.fields["name"] = SyncField(value: .string(name), hlc: T.ts(millis, device))
            return DeviceVersion(deviceID: device, record: r)
        }
        let merged = SyncMerge.mergeRecord([group("A", "工作", 10), group("B", "Work", 20)])!
        XCTAssertEqual(merged.value("name"), .string("Work"))
    }

    func testDeletedGroupStaysDeletedUnlessChangedLater() {
        let gid = UUID()
        var created = SyncRecord(id: gid)
        created.fields["name"] = SyncField(value: .string("旧分组"), hlc: T.ts(10, "A"))
        var deleted = SyncRecord(id: gid)
        deleted.deleted = T.ts(20, "B")
        let versions = [DeviceVersion(deviceID: "A", record: created),
                        DeviceVersion(deviceID: "B", record: deleted)]
        XCTAssertTrue(SyncMerge.mergeRecord(versions)!.isDeleted)
    }

    // MARK: 和顺序、重复无关

    func testResultDoesNotDependOnOrderOrDuplicates() {
        let versions = [
            T.note(id, on: "A", content: ("a", 10, ["A": 1]),
                   fields: [SyncFieldName.colorIndex: (.int(1), 11),
                            SyncFieldName.isTrashed: (.bool(true), 12)]),
            T.note(id, on: "B", content: ("b", 20, ["B": 1]),
                   fields: [SyncFieldName.colorIndex: (.int(2), 21)]),
            T.note(id, on: "C", content: ("c", 15, ["A": 1, "C": 1]),
                   fields: [SyncFieldName.groupID: (.string("G"), 16)]),
            T.note(id, on: "D", content: ("a", 5, ["A": 1])),   // 和 A 相同的旧版本
        ]
        let context = ConflictContext(deviceNames: ["A": "a", "B": "b", "C": "c"])
        let expected = merge(versions, context: context)
        XCTAssertEqual(expected.conflictCopies.count, 1)

        var generator = SystemRandomNumberGenerator()
        for _ in 0..<50 {
            var shuffled = versions + versions.prefix(Int.random(in: 0...versions.count, using: &generator))
            shuffled.shuffle(using: &generator)
            XCTAssertEqual(merge(shuffled, context: context), expected)
        }
    }

    // MARK: 冲突副本的说明行

    func testConflictHeaderSplitsBackToTheOriginalText() {
        let body = "# 标题\n\n第二段"
        let content = ConflictHeader.make(deviceName: "iMac", date: Date(timeIntervalSince1970: 0)) + "\n\n" + body
        let parts = ConflictHeader.split(content)
        XCTAssertEqual(parts.header, "同步冲突 / Sync conflict — iMac, 1970-01-01 00:00 UTC")
        XCTAssertEqual(parts.body, body)
        XCTAssertNil(ConflictHeader.split("普通便签").header)
        XCTAssertEqual(ConflictHeader.split("普通便签").body, "普通便签")
    }

    // MARK: 固定 UUID

    func testDeterministicUUIDIsAValidVersion5UUID() {
        let uuid = DeterministicUUID.make("conflict-group")
        XCTAssertEqual(uuid, DeterministicUUID.conflictGroupID)
        let text = uuid.uuidString
        XCTAssertEqual(Array(text)[14], "5", "第 13 位十六进制数字是版本号 5")
        XCTAssertTrue("89AB".contains(Array(text)[19]), "variant 位")
        XCTAssertNotEqual(DeterministicUUID.conflictCopy(of: id, content: "x"),
                          DeterministicUUID.conflictCopy(of: id, content: "y"))
    }
}
