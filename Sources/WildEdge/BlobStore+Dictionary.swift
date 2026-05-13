import Foundation

// MARK: - Encoding benchmarks (1 000 events per iteration, +1 warmup, 5 measured)
//
// Payload: fully-populated inference event (all optional fields filled in).
// cjson = compressedJSON with a 30-key alias map covering every event field.
//
//                           json       binary      plist       cjson       winner
//   ─────────────────────────────────────────────────────────────────────────────
//   encoded size           1325 B      1315 B      1430 B       842 B      cjson  (36% vs json)
//   ─────────────────────────────────────────────────────────────────────────────
//   Apple M4 Pro · macOS 15 · debug
//   encode / event        101.46 µs   75.54 µs   57.91 µs   113.01 µs    plist
//   decode / event         17.23 µs   31.08 µs   17.57 µs    66.70 µs    json
//   ─────────────────────────────────────────────────────────────────────────────
//   iPhone 13 · A15 · iOS 26 · debug
//   encode / event         74.4 µs    69.1 µs    52.5 µs     95.9 µs     plist
//   decode / event         16.2 µs    33.5 µs    16.3 µs     63.0 µs     json
//   ─────────────────────────────────────────────────────────────────────────────
//
// Size: compressedJSON wins by a wide margin (842 B) — all savings come from
// replacing long key names with 2-4 char aliases; values and JSON structure
// are unchanged. Binary (1315 B) and plain JSON (1325 B) are nearly tied.
// Plist is the largest (1430 B) due to its offset-table overhead.
//
// Encode: plist wins on both platforms — Foundation's binary plist writer is
// optimised C. iPhone A15 encodes faster than M4 Pro for all formats: CPU-bound
// serialisation scales with single-core speed, where A15 is competitive.
// compressedJSON is slowest: two full-tree traversals (key-map + JSONSerialization).
//
// Decode: json and plist are tied on both platforms (~16–17 µs) — both use
// compiled-C parsers in Foundation. Binary is slower (31–33 µs): a Swift
// withUnsafeBytes pass with a tag-switch per field vs Foundation's bulk C scanner.
// compressedJSON is slowest (63–67 µs): JSON parse + reverse key-map walk.
//
// Recommendation: use compressedJSON when storage/bandwidth is the bottleneck
// and the key map is stable across SDK versions — it gives the smallest payload
// at the cost of a ~1.1× encode and ~3.9× decode overhead vs plain JSON.
//

// MARK: - Public API

extension BlobStore {

    /// Serialisation format used when appending or reading a `[String: Any]` record.
    public enum DictionaryEncoding {
        /// Standard JSON via `JSONSerialization`.
        /// Human-readable; larger on disk; slower to encode/decode.
        case json

        /// Compact tag-length-value binary format (see format notes below).
        /// Not human-readable; ~30-50% smaller than JSON for typical event dicts;
        /// faster to encode and decode.
        case binary

        /// Apple binary property-list via `PropertyListSerialization`.
        /// Supports all plist value types (String, Int, Double, Bool, Data,
        /// Array, Dictionary). Implemented in optimised C inside Foundation;
        /// decode speed is comparable to JSON. Not available outside Apple platforms.
        case plist

        /// Standard JSON, but all dictionary keys are replaced with short aliases
        /// before encoding and restored after decoding using an external key map.
        /// The key map is never embedded in the payload — both sides must use
        /// the same map. Keys absent from the map are passed through unchanged.
        /// Applied recursively to all nested dictionaries and arrays.
        case compressedJSON(keyMap: [String: String])
    }

    enum DictionaryEncodingError: Error {
        /// The value cannot be serialised (JSON path: not a valid JSON object).
        case unserialisable
        /// The binary data is truncated or contains an unknown type tag.
        case corrupted
        /// A dictionary key exceeds 65 535 UTF-8 bytes (binary path only).
        case keyTooLong
    }

