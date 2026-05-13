import Foundation

// MARK: - EventQueue (BlobStore-backed)
//
// Replaces the former in-memory [[String: Any]] array + NDJSON disk mirror with
// a BlobStore that writes events directly to disk as JSON-encoded records.
//
// Trade-offs vs the previous design:
//   + No double-buffering: events live on disk only, not also in a heap array.
//   + O(1) append via write(2) with O_APPEND — no FileHandle open/close per event.
//   + Crash-safe removal via BlobStore(.rename) — dropFirst uses temp+rename.
//   - peekMany and removeFirstN now involve disk I/O under the lock (previously
//     in-memory reads; disk writes were async). Both are fast in practice because
//     recent writes stay in the kernel page cache.

internal final class EventQueue {
    private let maxSize: Int
    private let store:   BlobStore
    private var count:   Int = 0
    private let lock  =  NSLock()

    // Non-nil when we own a temp file (fileURL == nil on init) and should clean it up.
    private let ownedTempPath: String?

    // MARK: Init / deinit

    init(maxSize: Int, fileURL: URL? = nil) {
        self.maxSize = maxSize

        // Resolve the BlobStore path; fall back to a temp path if fileURL is nil
        // or if opening the requested path fails.
        var resolvedStore:    BlobStore?
        var resolvedTempPath: String? = nil
        var resolvedPath:     String  = ""

        if let fileURL {
            resolvedPath  = fileURL.path
            resolvedStore = try? BlobStore(path: resolvedPath,
                                           compaction: .rename,
                                           threadSafe: false)   // lock is external
        }

        if resolvedStore == nil {
            let tmp      = FileManager.default.temporaryDirectory
                .appendingPathComponent("we-queue-\(UUID().uuidString).bin").path
            resolvedPath     = tmp
            resolvedTempPath = tmp
            resolvedStore    = try? BlobStore(path: tmp, compaction: .rename, threadSafe: false)
        }

        self.store         = resolvedStore!     // temp path open must succeed
        self.ownedTempPath = resolvedTempPath

        // Count records that survived from a previous session — header-only scan,
        // payload bytes are never loaded into memory.
        let n = (try? self.store.count()) ?? 0

        if n > maxSize {
            try? self.store.dropFirst(n - maxSize)
            self.count = maxSize
        } else {
            self.count = n
        }

        // If count is 0 but the file has content (e.g. a leftover NDJSON file
        // from an older SDK version, or bytes written by a non-BlobStore path),
        // truncate via a separate fd so subsequent appends start at offset 0.
        // This preserves BlobStore's existing open fds — they reference the same
        // inode, which is now 0 bytes; the next O_APPEND write lands at offset 0.
        if n == 0 && !resolvedPath.isEmpty {
            let fd = open(resolvedPath, O_WRONLY | O_CLOEXEC)
            if fd >= 0 { _ = ftruncate(fd, 0); close(fd) }
        }
    }

    deinit {
        if let path = ownedTempPath {
            try? FileManager.default.removeItem(atPath: path)
            try? FileManager.default.removeItem(atPath: path + ".tmp")
        }
    }

    // MARK: - Write

    func add(_ event: [String: Any]) {
        lock.lock()
        defer { lock.unlock() }

        if count >= maxSize {
            try? store.dropFirst(1)
            count = max(0, count - 1)
        }
        if (try? store.append(event, encoding: .json)) != nil {
            count += 1
        }
    }

    // MARK: - Read

    func length() -> Int {
        lock.lock(); defer { lock.unlock() }
        return count
    }

    /// Returns up to `size` events from the head without removing them.
    func peekMany(_ size: Int) -> [[String: Any]] {
        lock.lock()
        defer { lock.unlock() }
        guard size > 0, let reader = try? store.makeReader() else { return [] }
        var result: [[String: Any]] = []
        result.reserveCapacity(size)
        while result.count < size, let item = try? reader.next() {
            if let dict = try? BlobStore.DictionaryEncoding.json.decode(item.data) {
                result.append(dict)
            }
        }
        return result
    }

    // MARK: - Remove

    func removeFirstN(_ n: Int) {
        lock.lock()
        defer { lock.unlock() }
        let drop = min(n, count)
        guard drop > 0 else { return }
        try? store.dropFirst(drop)
        count = max(0, count - drop)
    }
}
