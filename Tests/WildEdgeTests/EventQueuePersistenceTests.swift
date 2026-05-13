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

        let q2 = EventQueue(maxSize: 10, fileURL: queueURL)
        XCTAssertEqual(q2.length(), 3)
        let ids = q2.peekMany(3).compactMap { $0["event_id"] as? String }
        XCTAssertEqual(ids, ["a", "b", "c"])
    }

    func testFileCreatedOnInit() {
        // BlobStore opens (and creates) the backing file eagerly in init —
        // lazy creation is no longer guaranteed.
        _ = EventQueue(maxSize: 10, fileURL: queueURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: queueURL.path))
    }

    func testFileExistsAfterFirstAdd() {
        let q = EventQueue(maxSize: 10, fileURL: queueURL)
        q.add(["event_id": "x"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: queueURL.path))
    }

    // MARK: - removeFirstN persisted

    func testRemoveFirstNReflectedAfterReinit() {
        let q1 = EventQueue(maxSize: 10, fileURL: queueURL)
        q1.add(["event_id": "a"])
        q1.add(["event_id": "b"])
        q1.add(["event_id": "c"])
        q1.removeFirstN(2)

        let q2 = EventQueue(maxSize: 10, fileURL: queueURL)
        XCTAssertEqual(q2.length(), 1)
        XCTAssertEqual(q2.peekMany(1).first?["event_id"] as? String, "c")
    }

    func testRemoveAllLeavesEmptyFile() {
        let q1 = EventQueue(maxSize: 10, fileURL: queueURL)
        q1.add(["event_id": "a"])
        q1.add(["event_id": "b"])
        q1.removeFirstN(2)

        let q2 = EventQueue(maxSize: 10, fileURL: queueURL)
        XCTAssertEqual(q2.length(), 0)
    }

    // MARK: - maxSize eviction persisted

    func testEvictionPersistedToFile() {
        let q1 = EventQueue(maxSize: 2, fileURL: queueURL)
        q1.add(["event_id": "1"])
        q1.add(["event_id": "2"])
        q1.add(["event_id": "3"]) // evicts "1"
  
        let q2 = EventQueue(maxSize: 2, fileURL: queueURL)
        XCTAssertEqual(q2.length(), 2)
        let ids = q2.peekMany(2).compactMap { $0["event_id"] as? String }
        XCTAssertEqual(ids, ["2", "3"])
    }

    func testMaxSizeEnforcedOnLoad() {
        // Add 5 events via the queue API, then reload with a smaller maxSize.
        let seed = EventQueue(maxSize: 100, fileURL: queueURL)
        for i in 1...5 { seed.add(["event_id": "\(i)"]) }

        let q = EventQueue(maxSize: 3, fileURL: queueURL)
        XCTAssertEqual(q.length(), 3)
        let ids = q.peekMany(3).compactMap { $0["event_id"] as? String }
        XCTAssertEqual(ids, ["3", "4", "5"])
    }

    // MARK: - Corrupt / unknown file on disk

    func testUnknownFileOnDiskProducesEmptyQueue() {
        // If the file contains data in an unrecognised format (e.g. a leftover
        // NDJSON file from a previous SDK version), BlobStore's reader will
        // fail to parse any records — the queue starts empty and is safe to use.
        let garbage = Data("not-a-blobstore-file\n".utf8)
        try! garbage.write(to: queueURL)

        let q = EventQueue(maxSize: 10, fileURL: queueURL)
        XCTAssertEqual(q.length(), 0)
        q.add(["event_id": "fresh"])
        XCTAssertEqual(q.peekMany(1).first?["event_id"] as? String, "fresh")
    }

    // MARK: - Order preserved

    func testInsertionOrderPreservedAcrossReinit() {
        let q1 = EventQueue(maxSize: 20, fileURL: queueURL)
        for i in 0..<10 {
            q1.add(["seq": i])
        }
 
        let q2 = EventQueue(maxSize: 20, fileURL: queueURL)
        let seqs = q2.peekMany(10).compactMap { $0["seq"] as? Int }
        XCTAssertEqual(seqs, Array(0..<10))
    }
}
