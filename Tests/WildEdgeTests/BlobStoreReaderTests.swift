import XCTest
@testable import WildEdge

final class BlobStoreReaderTests: XCTestCase {

    private var storePath: String!

    override func setUp() {
        super.setUp()
        storePath = FileManager.default.temporaryDirectory
            .appendingPathComponent("blobstore-reader-\(UUID().uuidString).bin").path
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: storePath)
        super.tearDown()
    }

    // MARK: - Helpers

    private func store() throws -> BlobStore { try BlobStore(path: storePath) }
    private func blob(_ s: String) -> Data { Data(s.utf8) }
    private func str(_ item: BlobStore.Item) -> String { String(decoding: item.data, as: UTF8.self) }

    // MARK: - Empty store

    func testEmptyStoreReturnsNil() throws {
        let reader = try store().makeReader()
        XCTAssertNil(try reader.next())
    }

    func testEmptyStoreOffsetIsZero() throws {
        let reader = try store().makeReader()
        XCTAssertEqual(reader.offset, 0)
        _ = try reader.next()
        XCTAssertEqual(reader.offset, 0)
    }

    // MARK: - Basic sequential reads

    func testReadsSingleRecord() throws {
        let st = try store()
        try st.append(blob("hello"))
        let reader = try st.makeReader()
        let item = try reader.next()
        XCTAssertEqual(str(item!), "hello")
        XCTAssertNil(try reader.next())
    }

    func testReadsRecordsInOrder() throws {
        let st = try store()
        for p in ["A", "B", "C", "D"] { try st.append(blob(p)) }
        let reader = try st.makeReader()
        var got: [String] = []
        while let item = try reader.next() { got.append(str(item)) }
        XCTAssertEqual(got, ["A", "B", "C", "D"])
    }

    func testNextReturnsNilAtEOF() throws {
        let st = try store()
        try st.append(blob("X"))
        let reader = try st.makeReader()
        _ = try reader.next()
        XCTAssertNil(try reader.next())
        XCTAssertNil(try reader.next())     // repeated calls stay at nil
    }

    // MARK: - Offset tracking

    func testOffsetAdvancesPerRecord() throws {
        let st = try store()
        try st.append(blob("A"))            // 1 byte payload
        try st.append(blob("BB"))           // 2 bytes
        try st.append(blob("CCC"))          // 3 bytes

        let headerSize: Int64 = 20          // 16 UUID + 4 length
        let reader = try st.makeReader()

        XCTAssertEqual(reader.offset, 0)
        _ = try reader.next()
        XCTAssertEqual(reader.offset, headerSize + 1)
        _ = try reader.next()
        XCTAssertEqual(reader.offset, headerSize + 1 + headerSize + 2)
        _ = try reader.next()
        XCTAssertEqual(reader.offset, headerSize + 1 + headerSize + 2 + headerSize + 3)
    }

    func testOffsetDoesNotMoveAtEOF() throws {
        let st = try store()
        try st.append(blob("X"))
        let reader = try st.makeReader()
        _ = try reader.next()
        let eofOffset = reader.offset
        _ = try reader.next()
        XCTAssertEqual(reader.offset, eofOffset)
    }

    // MARK: - reset()

    func testResetRewindsToStart() throws {
        let st = try store()
        for p in ["A", "B", "C"] { try st.append(blob(p)) }
        let reader = try st.makeReader()

        var first: [String] = []
        while let item = try reader.next() { first.append(str(item)) }

        reader.reset()
        XCTAssertEqual(reader.offset, 0)

        var second: [String] = []
        while let item = try reader.next() { second.append(str(item)) }

        XCTAssertEqual(first, second)
        XCTAssertEqual(second, ["A", "B", "C"])
    }

    func testResetAfterPartialRead() throws {
        let st = try store()
        for p in ["A", "B", "C", "D", "E"] { try st.append(blob(p)) }
        let reader = try st.makeReader()

        _ = try reader.next()   // A
        _ = try reader.next()   // B
        reader.reset()

        var got: [String] = []
        while let item = try reader.next() { got.append(str(item)) }
        XCTAssertEqual(got, ["A", "B", "C", "D", "E"])
    }

    // MARK: - Multiple independent readers

    func testMultipleReadersAreIndependent() throws {
        let st = try store()
        for p in ["A", "B", "C"] { try st.append(blob(p)) }

        let r1 = try st.makeReader()
        let r2 = try st.makeReader()

        XCTAssertEqual(str((try r1.next())!), "A")     // r1 → A
        XCTAssertEqual(str((try r1.next())!), "B")     // r1 → B
        XCTAssertEqual(str((try r2.next())!), "A")     // r2 still at start → A
        XCTAssertEqual(str((try r1.next())!), "C")     // r1 → C
        XCTAssertEqual(str((try r2.next())!), "B")     // r2 → B
    }

    // MARK: - UUID preservation

    func testUUIDsMatchAppendReturn() throws {
        let st = try store()
        let id1 = try st.append(blob("first"))
        let id2 = try st.append(blob("second"))

        let reader = try st.makeReader()
        XCTAssertEqual((try reader.next())!.id, id1)
        XCTAssertEqual((try reader.next())!.id, id2)
    }

    // MARK: - Payload edge cases

    func testZeroLengthPayload() throws {
        let st = try store()
        try st.append(Data())               // empty blob
        try st.append(blob("after"))

        let reader = try st.makeReader()
        let first = try reader.next()
        XCTAssertNotNil(first)
        XCTAssertEqual(first!.data, Data())
        XCTAssertEqual(str((try reader.next())!), "after")
        XCTAssertNil(try reader.next())
    }

    func testVariableLengthPayloads() throws {
        let payloads = ["x", String(repeating: "y", count: 300), "", "end"]
        let st = try store()
        for p in payloads { try st.append(blob(p)) }

        let reader = try st.makeReader()
        var got: [String] = []
        while let item = try reader.next() { got.append(str(item)) }
        XCTAssertEqual(got, payloads)
    }

    func testLargePayload() throws {
        let large = Data(repeating: 0xCD, count: 128 * 1_024)   // 128 KB — multi-chunk pread
        let st = try store()
        try st.append(blob("before"))
        try st.append(large)
        try st.append(blob("after"))

        let reader = try st.makeReader()
        XCTAssertEqual(str((try reader.next())!), "before")
        XCTAssertEqual((try reader.next())!.data, large)
        XCTAssertEqual(str((try reader.next())!), "after")
        XCTAssertNil(try reader.next())
    }

    // MARK: - Reader sees appends made after it was opened

    func testReaderSeesSubsequentAppends() throws {
        // The reader holds an O_RDONLY fd to the same inode as the store.
        // pread(2) at offsets written after makeReader() still returns data
        // because the fd tracks the live inode, not a snapshot.
        let st = try store()
        try st.append(blob("A"))
        try st.append(blob("B"))

        let reader = try st.makeReader()
        XCTAssertEqual(str((try reader.next())!), "A")

        // Append two more records while reader is mid-stream.
        try st.append(blob("C"))
        try st.append(blob("D"))

        XCTAssertEqual(str((try reader.next())!), "B")
        XCTAssertEqual(str((try reader.next())!), "C")
        XCTAssertEqual(str((try reader.next())!), "D")
        XCTAssertNil(try reader.next())
    }

    // MARK: - Reader is independent of the store object's lifetime

    func testReaderOutlivesStore() throws {
        let reader: BlobReader
        do {
            let st = try store()
            try st.append(blob("persist"))
            reader = try st.makeReader()
        }   // store deallocated here — its fds are closed

        // Reader's own fd is still open and valid.
        let item = try reader.next()
        XCTAssertEqual(str(item!), "persist")
    }
}