    /// Serialises `dictionary` and appends it as a single record. Returns the UUID.
    @discardableResult
    func append(_ dictionary: [String: Any],
                encoding: DictionaryEncoding = .json) throws -> UUID {
        try append(encoding.encode(dictionary))
    }
}

// MARK: - Round-trip encode / decode

public extension BlobStore.DictionaryEncoding {

    func encode(_ dict: [String: Any]) throws -> Data {
        switch self {
        case .json:                          return try _jsonEncode(dict)
        case .binary:                        return try _binEncode(dict)
        case .plist:                         return try _plistEncode(dict)
        case .compressedJSON(let keyMap):    return try _jsonEncode(_applyKeyMap(dict, map: keyMap))
        }
    }

    func decode(_ data: Data) throws -> [String: Any] {
        switch self {
        case .json:                          return try _jsonDecode(data)
        case .binary:                        return try _binDecode(data)
        case .plist:                         return try _plistDecode(data)
        case .compressedJSON(let keyMap):
            let reverse = Dictionary(uniqueKeysWithValues: keyMap.map { ($0.value, $0.key) })
            return _applyKeyMap(try _jsonDecode(data), map: reverse)
        }
    }
}

extension BlobStore.Item {
    /// Deserialises this item's payload as a `[String: Any]` dictionary.
    func asDictionary(encoding: BlobStore.DictionaryEncoding = .json) throws -> [String: Any] {
        try encoding.decode(data)
    }
}

// MARK: - Compressed JSON helpers

/// Recursively replaces every dictionary key using `map`; keys absent from
/// the map are passed through unchanged. Applied depth-first so nested dicts
/// and dicts inside arrays are all rewritten in a single traversal.
private func _applyKeyMap(_ dict: [String: Any], map: [String: String]) -> [String: Any] {
    var out = [String: Any](minimumCapacity: dict.count)
    for (key, value) in dict {
        out[map[key] ?? key] = _applyKeyMapValue(value, map: map)
    }
    return out
}

private func _applyKeyMapValue(_ value: Any, map: [String: String]) -> Any {
    switch value {
    case let d as [String: Any]: return _applyKeyMap(d, map: map)
    case let a as [Any]:         return a.map { _applyKeyMapValue($0, map: map) }
    default:                     return value
    }
}

// MARK: - Plist path

private func _plistEncode(_ dict: [String: Any]) throws -> Data {
    guard PropertyListSerialization.propertyList(dict, isValidFor: .binary) else {
        throw BlobStore.DictionaryEncodingError.unserialisable
    }
    return try PropertyListSerialization.data(fromPropertyList: dict, format: .binary, options: .init())
}

private func _plistDecode(_ data: Data) throws -> [String: Any] {
    let obj = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
    guard let dict = obj as? [String: Any] else {
        throw BlobStore.DictionaryEncodingError.corrupted
    }
    return dict
}

// MARK: - JSON path

private func _jsonEncode(_ dict: [String: Any]) throws -> Data {
    // Reuse the SDK's own float-sanitising serialiser (Double → NSDecimalNumber).
    guard let data = jsonData(dict) else {
        throw BlobStore.DictionaryEncodingError.unserialisable
    }
    return data
}

private func _jsonDecode(_ data: Data) throws -> [String: Any] {
    let obj = try JSONSerialization.jsonObject(with: data)
    guard let dict = obj as? [String: Any] else {
        throw BlobStore.DictionaryEncodingError.corrupted
    }
    return dict
}

// MARK: - Binary path
//
// Format — all integers little-endian:
//
//   dict  ::= count:u32  pair*count
//   pair  ::= keyLen:u16  keyBytes  value
//   value ::= tag:u8  payload
//
//   tag  payload
//   0x00  —           null
//   0x01  —           Bool false
//   0x02  —           Bool true
//   0x03  i64:8       Int64
//   0x04  u64:8       Double (bit pattern)
//   0x05  len:u32 bytes  String (UTF-8)
//   0x06  dict        nested [String: Any]
//   0x07  count:u32 value*count  [Any]
//   0x08  len:u32 bytes  Data

