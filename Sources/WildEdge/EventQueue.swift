import Foundation

internal final class EventQueue {
    private let maxSize: Int
    private let lock = NSLock()
    private var events: [[String: Any]] = []
    private let fileURL: URL?
    private let fileQueue = DispatchQueue(label: "dev.wildedge.eventqueue.io", qos: .utility)

    init(maxSize: Int, fileURL: URL? = nil) {
        self.maxSize = maxSize
        self.fileURL = fileURL
        if let fileURL {
            let loaded = Self.loadFromDisk(fileURL)
            if loaded.count > maxSize {
                events = Array(loaded.suffix(maxSize))
                Self.rewriteToDisk(events, fileURL)
            } else {
                events = loaded
            }
        }
    }

    func add(_ event: [String: Any]) {
        lock.lock()
        let evicted = events.count >= maxSize
        if evicted {
            events.removeFirst(events.count - maxSize + 1)
        }
        events.append(event)
        let fileOp: (() -> Void)? = fileURL.map { url in
            if evicted {
                let snapshot = self.events
                return { Self.rewriteToDisk(snapshot, url) }
            } else {
                return { Self.appendToDisk(event, url) }
            }
        }
        lock.unlock()

        if let fileOp: () -> Void { fileQueue.async(execute: fileOp) }
    }

    func length() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return events.count
    }

    func peekMany(_ size: Int) -> [[String: Any]] {
        lock.lock()
        defer { lock.unlock() }
        return Array(events.prefix(size))
    }

    func removeFirstN(_ n: Int) {
        lock.lock()
        guard n > 0 else { lock.unlock(); return }
        let count = min(n, events.count)
        events.removeFirst(count)
        let fileOp: (() -> Void)? = fileURL.map { url in
            let snapshot = self.events
            return { Self.rewriteToDisk(snapshot, url) }
        }
        lock.unlock()

        if let fileOp { fileQueue.async(execute: fileOp) }
    }

    func inMemoryBytes() -> Int {
        lock.lock()
        let snapshot = events
        lock.unlock()
        return snapshot.reduce(0) { $0 + Self.dataSize(of: $1) }
    }

    func serialisedSize() -> Int {
        lock.lock()
        let snapshot = events
        lock.unlock()
        return snapshot.reduce(0) { total, event in
            let data = (try? JSONSerialization.data(withJSONObject: event)) ?? Data()
            return total + data.count
        }
    }

    func serialisedSizeWithTiming() -> (bytes: Int, elapsedMs: Double) {
        lock.lock()
        let snapshot = events
        lock.unlock()
        let start = DispatchTime.now()
        let bytes = snapshot.reduce(0) { total, event in
            let data = (try? JSONSerialization.data(withJSONObject: event)) ?? Data()
            return total + data.count
        }
        let end = DispatchTime.now()
        let ns = end.uptimeNanoseconds - start.uptimeNanoseconds
        return (bytes, Double(ns) / 1_000_000)
    }

    // Blocks until all pending background writes have completed.
    internal func waitForPendingWrites() {
        fileQueue.sync {}
    }

    // MARK: - Disk mirror (NDJSON, one JSON object per line)

    private static func loadFromDisk(_ url: URL) -> [[String: Any]] {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else { return [] }
        return text.components(separatedBy: "\n")
            .filter { !$0.isEmpty }
            .compactMap { line in
                guard let d = line.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any]
                else { return nil }
                return obj
            }
    }

    private static func appendToDisk(_ event: [String: Any], _ url: URL) {
        guard let data = try? JSONSerialization.data(withJSONObject: sanitizeForJSON(event)),
              let line = String(data: data, encoding: .utf8) else { return }
        let lineData = Data((line + "\n").utf8)
        if FileManager.default.fileExists(atPath: url.path) {
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            handle.seekToEndOfFile()
            handle.write(lineData)
            try? handle.close()
        } else {
            try? lineData.write(to: url, options: .atomic)
        }
    }

    private static func rewriteToDisk(_ events: [[String: Any]], _ url: URL) {
        let text = events.compactMap { event -> String? in
            guard let data = try? JSONSerialization.data(withJSONObject: sanitizeForJSON(event)),
                  let line = String(data: data, encoding: .utf8) else { return nil }
            return line
        }.joined(separator: "\n")
        let payload = text.isEmpty ? Data() : Data((text + "\n").utf8)
        try? payload.write(to: url, options: .atomic)
    }

    // MARK: - Helpers

    private static func sanitizeForJSON(_ value: Any) -> Any {
        switch value {
        case let dict as [String: Any]:
            return dict.mapValues { sanitizeForJSON($0) }
        case let array as [Any]:
            return array.map { sanitizeForJSON($0) }
        case let v as Double:
            return NSDecimalNumber(string: String(v))
        case let v as Float:
            return NSDecimalNumber(string: String(v))
        default:
            return value
        }
    }

    private static func dataSize(of value: Any) -> Int {
        switch value {
        case let dict as [String: Any]:
            return dict.reduce(0) { $0 + $1.key.utf8.count + dataSize(of: $1.value) }
        case let array as [Any]:
            return array.reduce(0) { $0 + dataSize(of: $1) }
        case let v as String:   return v.utf8.count
        case let v as Bool:     return MemoryLayout.size(ofValue: v)
        case let v as Double:   return MemoryLayout.size(ofValue: v)
        case let v as Float:    return MemoryLayout.size(ofValue: v)
        case let v as Int:      return MemoryLayout.size(ofValue: v)
        case let v as Int64:    return MemoryLayout.size(ofValue: v)
        case let v as Int32:    return MemoryLayout.size(ofValue: v)
        case let v as Int16:    return MemoryLayout.size(ofValue: v)
        case let v as Int8:     return MemoryLayout.size(ofValue: v)
        case let v as UInt64:   return MemoryLayout.size(ofValue: v)
        case let v as UInt32:   return MemoryLayout.size(ofValue: v)
        case let v as UInt16:   return MemoryLayout.size(ofValue: v)
        case let v as UInt8:    return MemoryLayout.size(ofValue: v)
        default:                return 0
        }
    }
}
