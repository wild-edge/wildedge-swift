#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

// MARK: - File format
//
// The store is a flat, append-only sequence of records with no file-level header.
//
// Record layout:
//   bytes  0-15 : uuid_t  — 16-byte UUID (raw, as written by the host)
//   bytes 16-19 : UInt32  — payload length, little-endian
//   bytes  20+  : [UInt8] — payload (arbitrary bytes)
//
// Access model:
//   Tail append  O(1)         — single write(2) per record, serialised by a mutex
//   Head peek    O(1)         — pread(2) at offset 0, serialised by the same mutex
//   Drop first N O(remaining) — two strategies, see CompactionStrategy
//   Sequential   O(n)         — pread(2) per record via BlobReader
//
// MARK: - dropFirst benchmarks (100 MB total, +1 warmup)
//
// All scenarios write a 100 MB file and drop the first half (~50 MB shifted).
// "single" is the fixed-overhead baseline (shift = 0 B).
//
//                                                 inPlace      rename       faster
//   ─────────────────────────────────────────────────────────────────────────────────
//   Apple M4 Pro · macOS 15 · debug
//   1kb     (102k × 1 KB,   shift  51 MB)          57.524 ms    61.810 ms   inPlace
//   10kb    ( 10k × 10 KB,  shift  50 MB)          16.668 ms    36.501 ms   inPlace
//   200kb   ( 512 × 200 KB, shift  50 MB)          11.701 ms    19.300 ms   inPlace
//   1mb     ( 100 × 1 MB,   shift  50 MB)          11.684 ms    20.514 ms   inPlace
//   10mb    (  10 × 10 MB,  shift  50 MB)          13.798 ms    20.327 ms   inPlace
//   single  (   1 × 100 MB, shift   0 B)           35.710 ms     4.701 ms   rename ← flips!
//   ─────────────────────────────────────────────────────────────────────────────────
//   iPhone 13 · A15 · iOS 26 · debug
//   1kb     (102k × 1 KB,   shift  51 MB)          55.600 ms   254.700 ms   inPlace
//   10kb    ( 10k × 10 KB,  shift  50 MB)          22.100 ms   153.800 ms   inPlace
//   200kb   ( 512 × 200 KB, shift  50 MB)          15.200 ms    47.400 ms   inPlace
//   1mb     ( 100 × 1 MB,   shift  50 MB)          15.100 ms    96.000 ms   inPlace
//   10mb    (  10 × 10 MB,  shift  50 MB)          14.300 ms    46.600 ms   inPlace
//   single  (   1 × 100 MB, shift   0 B)            3.100 ms     1.500 ms   rename ← flips!
//   ─────────────────────────────────────────────────────────────────────────────────
//
// inPlace wins whenever there is data to copy — it rewrites in-place and reuses
// page-cache pages loaded during the header scan.
// rename wins only at shift=0: with nothing to copy it pays just open+rename+reopen,
// while inPlace must ftruncate a 100 MB file (expensive inode/extent update in kernel).
// The A15 inPlace times are comparable to M4 Pro for copy-heavy scenarios;
// rename is ~4–7× slower on iPhone because the extra open+write+rename+reopen
// syscalls carry higher per-syscall overhead on iOS XNU than macOS XNU.
//
// MARK: - append benchmarks (100 MB total, +1 warmup)
//
// threadSafe:true (locked) vs threadSafe:false (unlocked) — uncontended path.
//
//                              Total     locked        unlocked      speedup    MB/s
//   ───────────────────────────────────────────────────────────────────────────────────
//   Apple M4 Pro · macOS 15 · debug
//   100b   ( 1M × 100 B)     100 MB   3230.401 ms   3145.159 ms    1.03×       30
//   1kb    (102k × 1 KB)     100 MB    404.959 ms    435.653 ms    0.93×      247
//   10kb   ( 10k × 10 KB)    100 MB     78.674 ms     94.532 ms    0.83×     1270
//   200kb  ( 512 × 200 KB)   100 MB     34.140 ms     26.645 ms    1.28×     2931
//   1mb    ( 100 × 1 MB)     100 MB     18.177 ms     18.521 ms    0.98×     5502
//   100mb  (   1 × 100 MB)   100 MB     62.739 ms     25.849 ms    2.43×     1593
//   ───────────────────────────────────────────────────────────────────────────────────
//   iPhone 13 · A15 · iOS 26 · debug
//   100b   ( 1M × 100 B)     100 MB      3550 ms        3560 ms    1.00×       28
//   1kb    (102k × 1 KB)     100 MB     431.7 ms       429.0 ms    1.01×      232
//   10kb   ( 10k × 10 KB)    100 MB     115.1 ms       115.9 ms    0.99×      869
//   200kb  ( 512 × 200 KB)   100 MB     146.6 ms       139.4 ms    1.05×      682
//   1mb    ( 100 × 1 MB)     100 MB     145.8 ms       138.3 ms    1.05×      686
//   100mb  (   1 × 100 MB)   100 MB     203.2 ms       503.8 ms    0.40×      492
//   ───────────────────────────────────────────────────────────────────────────────────
//
// Lock overhead is immeasurable on both platforms — NSLock (os_unfair_lock) costs
// ~3–5 ns uncontested vs ~1–3 µs per write(2) syscall. All speedup differences
// are within measurement noise; threadSafe:false only helps under real contention.
//
// iPhone vs Mac: syscall-heavy scenarios (100b, 1kb) are nearly identical — A15
// single-core syscall throughput matches M4 Pro. Large-payload scenarios diverge:
// 1mb is ~8× slower on iPhone (686 MB/s vs ~5.5 GB/s) because iOS NAND write
// bandwidth is far lower than the Mac's unified memory/SSD path.

