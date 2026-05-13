import XCTest
@testable import WildEdge

final class BlobStoreDropFirstTests: XCTestCase {

    private var storePath: String!

    override func setUp() {
        super.setUp()
        let tmp = FileManager.default.temporaryDirectory
        storePath = tmp.appendingPathComponent("blobstore-\(UUID().uuidString).bin").path
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: storePath)
        try? FileManager.default.removeItem(atPath: storePath + ".tmp")
        super.tearDown()
    }

    // MARK: - Helpers

    private func store(_ compaction: BlobStore.CompactionStrategy = .inPlace) throws -> BlobStore {
        try BlobStore(path: storePath, compaction: compaction)
    }

    private func blob(_ string: String) -> Data { Data(string.utf8) }

    private func readAll(_ store: BlobStore) throws -> [BlobStore.Item] {
        let reader = try store.makeReader()
        var items: [BlobStore.Item] = []
        while let item = try reader.next() { items.append(item) }
        return items
    }

    private func payloads(_ store: BlobStore) throws -> [String] {
        try readAll(store).map { String(decoding: $0.data, as: UTF8.self) }
    }

    // MARK: - drop(0) and drop from empty

    func testDropZeroIsNoop_inPlace() throws { try _testDropZeroIsNoop(.inPlace) }
    func testDropZeroIsNoop_rename()  throws { try _testDropZeroIsNoop(.rename)  }
    private func _testDropZeroIsNoop(_ s: BlobStore.CompactionStrategy) throws {
        let st = try store(s)
        try st.append(blob("A")); try st.append(blob("B"))
        try st.dropFirst(0)
        XCTAssertEqual(try payloads(st), ["A", "B"])
    }

    func testDropFromEmpty_inPlace() throws { try _testDropFromEmpty(.inPlace) }
    func testDropFromEmpty_rename()  throws { try _testDropFromEmpty(.rename)  }
    private func _testDropFromEmpty(_ s: BlobStore.CompactionStrategy) throws {
        let st = try store(s)
        XCTAssertNoThrow(try st.dropFirst(3))
        XCTAssertNil(try st.peekHead())
        XCTAssertEqual(try payloads(st), [])
    }

    // MARK: - Basic drop

    func testDropFirst_inPlace() throws { try _testDropFirst(.inPlace) }
    func testDropFirst_rename()  throws { try _testDropFirst(.rename)  }
    private func _testDropFirst(_ s: BlobStore.CompactionStrategy) throws {
        let st = try store(s)
        for p in ["A", "B", "C", "D", "E"] { try st.append(blob(p)) }
        try st.dropFirst(2)
        XCTAssertEqual(try payloads(st), ["C", "D", "E"])
    }

    func testDropOne_inPlace() throws { try _testDropOne(.inPlace) }
    func testDropOne_rename()  throws { try _testDropOne(.rename)  }
    private func _testDropOne(_ s: BlobStore.CompactionStrategy) throws {
        let st = try store(s)
        for p in ["A", "B", "C"] { try st.append(blob(p)) }
        try st.dropFirst(1)
        XCTAssertEqual(try payloads(st), ["B", "C"])
    }

    func testDropAll_inPlace() throws { try _testDropAll(.inPlace) }
    func testDropAll_rename()  throws { try _testDropAll(.rename)  }
    private func _testDropAll(_ s: BlobStore.CompactionStrategy) throws {
        let st = try store(s)
        for p in ["A", "B", "C"] { try st.append(blob(p)) }
        try st.dropFirst(3)
        XCTAssertEqual(try payloads(st), [])
        XCTAssertNil(try st.peekHead())
    }

    func testDropMoreThanExist_inPlace() throws { try _testDropMoreThanExist(.inPlace) }
    func testDropMoreThanExist_rename()  throws { try _testDropMoreThanExist(.rename)  }
    private func _testDropMoreThanExist(_ s: BlobStore.CompactionStrategy) throws {
        let st = try store(s)
        for p in ["A", "B"] { try st.append(blob(p)) }
        try st.dropFirst(100)
        XCTAssertEqual(try payloads(st), [])
        XCTAssertNil(try st.peekHead())
    }

    // MARK: - UUID preservation

    func testUUIDsPreserved_inPlace() throws { try _testUUIDsPreserved(.inPlace) }
    func testUUIDsPreserved_rename()  throws { try _testUUIDsPreserved(.rename)  }
    private func _testUUIDsPreserved(_ s: BlobStore.CompactionStrategy) throws {
        let st = try store(s)
        var ids: [UUID] = []
        for p in ["A", "B", "C", "D"] { ids.append(try st.append(blob(p))) }

        try st.dropFirst(1)

        let remaining = try readAll(st)
        XCTAssertEqual(remaining.count, 3)
        XCTAssertEqual(remaining[0].id, ids[1])
        XCTAssertEqual(remaining[1].id, ids[2])
        XCTAssertEqual(remaining[2].id, ids[3])
    }

    // MARK: - peekHead after drop

    func testPeekHeadAfterDrop_inPlace() throws { try _testPeekHeadAfterDrop(.inPlace) }
    func testPeekHeadAfterDrop_rename()  throws { try _testPeekHeadAfterDrop(.rename)  }
    private func _testPeekHeadAfterDrop(_ s: BlobStore.CompactionStrategy) throws {
        let st = try store(s)
        for p in ["A", "B", "C"] { try st.append(blob(p)) }

        try st.dropFirst(1)
        let head = try st.peekHead()
        XCTAssertEqual(head?.data, blob("B"))

        // peek is non-destructive — calling again returns the same item
        let head2 = try st.peekHead()
        XCTAssertEqual(head2?.data, blob("B"))
    }

    // MARK: - Append after drop

    func testAppendAfterDrop_inPlace() throws { try _testAppendAfterDrop(.inPlace) }
    func testAppendAfterDrop_rename()  throws { try _testAppendAfterDrop(.rename)  }
    private func _testAppendAfterDrop(_ s: BlobStore.CompactionStrategy) throws {
        let st = try store(s)
        for p in ["A", "B", "C"] { try st.append(blob(p)) }
        try st.dropFirst(2)
        try st.append(blob("D"))
        try st.append(blob("E"))
        XCTAssertEqual(try payloads(st), ["C", "D", "E"])
    }

    func testMultipleDropsWithAppends_inPlace() throws { try _testMultipleDropsWithAppends(.inPlace) }
    func testMultipleDropsWithAppends_rename()  throws { try _testMultipleDropsWithAppends(.rename)  }
    private func _testMultipleDropsWithAppends(_ s: BlobStore.CompactionStrategy) throws {
        let st = try store(s)
        for p in ["A", "B", "C"] { try st.append(blob(p)) }
        try st.dropFirst(1)                   // [B, C]
        try st.append(blob("D"))              // [B, C, D]
        try st.dropFirst(1)                   // [C, D]
        try st.append(blob("E"))              // [C, D, E]
        XCTAssertEqual(try payloads(st), ["C", "D", "E"])
    }

    // MARK: - Reader after drop

    func testReaderAfterDrop_inPlace() throws { try _testReaderAfterDrop(.inPlace) }
    func testReaderAfterDrop_rename()  throws { try _testReaderAfterDrop(.rename)  }
    private func _testReaderAfterDrop(_ s: BlobStore.CompactionStrategy) throws {
        let st = try store(s)
        for p in ["A", "B", "C", "D"] { try st.append(blob(p)) }
        try st.dropFirst(2)

        // Reader opened after drop starts at new beginning
        let reader = try st.makeReader()
        XCTAssertEqual(String(decoding: (try reader.next())!.data, as: UTF8.self), "C")
        XCTAssertEqual(String(decoding: (try reader.next())!.data, as: UTF8.self), "D")
        XCTAssertNil(try reader.next())
    }

    // MARK: - Variable-length payloads

    func testVariableLengthPayloads_inPlace() throws { try _testVariableLengthPayloads(.inPlace) }
    func testVariableLengthPayloads_rename()  throws { try _testVariableLengthPayloads(.rename)  }
    private func _testVariableLengthPayloads(_ s: BlobStore.CompactionStrategy) throws {
        let st = try store(s)
        let payloadList = ["x", "hello world", "", String(repeating: "z", count: 500), "end"]
        for p in payloadList { try st.append(blob(p)) }

        try st.dropFirst(2)     // drop "x" and "hello world"

        XCTAssertEqual(try payloads(st), ["", String(repeating: "z", count: 500), "end"])
    }

    func testZeroLengthPayload_inPlace() throws { try _testZeroLengthPayload(.inPlace) }
    func testZeroLengthPayload_rename()  throws { try _testZeroLengthPayload(.rename)  }
    private func _testZeroLengthPayload(_ s: BlobStore.CompactionStrategy) throws {
        let st = try store(s)
        try st.append(Data())       // empty blob at head
        try st.append(blob("B"))
        try st.append(blob("C"))

        try st.dropFirst(1)

        XCTAssertEqual(try payloads(st), ["B", "C"])
    }

    // MARK: - Large payload (triggers multi-chunk copy path)

    func testLargePayload_inPlace() throws { try _testLargePayload(.inPlace) }
    func testLargePayload_rename()  throws { try _testLargePayload(.rename)  }
    private func _testLargePayload(_ s: BlobStore.CompactionStrategy) throws {
        let st = try store(s)
        let large = Data(repeating: 0xAB, count: 128 * 1024)   // 128 KB > 64 KB chunk
        try st.append(blob("head"))
        try st.append(large)
        try st.append(blob("tail"))

        try st.dropFirst(1)     // drop "head", shift 128 KB blob + "tail"

        let items = try readAll(st)
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].data, large)
        XCTAssertEqual(items[1].data, blob("tail"))
    }

    // MARK: - Strategy equivalence

    func testBothStrategiesProduceSameResult() throws {
        // Run identical operations on two stores at different paths.
        let path2 = storePath + ".b"
        defer { try? FileManager.default.removeItem(atPath: path2) }

        let s1 = try BlobStore(path: storePath, compaction: .inPlace)
        let s2 = try BlobStore(path: path2,      compaction: .rename)

        let payloadList = ["alpha", "beta", "gamma", "delta", "epsilon"]
        for p in payloadList {
            try s1.append(blob(p))
            try s2.append(blob(p))
        }

        try s1.dropFirst(2)
        try s2.dropFirst(2)

        let r1 = try payloads(s1)
        let r2 = try payloads(s2)
        XCTAssertEqual(r1, r2)
        XCTAssertEqual(r1, ["gamma", "delta", "epsilon"])
    }
}
