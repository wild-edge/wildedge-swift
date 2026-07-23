import Foundation

/// Controls how `.data` payloads are persisted in the attachment queue.
///
/// - `file`: bytes are written to a managed file in Application Support;
///   the BlobStore record holds only the file path. Memory usage during
///   enqueueing is minimal and uploads stream directly from disk.
///
/// - `inline`: bytes are embedded directly in the BlobStore record using
///   the binary TLV encoding. No extra file is written, but the entire
///   payload is loaded into memory during `peekMany`. Best suited for
///   small payloads (thumbnails, short audio clips, embeddings).
///   `.file` payloads always use the file-path path regardless of strategy.
public enum AttachmentStorageStrategy {
    case file
    case inline
}

internal final class AttachmentQueue {
    private let store: BlobStore
    private let strategy: AttachmentStorageStrategy
    private var count: Int = 0
    private var disabled = false
    private let lock = NSLock()

    // Binary encoding is used for all records: it natively supports the
    // Data tag (0x08) needed for inline payloads, and is smaller than JSON.
    private static let encoding = BlobStore.DictionaryEncoding.binary

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    init(fileURL: URL, strategy: AttachmentStorageStrategy = .file) {
        self.strategy = strategy
        var resolved: BlobStore?
        if let s = try? BlobStore(path: fileURL.path, compaction: .rename, threadSafe: false) {
            resolved = s
        } else {
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("we-attachments-\(UUID().uuidString).bin").path
            resolved = try? BlobStore(path: tmp, compaction: .rename, threadSafe: false)
        }
        self.store = resolved!
        self.count = (try? self.store.count()) ?? 0
    }

    // MARK: - Write

    func append(_ attachment: PendingAttachment) {
        lock.lock()
        defer { lock.unlock() }
        guard !disabled else { return }
        guard let dict = encode(attachment) else { return }
        if (try? store.append(dict, encoding: Self.encoding)) != nil {
            count += 1
        }
    }

    /// Stops accepting new attachments for the rest of the session (e.g. after
    /// a presign 403 indicates attachments aren't enabled for this project).
    func disable() {
        lock.lock()
        defer { lock.unlock() }
        disabled = true
    }

    func isDisabled() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return disabled
    }

    // MARK: - Read

    func peekMany(_ size: Int) -> [PendingAttachment] {
        lock.lock()
        defer { lock.unlock() }
        guard size > 0, let reader = try? store.makeReader() else { return [] }
        var result: [PendingAttachment] = []
        result.reserveCapacity(size)
        while result.count < size, let item = try? reader.next() {
            if let dict = try? Self.encoding.decode(item.data),
               let attachment = decode(dict) {
                result.append(attachment)
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

    // MARK: - Diagnostics

    func length() -> Int {
        lock.lock(); defer { lock.unlock() }
        return count
    }

    // MARK: - Encode / Decode

    private func encode(_ a: PendingAttachment) -> [String: Any]? {
        var dict: [String: Any] = [
            "attachment_id":       a.attachmentId,
            "inference_id":        a.inferenceId,
            "name":                a.name,
            "role":                a.role,
            "mime_type":           mimeType(from: a.payload),
            "byte_size":           a.payload.byteSize,
            "inference_timestamp": Self.isoFormatter.string(from: a.inferenceTimestamp),
            "registered_at":       Self.isoFormatter.string(from: a.registeredAt),
        ]

        switch a.payload.source {
        case .data(let bytes, _):
            dict["payload_kind"] = "data"
            dict["payload_data"] = bytes
        case .file(let url, _):
            dict["payload_kind"] = "file"
            dict["file_path"]    = url.path
        }

        return dict
    }

    private func decode(_ dict: [String: Any]) -> PendingAttachment? {
        guard
            let id           = dict["attachment_id"]       as? String,
            let inferenceId  = dict["inference_id"]        as? String,
            let name         = dict["name"]                as? String,
            let role         = dict["role"]                as? String,
            let mimeType     = dict["mime_type"]           as? String,
            let byteSize     = dict["byte_size"]           as? Int,
            let kind         = dict["payload_kind"]        as? String,
            let infTsStr     = dict["inference_timestamp"] as? String,
            let regAtStr     = dict["registered_at"]       as? String,
            let inferenceTs  = Self.isoFormatter.date(from: infTsStr),
            let registeredAt = Self.isoFormatter.date(from: regAtStr)
        else { return nil }

        let source: InferenceAttachment.Payload
        switch kind {
        case "data":
            guard let bytes = dict["payload_data"] as? Data else { return nil }
            source = .data(bytes, mimeType: mimeType)
        case "file":
            guard let path = dict["file_path"] as? String,
                  FileManager.default.fileExists(atPath: path)
            else { return nil }
            source = .file(URL(fileURLWithPath: path), mimeType: mimeType)
        default:
            return nil
        }

        return PendingAttachment(
            attachmentId:       id,
            inferenceId:        inferenceId,
            name:               name,
            role:               role,
            payload:            SizedPayload(source, byteSize: byteSize),
            inferenceTimestamp: inferenceTs,
            registeredAt:       registeredAt
        )
    }

    private func mimeType(from payload: SizedPayload) -> String {
        switch payload.source {
        case .data(_, let m), .file(_, let m): return m
        }
    }
}
