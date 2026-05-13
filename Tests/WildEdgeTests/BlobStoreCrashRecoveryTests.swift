import XCTest
@testable import WildEdge

final class BlobStoreCrashRecoveryTests: XCTestCase {

    private var storePath: String!

    override func setUp() {
        super.setUp()
        storePath = FileManager.default.temporaryDirectory
            .appendingPathComponent("blobstore-crash-\(UUID().uuidString).bin").path
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: storePath)
        try? FileManager.default.removeItem(atPath: storePath + ".tmp")
        super.tearDown()
    }

    private func blob(_ s: String) -> Data { Data(s.utf8) }
    private func str(_ item: BlobStore.Item) -> String { String(decoding: item.data, as: UTF8.self) }

    private func readAll(_ st: BlobStore) throws -> [String] {
        let reader = try st.makeReader()
        var out: [String] = []
        while let item = try reader.next() { out.append(str(item)) }
        return out
    }

    // Builds one raw BlobStore record: 16-byte UUID + 4-byte LE payload length + payload.
    private func makeRecord(payload: Data) -> Data {
        var rec = Data(capacity: 20 + payload.count)
        var u = UUID().uuid
        withUnsafeBytes(of: &u) { rec.append(contentsOf: $0) }
        var len = UInt32(payload.count).littleEndian
        withUnsafeBytes(of: &len) { rec.append(contentsOf: $0) }
        rec.append(payload)
        return rec
    }

    // MARK: - 1. rename: stale .tmp sidecar left from prior crash

    // A .rename compaction crashes after writing the .tmp sidecar but before rename(2).
    // The original store file is untouched; the sidecar holds stale bytes.
    // On reopening, the store reads from the original file (BlobStore.init never inspects
    // .tmp). A subsequent dropFirst(.rename) must overwrite the stale sidecar correctly.
    func testStaleTmpSidecarDoesNotCorruptReopen() throws {
        let st1 = try BlobStore(path: storePath, compaction: .rename)
        try st1.append(blob("A"))
        try st1.append(blob("B"))
        try st1.append(blob("C"))

        // Simulate crash mid-rename: leave a stale sidecar with arbitrary bytes.
        try Data("stale-garbage".utf8).write(
            to: URL(fileURLWithPath: storePath + ".tmp"))

        // Reopen — must see the original 3 records, not the stale sidecar.
        let st2 = try BlobStore(path: storePath, compaction: .rename)
        XCTAssertEqual(try readAll(st2), ["A", "B", "C"])

        // dropFirst overwrites the stale sidecar via O_TRUNC and proceeds correctly.
        try st2.dropFirst(1)
        XCTAssertEqual(try readAll(st2), ["B", "C"])

        // Subsequent appends work normally.
        try st2.append(blob("D"))
        XCTAssertEqual(try readAll(st2), ["B", "C", "D"])
    }

    // MARK: - 2. inPlace: truncated header (crash mid-shift, partial header written)

    // A .inPlace compaction crashes after shifting only a partial header to offset 0.
    // The file contains one complete record followed by fewer than 20 header bytes.
    // count() must stop at the truncated header without throwing.
    // makeReader().next() must throw .truncated when it reaches the partial header.
    func testTruncatedHeaderStopsCountAndThrowsOnRead() throws {
        var raw = makeRecord(payload: blob("A"))
        raw.append(Data(repeating: 0xFF, count: 10))  // 10 of 20 header bytes — partial header
        try raw.write(to: URL(fileURLWithPath: storePath))

        let st = try BlobStore(path: storePath)

        XCTAssertEqual(try st.count(), 1)

        let reader = try st.makeReader()
        XCTAssertEqual(str(try XCTUnwrap(reader.next())), "A")
        XCTAssertThrowsError(try reader.next())
    }

    // MARK: - 3. Truncated payload (header intact, payload shorter than declared)

    // The last record's header claims a payload length that extends past the end of file —
    // i.e. a write(2) was interrupted mid-payload.
    // count() must exclude that record without throwing.
    // makeReader().next() must throw .truncated when it reads the incomplete payload.
    func testTruncatedPayloadStopsCountAndThrowsOnRead() throws {
        var raw = makeRecord(payload: blob("A"))

        // Append a syntactically valid 20-byte header claiming 1 000-byte payload.
        var u = UUID().uuid
        withUnsafeBytes(of: &u) { raw.append(contentsOf: $0) }   // 16-byte UUID
        var len = UInt32(1000).littleEndian
        withUnsafeBytes(of: &len) { raw.append(contentsOf: $0) }  // 4-byte length: 1 000
        raw.append(Data(repeating: 0xAB, count: 5))               // only 5 of 1 000 payload bytes

        try raw.write(to: URL(fileURLWithPath: storePath))

        let st = try BlobStore(path: storePath)

        // count() sees the truncated record's nextOffset exceeds file size → stops at 1.
        XCTAssertEqual(try st.count(), 1)

        let reader = try st.makeReader()
        XCTAssertEqual(str(try XCTUnwrap(reader.next())), "A")
        XCTAssertThrowsError(try reader.next())
    }
}
