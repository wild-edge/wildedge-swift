import Foundation

internal final class EventQueue {
    private let maxSize: Int
    private let lock = NSLock()
    private var events: [[String: Any]] = []

    init(maxSize: Int) {
        self.maxSize = maxSize
    }

    func add(_ event: [String: Any]) {
        lock.lock()
        defer { lock.unlock() }

        if events.count >= maxSize {
            events.removeFirst(events.count - maxSize + 1)
        }
        events.append(event)
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
        defer { lock.unlock() }

        guard n > 0 else { return }
        let count = min(n, events.count)
        events.removeFirst(count)
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
