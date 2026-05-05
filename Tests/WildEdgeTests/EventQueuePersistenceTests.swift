import XCTest
@testable import WildEdge

final class EventQueuePersistenceTests: XCTestCase {
    private var queueURL: URL!

    override func setUp() {
        super.setUp()
        let id = UUID().uuidString
        queueURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("wildedge-test-\(id).ndjson")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: queueURL)
        super.tearDown()
    }

    // MARK: - Persistence across reinit

    func testEventsRestoredAfterReinit() {
        let q1 = EventQueue(maxSize: 10, fileURL: queueURL)
        q1.add(["event_id": "a"])
        q1.add(["event_id": "b"])
        q1.add(["event_id": "c"])
        q1.waitForPendingWrites()

        let q2 = EventQueue(maxSize: 10, fileURL: queueURL)
        XCTAssertEqual(q2.length(), 3)
        let ids = q2.peekMany(3).compactMap { $0["event_id"] as? String }
        XCTAssertEqual(ids, ["a", "b", "c"])
    }

    func testEmptyQueueCreatesNoFileUntilFirstAdd() {
        _ = EventQueue(maxSize: 10, fileURL: queueURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: queueURL.path))
    }

    func testFileExistsAfterFirstAdd() {
        let q = EventQueue(maxSize: 10, fileURL: queueURL)
        q.add(["event_id": "x"])
        q.waitForPendingWrites()
        XCTAssertTrue(FileManager.default.fileExists(atPath: queueURL.path))
    }

    // MARK: - removeFirstN persisted

    func testRemoveFirstNReflectedAfterReinit() {
        let q1 = EventQueue(maxSize: 10, fileURL: queueURL)
        q1.add(["event_id": "a"])
        q1.add(["event_id": "b"])
        q1.add(["event_id": "c"])
        q1.removeFirstN(2)
        q1.waitForPendingWrites()

        let q2 = EventQueue(maxSize: 10, fileURL: queueURL)
        XCTAssertEqual(q2.length(), 1)
        XCTAssertEqual(q2.peekMany(1).first?["event_id"] as? String, "c")
    }

    func testRemoveAllLeavesEmptyFile() {
        let q1 = EventQueue(maxSize: 10, fileURL: queueURL)
        q1.add(["event_id": "a"])
        q1.add(["event_id": "b"])
        q1.removeFirstN(2)
        q1.waitForPendingWrites()

        let q2 = EventQueue(maxSize: 10, fileURL: queueURL)
        XCTAssertEqual(q2.length(), 0)
    }

    // MARK: - maxSize eviction persisted

    func testEvictionPersistedToFile() {
        let q1 = EventQueue(maxSize: 2, fileURL: queueURL)
        q1.add(["event_id": "1"])
        q1.add(["event_id": "2"])
        q1.add(["event_id": "3"]) // evicts "1"
        q1.waitForPendingWrites()

        let q2 = EventQueue(maxSize: 2, fileURL: queueURL)
        XCTAssertEqual(q2.length(), 2)
        let ids = q2.peekMany(2).compactMap { $0["event_id"] as? String }
        XCTAssertEqual(ids, ["2", "3"])
    }

    func testMaxSizeEnforcedOnLoad() {
        // write 5 lines directly, then load with maxSize=3
        let lines = (1...5).map { "{\"event_id\":\"\($0)\"}" }.joined(separator: "\n") + "\n"
        try! Data(lines.utf8).write(to: queueURL)

        let q = EventQueue(maxSize: 3, fileURL: queueURL)
        XCTAssertEqual(q.length(), 3)
        let ids = q.peekMany(3).compactMap { $0["event_id"] as? String }
        XCTAssertEqual(ids, ["3", "4", "5"])
    }

    // MARK: - Corrupt / partial lines

    func testCorruptLinesSkippedOnLoad() {
        let content = "{\"event_id\":\"a\"}\nnot-json\n{\"event_id\":\"b\"}\n"
        try! Data(content.utf8).write(to: queueURL)

        let q = EventQueue(maxSize: 10, fileURL: queueURL)
        XCTAssertEqual(q.length(), 2)
        let ids = q.peekMany(2).compactMap { $0["event_id"] as? String }
        XCTAssertEqual(ids, ["a", "b"])
    }

    func testPartialLastLineSkippedOnLoad() {
        // last line has no closing brace — simulates a kill mid-write
        let content = "{\"event_id\":\"a\"}\n{\"event_id\":\"b\"\n"
        try! Data(content.utf8).write(to: queueURL)

        let q = EventQueue(maxSize: 10, fileURL: queueURL)
        XCTAssertEqual(q.length(), 1)
        XCTAssertEqual(q.peekMany(1).first?["event_id"] as? String, "a")
    }

    func testAllCorruptLinesProducesEmptyQueue() {
        let content = "not-json\nalso-not-json\n"
        try! Data(content.utf8).write(to: queueURL)

        let q = EventQueue(maxSize: 10, fileURL: queueURL)
        XCTAssertEqual(q.length(), 0)
    }

    // MARK: - No file URL (memory-only)

    func testMemoryOnlyQueueLeavesNoDisk() {
        let q = EventQueue(maxSize: 10)
        q.add(["event_id": "x"])
        q.removeFirstN(1)
        XCTAssertEqual(q.length(), 0)
    }

    // MARK: - Order preserved

    func testInsertionOrderPreservedAcrossReinit() {
        let q1 = EventQueue(maxSize: 20, fileURL: queueURL)
        for i in 0..<10 {
            q1.add(["seq": i])
        }
        q1.waitForPendingWrites()

        let q2 = EventQueue(maxSize: 20, fileURL: queueURL)
        let seqs = q2.peekMany(10).compactMap { $0["seq"] as? Int }
        XCTAssertEqual(seqs, Array(0..<10))
    }
}