private enum BinTag: UInt8 {
    case null   = 0x00
    case bFalse = 0x01
    case bTrue  = 0x02
    case int64  = 0x03
    case double = 0x04
    case string = 0x05
    case dict   = 0x06
    case array  = 0x07
    case data   = 0x08
}

// MARK: Encoder

private func _binEncode(_ dict: [String: Any]) throws -> Data {
    var out = Data()
    try _encodeDict(dict, into: &out)
    return out
}

private func _encodeDict(_ dict: [String: Any], into out: inout Data) throws {
    _appendLE(UInt32(dict.count), to: &out)
    for (key, value) in dict {
        let keyBytes = Data(key.utf8)
        guard keyBytes.count <= UInt16.max else {
            throw BlobStore.DictionaryEncodingError.keyTooLong
        }
        _appendLE(UInt16(keyBytes.count), to: &out)
        out.append(keyBytes)
        try _encodeValue(value, into: &out)
    }
}

private func _encodeValue(_ value: Any, into out: inout Data) throws {
    switch value {
    case is NSNull:
        out.append(BinTag.null.rawValue)

    case let b as Bool:
        out.append(b ? BinTag.bTrue.rawValue : BinTag.bFalse.rawValue)

    // NSDecimalNumber must be matched before Double (it is a subclass of NSNumber).
    case let n as NSDecimalNumber:
        out.append(BinTag.double.rawValue)
        _appendLE(n.doubleValue.bitPattern, to: &out)

    case let n as Double:
        out.append(BinTag.double.rawValue)
        _appendLE(n.bitPattern, to: &out)

    case let n as Float:
        out.append(BinTag.double.rawValue)
        _appendLE(Double(n).bitPattern, to: &out)

    case let n as Int:
        out.append(BinTag.int64.rawValue)
        _appendLE(Int64(n), to: &out)

    case let n as Int64:
        out.append(BinTag.int64.rawValue)
        _appendLE(n, to: &out)

    case let n as Int32:
        out.append(BinTag.int64.rawValue)
        _appendLE(Int64(n), to: &out)

    case let s as String:
        let bytes = Data(s.utf8)
        out.append(BinTag.string.rawValue)
        _appendLE(UInt32(bytes.count), to: &out)
        out.append(bytes)

    case let d as [String: Any]:
        out.append(BinTag.dict.rawValue)
        try _encodeDict(d, into: &out)

    case let a as [Any]:
        out.append(BinTag.array.rawValue)
        _appendLE(UInt32(a.count), to: &out)
        for elem in a { try _encodeValue(elem, into: &out) }

    case let bytes as Data:
        out.append(BinTag.data.rawValue)
        _appendLE(UInt32(bytes.count), to: &out)
        out.append(bytes)

    default:
        // Best-effort fallback: serialise as a string description.
        let bytes = Data(String(describing: value).utf8)
        out.append(BinTag.string.rawValue)
        _appendLE(UInt32(bytes.count), to: &out)
        out.append(bytes)
    }
}

// MARK: Decoder
//
// Single withUnsafeBytes pass: enter the buffer once, pass a raw base pointer
// and an Int offset through every recursive call. No Data.Index arithmetic,
// no slice creation per field — just pointer addition and memcpy.

private func _binDecode(_ data: Data) throws -> [String: Any] {
    try data.withUnsafeBytes { raw in
        guard let base = raw.baseAddress, raw.count > 0 else {
            throw BlobStore.DictionaryEncodingError.corrupted
        }
        var offset = 0
        return try _fastDecodeDict(base: base, end: raw.count, offset: &offset)
    }
}

