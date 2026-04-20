import Foundation
import WildEdge

enum ModelDownloader {
    static func downloadIfNeeded(
        handle: ModelHandle,
        sourceURL: URL,
        destinationURL: URL
    ) async throws -> Bool {
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            return true
        }

        let start = Date()
        var downloaded: Int64 = 0
        var totalSize: Int64 = 0

        do {
            let (data, response) = try await URLSession.shared.data(from: sourceURL)
            totalSize = response.expectedContentLength > 0 ? response.expectedContentLength : Int64(data.count)
            downloaded = Int64(data.count)

            let parent = destinationURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            try data.write(to: destinationURL, options: .atomic)

            handle.trackDownload(
                sourceUrl: sourceURL.absoluteString,
                sourceType: sourceURL.scheme ?? "https",
                fileSizeBytes: totalSize,
                downloadedBytes: downloaded,
                durationMs: Int(Date().timeIntervalSince(start) * 1000),
                networkType: "unknown",
                resumed: false,
                cacheHit: false,
                success: true
            )

            return true
        } catch {
            try? FileManager.default.removeItem(at: destinationURL)
            handle.trackDownload(
                sourceUrl: sourceURL.absoluteString,
                sourceType: sourceURL.scheme ?? "https",
                fileSizeBytes: totalSize,
                downloadedBytes: downloaded,
                durationMs: Int(Date().timeIntervalSince(start) * 1000),
                networkType: "unknown",
                resumed: false,
                cacheHit: false,
                success: false,
                errorCode: String(describing: type(of: error))
            )
            return false
        }
    }
}
