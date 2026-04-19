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
}
