import XCTest
@testable import WildEdge

final class BlobStoreDictionaryTests: XCTestCase {

    private var storePath: String!

    override func setUp() {
        super.setUp()
        storePath = FileManager.default.temporaryDirectory
            .appendingPathComponent("blobstore-dict-\(UUID().uuidString).bin").path
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: storePath)
        super.tearDown()
    }

    private func store() throws -> BlobStore { try BlobStore(path: storePath) }

    // Key map covering every key in sampleEvent (including nested and array-element dicts).
    private let sampleKeyMap: [String: String] = [
        "event_id": "eid", "event_type": "et",  "timestamp": "ts",
        "model_id":  "mid", "trace_id":   "tid", "duration_ms": "dur",
        "success":   "ok",  "confidence": "cf",  "tokens_in":   "ti",
        "tokens_out": "to", "hardware":   "hw",  "top_k":       "tk",
        "battery_level": "bl", "battery_charging": "bc", "cpu_freq_mhz": "cf2",
        "label": "lb",
    ]

    // Typical inference event dictionary (mirrors what the SDK actually writes).
    private var sampleEvent: [String: Any] {
        [
            "event_id":        "550e8400-e29b-41d4-a716-446655440000",
            "event_type":      "inference",
            "timestamp":       "2026-05-10T12:00:00.000Z",
            "model_id":        "gpt2-medium",
            "trace_id":        "trace-abc123",
            "duration_ms":     342,
            "success":         true,
            "confidence":      0.97,
            "tokens_in":       128,
            "tokens_out":      256,
            "hardware": [
                "battery_level":   0.85,
                "battery_charging": true,
                "cpu_freq_mhz":    3200,
            ] as [String: Any],
            "top_k": [
                ["label": "cat", "confidence": 0.91],
                ["label": "dog", "confidence": 0.07],
            ] as [Any],
        ]
    }

    // MARK: - JSON round-trip

    func testJSONRoundTrip() throws {
        let st = try store()
        try st.append(sampleEvent, encoding: .json)

        let reader = try st.makeReader()
        let item = try reader.next()!
        let decoded = try item.asDictionary(encoding: .json)

        XCTAssertEqual(decoded["event_id"] as? String, "550e8400-e29b-41d4-a716-446655440000")
        XCTAssertEqual(decoded["event_type"] as? String, "inference")
        XCTAssertEqual(decoded["duration_ms"] as? Int, 342)
        XCTAssertEqual(decoded["success"] as? Bool, true)
    }

    // MARK: - Binary round-trip

    func testBinaryRoundTrip() throws {
        let st = try store()
        try st.append(sampleEvent, encoding: .binary)

        let reader = try st.makeReader()
        let item = try reader.next()!
        let decoded = try item.asDictionary(encoding: .binary)

        XCTAssertEqual(decoded["event_id"] as? String, "550e8400-e29b-41d4-a716-446655440000")
        XCTAssertEqual(decoded["event_type"] as? String, "inference")
        XCTAssertEqual(decoded["duration_ms"] as? Int, 342)
        XCTAssertEqual(decoded["success"] as? Bool, true)
        XCTAssertEqual(try XCTUnwrap(decoded["confidence"] as? Double), 0.97, accuracy: 1e-10)
        XCTAssertEqual(decoded["tokens_in"] as? Int, 128)
    }

    // MARK: - Plist round-trip

    func testPlistRoundTrip() throws {
        let st = try store()
        try st.append(sampleEvent, encoding: .plist)

        let reader = try st.makeReader()
        let item = try reader.next()!
        let decoded = try item.asDictionary(encoding: .plist)

        XCTAssertEqual(decoded["event_id"] as? String, "550e8400-e29b-41d4-a716-446655440000")
        XCTAssertEqual(decoded["event_type"] as? String, "inference")
        XCTAssertEqual(decoded["duration_ms"] as? Int, 342)
        XCTAssertEqual(decoded["success"] as? Bool, true)
        XCTAssertEqual(try XCTUnwrap(decoded["confidence"] as? Double), 0.97, accuracy: 1e-10)
    }

    func testAllSupportedTypes_plist() throws {
        // plist does not support NSNull; all other common types round-trip fine.
        let dict: [String: Any] = [
            "bool_true":  true,
            "bool_false": false,
            "int":        42,
            "double":     3.14159,
            "string":     "hello",
            "data":       Data([0xDE, 0xAD, 0xBE, 0xEF]),
            "nested":     ["inner": "value"] as [String: Any],
            "array":      ["one", "two", "three"] as [Any],
        ]
        let encoded = try BlobStore.DictionaryEncoding.plist.encode(dict)
        let decoded = try BlobStore.DictionaryEncoding.plist.decode(encoded)

        XCTAssertEqual(decoded["bool_true"]  as? Bool,   true)
        XCTAssertEqual(decoded["bool_false"] as? Bool,   false)
        XCTAssertEqual(decoded["int"]        as? Int,    42)
        XCTAssertEqual(try XCTUnwrap(decoded["double"] as? Double), 3.14159, accuracy: 1e-10)
        XCTAssertEqual(decoded["string"]     as? String, "hello")
        XCTAssertEqual(decoded["data"]       as? Data,   Data([0xDE, 0xAD, 0xBE, 0xEF]))

        let nested = decoded["nested"] as? [String: Any]
        XCTAssertEqual(nested?["inner"] as? String, "value")

        let array = decoded["array"] as? [Any]
        XCTAssertEqual(array?.count, 3)
    }

    func testDecodeCorruptData_plist() {
        XCTAssertThrowsError(
            try BlobStore.DictionaryEncoding.plist.decode(Data("not a plist".utf8))
        )
    }

    // MARK: - Compressed JSON round-trip

    func testCompressedJSONRoundTrip() throws {
        let enc = BlobStore.DictionaryEncoding.compressedJSON(keyMap: sampleKeyMap)
        let st = try store()
        try st.append(sampleEvent, encoding: enc)

        let item = try st.makeReader().next()!
        let decoded = try item.asDictionary(encoding: enc)

        // Keys are fully restored after decode.
        XCTAssertEqual(decoded["event_id"]   as? String, "550e8400-e29b-41d4-a716-446655440000")
        XCTAssertEqual(decoded["event_type"] as? String, "inference")
        XCTAssertEqual(decoded["duration_ms"] as? Int,   342)
        XCTAssertEqual(decoded["success"]    as? Bool,   true)
        XCTAssertEqual(decoded["confidence"] as? Double, 0.97)
    }

    func testCompressedJSONNestedKeysRewritten() throws {
        // Verify the raw on-disk bytes use short keys everywhere.
        let enc = BlobStore.DictionaryEncoding.compressedJSON(keyMap: sampleKeyMap)
        let raw = try enc.encode(sampleEvent)
        let onDisk = String(decoding: raw, as: UTF8.self)

        // Short keys present on disk.
        XCTAssertTrue(onDisk.contains("\"eid\""))
        XCTAssertTrue(onDisk.contains("\"hw\""))     // nested dict key
        XCTAssertTrue(onDisk.contains("\"bl\""))     // key inside nested dict
        XCTAssertTrue(onDisk.contains("\"lb\""))     // key inside array-element dict

        // Original long keys must NOT appear.
        XCTAssertFalse(onDisk.contains("\"event_id\""))
        XCTAssertFalse(onDisk.contains("\"hardware\""))
        XCTAssertFalse(onDisk.contains("\"battery_level\""))
        XCTAssertFalse(onDisk.contains("\"label\""))
    }

    func testCompressedJSONUnmappedKeysPassThrough() throws {
        let enc = BlobStore.DictionaryEncoding.compressedJSON(keyMap: ["a": "x"])
        let dict: [String: Any] = ["a": 1, "unmapped": 2]
        let decoded = try enc.decode(enc.encode(dict))
        XCTAssertEqual(decoded["a"]       as? Int, 1)
        XCTAssertEqual(decoded["unmapped"] as? Int, 2)  // unchanged key survives
    }

    func testCompressedJSONIsSmallerThanJSON() throws {
        let plain      = try BlobStore.DictionaryEncoding.json.encode(sampleEvent).count
        let compressed = try BlobStore.DictionaryEncoding.compressedJSON(keyMap: sampleKeyMap)
                             .encode(sampleEvent).count
        print("\n  compressedJSON size: \(compressed) B vs JSON: \(plain) B  (saves \(plain - compressed) B, \(100 * (plain - compressed) / plain)%)\n")
        XCTAssertLessThan(compressed, plain)
    }

    // MARK: - Type coverage

    func testAllSupportedTypes_binary() throws {
        let dict: [String: Any] = [
            "null_val":   NSNull(),
            "bool_true":  true,
            "bool_false": false,
            "int":        42,
            "int64":      Int64(9_999_999_999),
            "double":     3.14159,
            "string":     "hello",
            "data":       Data([0xDE, 0xAD, 0xBE, 0xEF]),
            "nested":     ["inner": "value"] as [String: Any],
            "array":      [1, "two", true] as [Any],
        ]

        let encoded = try BlobStore.DictionaryEncoding.binary.encode(dict)
        let decoded = try BlobStore.DictionaryEncoding.binary.decode(encoded)

        XCTAssertTrue(decoded["null_val"] is NSNull)
        XCTAssertEqual(decoded["bool_true"]  as? Bool, true)
        XCTAssertEqual(decoded["bool_false"] as? Bool, false)
        XCTAssertEqual(decoded["int"]    as? Int,    42)
        XCTAssertEqual(decoded["int64"]  as? Int,    9_999_999_999)
        XCTAssertEqual(try XCTUnwrap(decoded["double"] as? Double), 3.14159, accuracy: 1e-10)
        XCTAssertEqual(decoded["string"] as? String, "hello")
        XCTAssertEqual(decoded["data"]   as? Data,   Data([0xDE, 0xAD, 0xBE, 0xEF]))

        let nested = decoded["nested"] as? [String: Any]
        XCTAssertEqual(nested?["inner"] as? String, "value")

        let array = decoded["array"] as? [Any]
        XCTAssertEqual(array?.count, 3)
        XCTAssertEqual(array?[1] as? String, "two")
    }

    func testBoolNotConfusedWithInt() throws {
        let dict: [String: Any] = ["flag": true, "count": 1]
        let encoded = try BlobStore.DictionaryEncoding.binary.encode(dict)
        let decoded = try BlobStore.DictionaryEncoding.binary.decode(encoded)

        XCTAssertEqual(decoded["flag"]  as? Bool, true)
        XCTAssertNil(decoded["flag"] as? Int)       // must not bleed into Int
        XCTAssertEqual(decoded["count"] as? Int, 1)
        XCTAssertNil(decoded["count"] as? Bool)     // Int 1 must not become Bool
    }

    func testEmptyDictionary() throws {
        let encoded = try BlobStore.DictionaryEncoding.binary.encode([:])
        let decoded = try BlobStore.DictionaryEncoding.binary.decode(encoded)
        XCTAssertTrue(decoded.isEmpty)
    }

    func testEmptyStringValue() throws {
        let encoded = try BlobStore.DictionaryEncoding.binary.encode(["k": ""])
        let decoded = try BlobStore.DictionaryEncoding.binary.decode(encoded)
        XCTAssertEqual(decoded["k"] as? String, "")
    }

    func testUnicodeStrings() throws {
        let dict: [String: Any] = ["emoji": "🔥🧠", "japanese": "日本語"]
        let encoded = try BlobStore.DictionaryEncoding.binary.encode(dict)
        let decoded = try BlobStore.DictionaryEncoding.binary.decode(encoded)
        XCTAssertEqual(decoded["emoji"]    as? String, "🔥🧠")
        XCTAssertEqual(decoded["japanese"] as? String, "日本語")
    }

    // MARK: - Corrupt data

    func testDecodeCorruptData_binary() {
        XCTAssertThrowsError(
            try BlobStore.DictionaryEncoding.binary.decode(Data([0xFF, 0xFF]))
        )
    }

    func testDecodeEmptyData_binary() {
        XCTAssertThrowsError(
            try BlobStore.DictionaryEncoding.binary.decode(Data())
        )
    }

    func testDecodeCorruptData_json() {
        XCTAssertThrowsError(
            try BlobStore.DictionaryEncoding.json.decode(Data("not json".utf8))
        )
    }

    // MARK: - Multiple records, mixed encodings

    func testMultipleRecordsMixedEncodings() throws {
        let st = try store()
        let id1 = try st.append(["type": "a", "n": 1], encoding: .json)
        let id2 = try st.append(["type": "b", "n": 2], encoding: .binary)

        let reader = try st.makeReader()
        let item1 = try reader.next()!
        let item2 = try reader.next()!

        XCTAssertEqual(item1.id, id1)
        XCTAssertEqual(item2.id, id2)

        let d1 = try item1.asDictionary(encoding: .json)
        let d2 = try item2.asDictionary(encoding: .binary)
        XCTAssertEqual(d1["type"] as? String, "a")
        XCTAssertEqual(d2["type"] as? String, "b")
    }
}