private func _fastDecodeDict(base: UnsafeRawPointer,
                             end: Int,
                             offset: inout Int) throws -> [String: Any] {
    let count = Int(try _fastReadLE(UInt32.self, base: base, end: end, offset: &offset))
    var dict: [String: Any] = Dictionary(minimumCapacity: count)
    for _ in 0 ..< count {
        let keyLen = Int(try _fastReadLE(UInt16.self, base: base, end: end, offset: &offset))
        guard keyLen >= 0, offset + keyLen <= end else {
            throw BlobStore.DictionaryEncodingError.corrupted
        }
        // String(bytes:encoding:) copies the UTF-8 span — safe after withUnsafeBytes returns.
        let keyPtr = UnsafeBufferPointer(
            start: base.advanced(by: offset).assumingMemoryBound(to: UInt8.self),
            count: keyLen)
        guard let key = String(bytes: keyPtr, encoding: .utf8) else {
            throw BlobStore.DictionaryEncodingError.corrupted
        }
        offset += keyLen
        dict[key] = try _fastDecodeValue(base: base, end: end, offset: &offset)
    }
    return dict
}

private func _fastDecodeValue(base: UnsafeRawPointer,
                              end: Int,
                              offset: inout Int) throws -> Any {
    guard offset < end else { throw BlobStore.DictionaryEncodingError.corrupted }
    let tagByte = base.load(fromByteOffset: offset, as: UInt8.self)
    offset += 1
    guard let tag = BinTag(rawValue: tagByte) else {
        throw BlobStore.DictionaryEncodingError.corrupted
    }
    switch tag {
    case .null:   return NSNull()
    case .bFalse: return false
    case .bTrue:  return true

    case .int64:
        return Int(try _fastReadLE(Int64.self, base: base, end: end, offset: &offset))

    case .double:
        let bits = try _fastReadLE(UInt64.self, base: base, end: end, offset: &offset)
        return Double(bitPattern: bits)

    case .string:
        let len = Int(try _fastReadLE(UInt32.self, base: base, end: end, offset: &offset))
        guard len >= 0, offset + len <= end else {
            throw BlobStore.DictionaryEncodingError.corrupted
        }
        let strPtr = UnsafeBufferPointer(
            start: base.advanced(by: offset).assumingMemoryBound(to: UInt8.self),
            count: len)
        guard let s = String(bytes: strPtr, encoding: .utf8) else {
            throw BlobStore.DictionaryEncodingError.corrupted
        }
        offset += len
        return s

    case .dict:
        return try _fastDecodeDict(base: base, end: end, offset: &offset)

    case .array:
        let count = Int(try _fastReadLE(UInt32.self, base: base, end: end, offset: &offset))
        var array: [Any] = []
        array.reserveCapacity(count)
        for _ in 0 ..< count {
            array.append(try _fastDecodeValue(base: base, end: end, offset: &offset))
        }
        return array

    case .data:
        let len = Int(try _fastReadLE(UInt32.self, base: base, end: end, offset: &offset))
        guard len >= 0, offset + len <= end else {
            throw BlobStore.DictionaryEncodingError.corrupted
        }
        let bytes = Data(bytes: base.advanced(by: offset), count: len)
        offset += len
        return bytes
    }
}

// MARK: - Binary I/O primitives

private func _appendLE<T: FixedWidthInteger>(_ value: T, to out: inout Data) {
    var le = value.littleEndian
    withUnsafeBytes(of: &le) { out.append(contentsOf: $0) }
}

/// Reads a little-endian integer from the raw buffer using memcpy — safe for
/// any alignment. Advances `offset` by the size of `T`.
@inline(__always)
private func _fastReadLE<T: FixedWidthInteger>(_ type: T.Type,
                                               base: UnsafeRawPointer,
                                               end: Int,
                                               offset: inout Int) throws -> T {
    let size = MemoryLayout<T>.size
    guard offset + size <= end else { throw BlobStore.DictionaryEncodingError.corrupted }
    var value: T = 0
    withUnsafeMutableBytes(of: &value) {
        $0.baseAddress!.copyMemory(from: base.advanced(by: offset), byteCount: size)
    }
    offset += size
    return T(littleEndian: value)
}