private let _headerSize: Int = 20      // 16 uuid + 4 length

// MARK: - Error

public enum BlobStoreError: Error {
    case openFailed(Int32)
    case writeFailed(Int32)
    case readFailed(Int32)
    case syncFailed(Int32)
    case truncated
}

// MARK: - BlobStore

/// Append-only flat-file blob store backed by POSIX fd I/O.
///
/// - **Append** is serialised with an `NSLock`; concurrent callers are safe.
/// - **Reads** use `pread(2)` (offset-based, does not move the fd position),
///   so concurrent readers never interfere with each other or with the writer.
/// - Random access by record ID is intentionally not supported.
public final class BlobStore {

    /// Controls how `dropFirst(_:)` reclaims space.
    public enum CompactionStrategy {
        /// Shifts remaining bytes to offset 0 with `pwrite(2)` (or
        /// `copy_file_range(2)` on Linux), then calls `ftruncate(2)`.
        /// `writeFd` and `peekFd` keep pointing to the same inode — no reopen.
        /// Not crash-safe: a kill mid-shift leaves the file partially overwritten.
        case inPlace

        /// Writes remaining records to a temp file alongside the store, then
        /// calls `rename(2)` to replace it atomically. `writeFd` and `peekFd`
        /// are reopened after the rename so they point to the new file.
        /// Crash-safe: if the process dies before `rename(2)` the original
        /// file is untouched; a stale `.tmp` sidecar may be left behind.
        case rename
    }

    public struct Item {
        let id: UUID
        let data: Data
    }

    private let storePath: String
    private var writeFd: Int32          // O_WRONLY | O_CREAT | O_APPEND
    private var peekFd:  Int32          // O_RDONLY — dedicated fd for peekHead()
    private let compaction: CompactionStrategy
    private let threadSafe: Bool
    private let storeLock = NSLock()

    // MARK: Lifecycle

    /// - Parameters:
    ///   - threadSafe: When `true` (default) a mutex serialises `append`,
    ///     `peekHead`, and `dropFirst` so concurrent callers are safe.
    ///     Pass `false` when the call site is already serialised externally
    ///     (e.g. a dedicated serial queue) to eliminate the lock round-trip.
    public init(path: String,
         compaction: CompactionStrategy = .inPlace,
         threadSafe: Bool = true) throws {
        let wfd = open(path,
                       O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC,
                       S_IRUSR | S_IWUSR | S_IRGRP)     // 0o640
        guard wfd >= 0 else { throw BlobStoreError.openFailed(errno) }

        let rfd = open(path, O_RDONLY | O_CLOEXEC)
        guard rfd >= 0 else {
            close(wfd)
            throw BlobStoreError.openFailed(errno)
        }

        self.storePath  = path
        self.writeFd    = wfd
        self.peekFd     = rfd
        self.compaction = compaction
        self.threadSafe = threadSafe
    }

    deinit {
        close(writeFd)
        close(peekFd)
    }

    // MARK: - Locking

    @inline(__always)
    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        guard threadSafe else { return try body() }
        storeLock.lock()
        defer { storeLock.unlock() }
        return try body()
    }

    // MARK: - Tail append

    /// Appends `data` as a new record and returns the assigned UUID.
    @discardableResult
    public func append(_ data: Data) throws -> UUID {
        let id = UUID()
        var record = Data(capacity: _headerSize + data.count)

        // 16-byte UUID
        var u = id.uuid
        withUnsafeBytes(of: &u) { record.append(contentsOf: $0) }

        // 4-byte LE length
        var len = UInt32(data.count).littleEndian
        withUnsafeBytes(of: &len) { record.append(contentsOf: $0) }

        record.append(data)

        // Single write(2) with O_APPEND → atomic seek-to-end + write on POSIX.
        // The mutex guards against concurrent partial writes on the same fd
        // for payloads that exceed the kernel's atomic-write limit.
        return try withLock {
            try _posixWrite(writeFd, record)
            return id
        }
    }

    /// Flushes pending kernel write buffers to the storage device.
    func sync() throws {
        guard fsync(writeFd) == 0 else { throw BlobStoreError.syncFailed(errno) }
    }

    // MARK: - Head peek (O(1))

    /// Reads the first record without advancing any cursor.
    /// Serialised via `withLock` when `threadSafe` is true.
    func peekHead() throws -> Item? {
        try withLock { try _readRecord(peekFd, at: 0) }
    }

    // MARK: - Record count (header-only scan)

    /// Counts records by reading only the 20-byte header of each record and
    /// using the stored payload length to skip forward — the payload bytes are
    /// never loaded into memory. O(n) in record count, O(1) in payload size.
    ///
    /// Memory per call: one 20-byte stack buffer regardless of payload sizes.
    func count() throws -> Int {
        let fd = open(storePath, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { throw BlobStoreError.openFailed(errno) }
        defer { close(fd) }

        // One fstat gives us the file size; each record's extent is validated
        // against it so garbage bytes from an incompatible format are rejected.
        var st = stat()
        guard fstat(fd, &st) == 0 else { throw BlobStoreError.readFailed(errno) }
        let fileSize = Int64(st.st_size)

        var header = [UInt8](repeating: 0, count: _headerSize)
        var offset: Int64 = 0
        var n = 0

        while offset < fileSize {
            let nr = try _posixPread(fd, into: &header, count: _headerSize, at: offset)
            if nr == 0 { break }                          // clean EOF
            guard nr == _headerSize else { break }        // truncated header — stop

            // Bytes 16-19: payload length (LE UInt32)
            var rawLen: UInt32 = 0
            withUnsafeMutableBytes(of: &rawLen) { dst in
                header.withUnsafeBytes { src in
                    dst.copyMemory(from: UnsafeRawBufferPointer(
                        start: src.baseAddress!.advanced(by: 16), count: 4))
                }
            }
            let payloadLen = Int64(UInt32(littleEndian: rawLen))
            let nextOffset = offset + Int64(_headerSize) + payloadLen

            // Reject the record if its payload would extend beyond the file —
            // this catches garbage headers from incompatible formats.
            guard nextOffset <= fileSize else { break }

            // Jump directly to the next record header — payload never touched.
            offset = nextOffset
            n += 1
        }
        return n
    }

    // MARK: - Drop first N (O(remaining))

    /// Removes the first `n` records from the store using the strategy
    /// supplied at initialisation. Holds `storeLock` for the full duration;
    /// concurrent `append()` and `peekHead()` block until compaction finishes.
    /// `BlobReader` instances may receive `.truncated` if they straddle the
    /// compaction window.
    public func dropFirst(_ n: Int) throws {
        guard n > 0 else { return }

        try withLock {

        // Scan first n record headers to locate the drop boundary.
        let srcFd = open(storePath, O_RDONLY | O_CLOEXEC)
        guard srcFd >= 0 else { throw BlobStoreError.openFailed(errno) }
        defer { close(srcFd) }

        var dropOffset: Int64 = 0
        var dropped = 0
        while dropped < n {
            var header = [UInt8](repeating: 0, count: _headerSize)
            let nr = try _posixPread(srcFd, into: &header, count: _headerSize, at: dropOffset)
            if nr == 0 { break }                        // EOF: fewer than n records
            guard nr == _headerSize else { throw BlobStoreError.truncated }

            var rawLen: UInt32 = 0
            withUnsafeMutableBytes(of: &rawLen) { dst in
                header.withUnsafeBytes { src in
                    dst.copyMemory(from: UnsafeRawBufferPointer(
                        start: src.baseAddress!.advanced(by: 16), count: 4))
                }
            }
            dropOffset += Int64(_headerSize) + Int64(UInt32(littleEndian: rawLen))
            dropped += 1
        }

        guard dropped > 0 else { return }

        var st = stat()
        guard fstat(srcFd, &st) == 0 else { throw BlobStoreError.readFailed(errno) }
        let fileSize  = Int64(st.st_size)
        let remaining = max(0, fileSize - dropOffset)

        switch compaction {
        case .inPlace: try _compactInPlace(srcFd: srcFd, dropOffset: dropOffset, remaining: remaining)
        case .rename:  try _compactRename(srcFd: srcFd, dropOffset: dropOffset, remaining: remaining)
        }
        }   // withLock
    }

    // MARK: Compaction — in-place

    /// Shifts remaining bytes to offset 0 on an `O_RDWR` fd, then truncates.
    /// `writeFd` and `peekFd` keep pointing to the same inode — no reopen.
    private func _compactInPlace(srcFd: Int32, dropOffset: Int64, remaining: Int64) throws {
        let rwFd = open(storePath, O_RDWR | O_CLOEXEC)
        guard rwFd >= 0 else { throw BlobStoreError.openFailed(errno) }
        defer { close(rwFd) }

        // srcFd reads from dropOffset+; rwFd writes from 0.
        // Source is always ahead of destination — no overlap.
        try _copyBytes(from: srcFd, srcOff: dropOffset, to: rwFd, dstOff: 0, count: remaining)

        guard ftruncate(rwFd, off_t(remaining)) == 0 else {
            throw BlobStoreError.writeFailed(errno)
        }
    }

    // MARK: Compaction — rename

    /// Writes remaining bytes to a `.tmp` sidecar, renames it over the store
    /// atomically, then reopens `writeFd` and `peekFd` to the new file.
    private func _compactRename(srcFd: Int32, dropOffset: Int64, remaining: Int64) throws {
        let tmpPath = storePath + ".tmp"

        let tmpFd = open(tmpPath, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC,
                         S_IRUSR | S_IWUSR | S_IRGRP)
        guard tmpFd >= 0 else { throw BlobStoreError.openFailed(errno) }

        do {
            try _copyBytes(from: srcFd, srcOff: dropOffset, to: tmpFd, dstOff: 0, count: remaining)
        } catch {
            close(tmpFd); unlink(tmpPath); throw error
        }
        close(tmpFd)

        guard rename(tmpPath, storePath) == 0 else {
            let e = errno; unlink(tmpPath); throw BlobStoreError.writeFailed(e)
        }

        // writeFd and peekFd now reference the unlinked old file — reopen both.
        let newWfd = open(storePath, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC,
                          S_IRUSR | S_IWUSR | S_IRGRP)
        close(writeFd)
        writeFd = newWfd
        guard writeFd >= 0 else { throw BlobStoreError.openFailed(errno) }

        let newPfd = open(storePath, O_RDONLY | O_CLOEXEC)
        close(peekFd)
        peekFd = newPfd
        guard peekFd >= 0 else { throw BlobStoreError.openFailed(errno) }
    }

    // MARK: - Sequential reader

    /// Creates an independent forward-only reader starting at the first record.
    /// Each reader owns its own file descriptor.
    func makeReader() throws -> BlobReader {
        let fd = open(storePath, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { throw BlobStoreError.openFailed(errno) }
        return BlobReader(fd: fd)
    }
}

// MARK: - BlobReader

/// Stateful forward-only cursor over a BlobStore file.
///
/// The reader maintains its own `offset`; calling `next()` never affects
/// the store or any other reader. Create via `BlobStore.makeReader()`.
internal final class BlobReader {

    private let fd: Int32
    private(set) var offset: Int64 = 0

    fileprivate init(fd: Int32) { self.fd = fd }

    deinit { close(fd) }

    /// Returns the next record and advances the cursor, or `nil` at EOF.
    func next() throws -> BlobStore.Item? {
        guard let item = try _readRecord(fd, at: offset) else { return nil }
        offset += Int64(_headerSize) + Int64(item.data.count)
        return item
    }

    /// Resets the cursor to the beginning of the file.
    func reset() { offset = 0 }
}

// MARK: - File-private POSIX helpers

/// Reads one record from `fd` starting at byte `offset`.
/// Uses `pread(2)` — does not move the fd's internal position.
private func _readRecord(_ fd: Int32, at offset: Int64) throws -> BlobStore.Item? {
    // ── Header ──────────────────────────────────────────────────────────────
    var header = [UInt8](repeating: 0, count: _headerSize)
    let headerRead = try _posixPread(fd, into: &header, count: _headerSize, at: offset)
    if headerRead == 0 { return nil }                   // clean EOF
    guard headerRead == _headerSize else { throw BlobStoreError.truncated }

    // Bytes 0-15: UUID
    let uuid = UUID(uuid: (
        header[0],  header[1],  header[2],  header[3],
        header[4],  header[5],  header[6],  header[7],
        header[8],  header[9],  header[10], header[11],
        header[12], header[13], header[14], header[15]
    ))

    // Bytes 16-19: payload length (LE UInt32); copy via memcpy to avoid
    // alignment faults on strict-alignment architectures.
    var rawLen: UInt32 = 0
    withUnsafeMutableBytes(of: &rawLen) { dst in
        header.withUnsafeBytes { src in
            dst.copyMemory(from: UnsafeRawBufferPointer(
                start: src.baseAddress!.advanced(by: 16), count: 4))
        }
    }
    let payloadLen = Int(UInt32(littleEndian: rawLen))

    if payloadLen == 0 { return BlobStore.Item(id: uuid, data: Data()) }

    // ── Payload ──────────────────────────────────────────────────────────────
    var payload = [UInt8](repeating: 0, count: payloadLen)
    let payloadRead = try _posixPread(fd, into: &payload, count: payloadLen,
                                     at: offset + Int64(_headerSize))
    guard payloadRead == payloadLen else { throw BlobStoreError.truncated }

    return BlobStore.Item(id: uuid, data: Data(payload))
}

/// Reads exactly `count` bytes from `fd` at `offset` using `pread(2)`.
/// Returns the number of bytes actually read (< count only at EOF).
/// Retries automatically on `EINTR`.
private func _posixPread(_ fd: Int32, into buf: inout [UInt8],
                         count: Int, at offset: Int64) throws -> Int {
    var total = 0
    while total < count {
        let n = buf.withUnsafeMutableBytes { ptr in
            pread(fd,
                  ptr.baseAddress!.advanced(by: total),
                  count - total,
                  off_t(offset) + off_t(total))
        }
        if n > 0  { total += n; continue }
        if n == 0 { break }                             // EOF
        if errno == EINTR { continue }
        throw BlobStoreError.readFailed(errno)
    }
    return total
}

/// Copies `count` bytes from `srcFd` at `srcOff` to `dstFd` at `dstOff`.
///
/// On Linux uses `copy_file_range(2)`: data moves between fds inside the
/// kernel, no user-space buffer is allocated and no CPU copy occurs.
/// On Darwin falls back to `pread(2)` + `pwrite(2)` in 64 KB chunks.
private func _copyBytes(from srcFd: Int32, srcOff: Int64,
                        to dstFd: Int32,   dstOff: Int64,
                        count: Int64) throws {
    guard count > 0 else { return }
#if canImport(Glibc)
    // copy_file_range keeps data in the kernel page cache — no user buffer.
    var src = off_t(srcOff)
    var dst = off_t(dstOff)
    var remaining = count
    while remaining > 0 {
        let n = copy_file_range(srcFd, &src, dstFd, &dst, Int(remaining), 0)
        if n > 0  { remaining -= Int64(n); continue }
        if n == 0 { break }               // unexpected EOF
        if errno == EINTR { continue }
        throw BlobStoreError.writeFailed(errno)
    }
#else
    var buf = [UInt8](repeating: 0, count: min(Int(count), 65536))
    var done: Int64 = 0
    while done < count {
        let toRead = min(buf.count, Int(count - done))
        let nr = try _posixPread(srcFd, into: &buf, count: toRead, at: srcOff + done)
        if nr == 0 { break }
        try buf.withUnsafeBytes { ptr in
            try _posixPwrite(dstFd, from: ptr.baseAddress!, count: nr, at: dstOff + done)
        }
        done += Int64(nr)
    }
#endif
}

/// Writes `count` bytes at `offset` in `fd` using `pwrite(2)`, retrying on `EINTR`.
/// Unlike `write(2)`, `pwrite(2)` ignores `O_APPEND` and writes at the given offset.
private func _posixPwrite(_ fd: Int32, from base: UnsafeRawPointer,
                          count: Int, at offset: Int64) throws {
    var written = 0
    while written < count {
        let n = pwrite(fd, base.advanced(by: written),
                       count - written,
                       off_t(offset) + off_t(written))
        if n > 0  { written += n; continue }
        if errno == EINTR { continue }
        throw BlobStoreError.writeFailed(errno)
    }
}

/// Writes all bytes of `data` to `fd` using `write(2)`, retrying on `EINTR`
/// and short writes (the fd is opened with `O_APPEND`).
private func _posixWrite(_ fd: Int32, _ data: Data) throws {
    var written = 0
    let count = data.count
    try data.withUnsafeBytes { buf in
        let base = buf.baseAddress!
        while written < count {
            let n = write(fd, base.advanced(by: written), count - written)
            if n > 0  { written += n; continue }
            if errno == EINTR { continue }
            throw BlobStoreError.writeFailed(errno)
        }
    }
}
