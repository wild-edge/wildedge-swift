import Foundation
import WhisperKit

enum ModelAssetPhase: String, Sendable {
    case checking
    case cached
    case downloading
    case loading
    case blocked
}

struct ModelAssetDownloadProgress: Sendable {
    let phase: ModelAssetPhase
    let progress: Double?
    let speedBytesPerSecond: Int64
    let receivedBytes: Int64
    let expectedBytes: Int64?
}

struct ModelAssetStatus: Sendable {
    enum State: String, Sendable {
        case missing
        case partial
        case cached
        case blocked
    }

    let state: State
    let localURL: URL?
    let partialURL: URL?
    let bytes: Int64
    let message: String?

    var isCached: Bool {
        state == .cached
    }
}

enum VoiceRecorderModelAsset: Sendable {
    case gguf(BenchmarkTextToToolModel)
    case ggufProjector(BenchmarkTextToToolModel)
    case whisper(WhisperModelSize)
    case leapAudio(modelName: String, quantization: String)
}

actor VoiceRecorderModelManager {
    static let shared = VoiceRecorderModelManager()

    private let fileManager: FileManager
    private let urlSession: URLSession
    private let jsonEncoder: JSONEncoder

    init(
        fileManager: FileManager = .default,
        urlSession: URLSession = .shared
    ) {
        self.fileManager = fileManager
        self.urlSession = urlSession
        self.jsonEncoder = JSONEncoder()
        self.jsonEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    func status(for asset: VoiceRecorderModelAsset) async -> ModelAssetStatus {
        do {
            switch asset {
            case .gguf(let model):
                return try ggufStatus(for: model)
            case .ggufProjector(let model):
                return try ggufProjectorStatus(for: model)
            case .whisper(let model):
                return try whisperStatus(for: model)
            case .leapAudio(let modelName, let quantization):
                return try leapStatus(modelName: modelName, quantization: quantization)
            }
        } catch {
            return ModelAssetStatus(
                state: .missing,
                localURL: nil,
                partialURL: nil,
                bytes: 0,
                message: error.localizedDescription
            )
        }
    }

    func prepare(
        _ asset: VoiceRecorderModelAsset,
        progressHandler: (@Sendable (ModelAssetDownloadProgress) -> Void)? = nil
    ) async throws -> URL? {
        progressHandler?(
            ModelAssetDownloadProgress(
                phase: .checking,
                progress: nil,
                speedBytesPerSecond: 0,
                receivedBytes: 0,
                expectedBytes: nil
            )
        )

        switch asset {
        case .gguf(let model):
            return try await prepareGGUF(model, progressHandler: progressHandler)
        case .ggufProjector(let model):
            return try await prepareGGUFProjector(model, progressHandler: progressHandler)
        case .whisper(let model):
            return try await prepareWhisper(model, progressHandler: progressHandler)
        case .leapAudio(let modelName, let quantization):
            if LeapSpeechTranscriber.isLoadTemporarilyDisabled {
                progressHandler?(
                    ModelAssetDownloadProgress(
                        phase: .blocked,
                        progress: nil,
                        speedBytesPerSecond: 0,
                        receivedBytes: 0,
                        expectedBytes: nil
                    )
                )
                throw SpeechTranscriptionError.transcriptionFailed(LeapSpeechTranscriber.loadDisabledReason)
            }
            return try leapStatus(modelName: modelName, quantization: quantization).localURL
        }
    }

    func localURL(for asset: VoiceRecorderModelAsset) async throws -> URL? {
        switch asset {
        case .gguf(let model):
            let url = try ggufURL(for: model)
            if try validFileExists(at: url) {
                return url
            }
            return try bundledModelFileURL(named: url.lastPathComponent)
        case .ggufProjector(let model):
            let url = try ggufProjectorURL(for: model)
            if try validFileExists(at: url) {
                return url
            }
            return try bundledModelFileURL(named: url.lastPathComponent)
        case .whisper(let model):
            let url = try stableWhisperFolder(for: model)
            return modelFolderExists(at: url) ? url : nil
        case .leapAudio(let modelName, let quantization):
            return try leapStatus(modelName: modelName, quantization: quantization).localURL
        }
    }

    func invalidate(_ asset: VoiceRecorderModelAsset) async {
        do {
            switch asset {
            case .gguf(let model):
                let finalURL = try ggufURL(for: model)
                try? fileManager.removeItem(at: finalURL)
                try? fileManager.removeItem(at: partialGGUFURL(for: model))
                try? fileManager.removeItem(at: manifestURL(for: model))
            case .ggufProjector(let model):
                let finalURL = try ggufProjectorURL(for: model)
                try? fileManager.removeItem(at: finalURL)
                try? fileManager.removeItem(at: partialGGUFProjectorURL(for: model))
                try? fileManager.removeItem(at: ggufProjectorManifestURL(for: model))
            case .whisper(let model):
                try? fileManager.removeItem(at: stableWhisperFolder(for: model))
            case .leapAudio(let modelName, let quantization):
                try? fileManager.removeItem(at: leapFolder(modelName: modelName, quantization: quantization))
            }
        } catch {
            return
        }
    }

    private func prepareGGUF(
        _ model: BenchmarkTextToToolModel,
        progressHandler: (@Sendable (ModelAssetDownloadProgress) -> Void)?
    ) async throws -> URL {
        try await prepareGGUFFile(
            model,
            finalURL: ggufURL(for: model),
            partialURL: partialGGUFURL(for: model),
            manifestURL: manifestURL(for: model),
            downloadURLString: model.downloadURLString,
            progressHandler: progressHandler
        )
    }

    private func prepareGGUFProjector(
        _ model: BenchmarkTextToToolModel,
        progressHandler: (@Sendable (ModelAssetDownloadProgress) -> Void)?
    ) async throws -> URL {
        try await prepareGGUFFile(
            model,
            finalURL: ggufProjectorURL(for: model),
            partialURL: partialGGUFProjectorURL(for: model),
            manifestURL: ggufProjectorManifestURL(for: model),
            downloadURLString: model.mmprojDownloadURLString,
            progressHandler: progressHandler
        )
    }

    private func prepareGGUFFile(
        _ model: BenchmarkTextToToolModel,
        finalURL: URL,
        partialURL: URL,
        manifestURL: URL,
        downloadURLString: String?,
        progressHandler: (@Sendable (ModelAssetDownloadProgress) -> Void)?
    ) async throws -> URL {
        if try validFileExists(at: finalURL) {
            progressHandler?(
                ModelAssetDownloadProgress(
                    phase: .cached,
                    progress: 1,
                    speedBytesPerSecond: 0,
                    receivedBytes: try fileSize(at: finalURL),
                    expectedBytes: try fileSize(at: finalURL)
                )
            )
            return finalURL
        }
        if let bundledURL = try bundledModelFileURL(named: finalURL.lastPathComponent) {
            progressHandler?(
                ModelAssetDownloadProgress(
                    phase: .cached,
                    progress: 1,
                    speedBytesPerSecond: 0,
                    receivedBytes: try fileSize(at: bundledURL),
                    expectedBytes: try fileSize(at: bundledURL)
                )
            )
            return bundledURL
        }

        guard let downloadURLString,
              let downloadURL = URL(string: downloadURLString)
        else {
            throw SpeechTranscriptionError.transcriptionFailed(
                "\(model.displayName) does not define a download URL."
            )
        }

        try prepareAppManagedDirectory(finalURL.deletingLastPathComponent())
        let startedAt = Date()
        let finalURLForClosure = finalURL
        let partialURLForClosure = partialURL
        let downloadResult = try await downloadFile(
            sourceURL: downloadURL,
            finalURL: finalURLForClosure,
            partialURL: partialURLForClosure,
            startedAt: startedAt,
            progressHandler: progressHandler
        )
        try writeManifest(
            GGUFModelManifest(
                modelId: model.modelId,
                displayName: model.displayName,
                sourceURL: downloadURLString,
                fileName: finalURL.lastPathComponent,
                expectedBytes: downloadResult.expectedBytes,
                finalBytes: downloadResult.finalBytes,
                completedAt: Date()
            ),
            at: manifestURL
        )
        return finalURL
    }

    private func prepareWhisper(
        _ model: WhisperModelSize,
        progressHandler: (@Sendable (ModelAssetDownloadProgress) -> Void)?
    ) async throws -> URL {
        let stableFolder = try stableWhisperFolder(for: model)
        if modelFolderExists(at: stableFolder) {
            progressHandler?(
                ModelAssetDownloadProgress(
                    phase: .cached,
                    progress: 1,
                    speedBytesPerSecond: 0,
                    receivedBytes: folderSize(at: stableFolder),
                    expectedBytes: folderSize(at: stableFolder)
                )
            )
            return stableFolder
        }

        try prepareAppManagedDirectory(stableFolder.deletingLastPathComponent())
        if let discoveredFolder = try discoverExistingWhisperFolder(for: model) {
            try installWhisperFolder(discoveredFolder, at: stableFolder)
            progressHandler?(
                ModelAssetDownloadProgress(
                    phase: .cached,
                    progress: 1,
                    speedBytesPerSecond: 0,
                    receivedBytes: folderSize(at: stableFolder),
                    expectedBytes: folderSize(at: stableFolder)
                )
            )
            return stableFolder
        }

        let downloadBase = try whisperDownloadCacheRoot()
        try prepareAppManagedDirectory(downloadBase)
        let downloadedFolder = try await WhisperKit.download(
            variant: model.whisperKitModelName,
            downloadBase: downloadBase,
            progressCallback: { progress in
                let normalizedProgress = Self.normalizedProgress(progress)
                let speed = Self.progressSpeed(progress)
                progressHandler?(
                    ModelAssetDownloadProgress(
                        phase: .downloading,
                        progress: normalizedProgress,
                        speedBytesPerSecond: speed,
                        receivedBytes: 0,
                        expectedBytes: nil
                    )
                )
            }
        )
        try installWhisperFolder(downloadedFolder, at: stableFolder)
        progressHandler?(
            ModelAssetDownloadProgress(
                phase: .cached,
                progress: 1,
                speedBytesPerSecond: 0,
                receivedBytes: folderSize(at: stableFolder),
                expectedBytes: folderSize(at: stableFolder)
            )
        )
        return stableFolder
    }

    private func downloadFile(
        sourceURL: URL,
        finalURL: URL,
        partialURL: URL,
        startedAt: Date,
        progressHandler: (@Sendable (ModelAssetDownloadProgress) -> Void)?
    ) async throws -> GGUFDownloadResult {
        let existingPartialBytes = (try? fileSize(at: partialURL)) ?? 0
        var request = URLRequest(url: sourceURL)
        if existingPartialBytes > 0 {
            request.setValue("bytes=\(existingPartialBytes)-", forHTTPHeaderField: "Range")
        }

        let (bytes, response) = try await urlSession.bytes(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SpeechTranscriptionError.transcriptionFailed("Model download returned an invalid response.")
        }

        let shouldAppend: Bool
        switch httpResponse.statusCode {
        case 200..<300:
            shouldAppend = httpResponse.statusCode == 206 && existingPartialBytes > 0
        case 416 where existingPartialBytes > 0:
            try fileManager.removeItem(at: partialURL)
            return try await downloadFile(
                sourceURL: sourceURL,
                finalURL: finalURL,
                partialURL: partialURL,
                startedAt: Date(),
                progressHandler: progressHandler
            )
        default:
            throw SpeechTranscriptionError.transcriptionFailed(
                "Model download failed with HTTP \(httpResponse.statusCode)."
            )
        }

        if shouldAppend == false, fileManager.fileExists(atPath: partialURL.path) {
            try fileManager.removeItem(at: partialURL)
        }
        if fileManager.fileExists(atPath: partialURL.path) == false {
            fileManager.createFile(atPath: partialURL.path, contents: nil)
        }

        let expectedBytes = expectedByteCount(
            response: response,
            existingPartialBytes: shouldAppend ? existingPartialBytes : 0
        )
        var receivedBytes = shouldAppend ? existingPartialBytes : 0
        let handle = try FileHandle(forWritingTo: partialURL)
        do {
            if shouldAppend {
                _ = try handle.seekToEnd()
            }

            var chunk: [UInt8] = []
            chunk.reserveCapacity(64 * 1024)
            for try await byte in bytes {
                chunk.append(byte)
                if chunk.count >= 64 * 1024 {
                    try handle.write(contentsOf: chunk)
                    receivedBytes += Int64(chunk.count)
                    chunk.removeAll(keepingCapacity: true)
                    reportDownloadProgress(
                        receivedBytes: receivedBytes,
                        expectedBytes: expectedBytes,
                        startedAt: startedAt,
                        progressHandler: progressHandler
                    )
                }
            }

            if chunk.isEmpty == false {
                try handle.write(contentsOf: chunk)
                receivedBytes += Int64(chunk.count)
                reportDownloadProgress(
                    receivedBytes: receivedBytes,
                    expectedBytes: expectedBytes,
                    startedAt: startedAt,
                    progressHandler: progressHandler
                )
            }
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }

        if fileManager.fileExists(atPath: finalURL.path) {
            try fileManager.removeItem(at: finalURL)
        }
        try fileManager.moveItem(at: partialURL, to: finalURL)
        let finalBytes = try fileSize(at: finalURL)
        progressHandler?(
            ModelAssetDownloadProgress(
                phase: .downloading,
                progress: 1,
                speedBytesPerSecond: 0,
                receivedBytes: finalBytes,
                expectedBytes: expectedBytes
            )
        )
        return GGUFDownloadResult(expectedBytes: expectedBytes, finalBytes: finalBytes)
    }

    private func ggufStatus(for model: BenchmarkTextToToolModel) throws -> ModelAssetStatus {
        let finalURL = try ggufURL(for: model)
        return try fileStatus(finalURL: finalURL, partialURL: partialGGUFURL(for: model))
    }

    private func ggufProjectorStatus(for model: BenchmarkTextToToolModel) throws -> ModelAssetStatus {
        let finalURL = try ggufProjectorURL(for: model)
        return try fileStatus(finalURL: finalURL, partialURL: partialGGUFProjectorURL(for: model))
    }

    private func fileStatus(finalURL: URL, partialURL: URL) throws -> ModelAssetStatus {
        if try validFileExists(at: finalURL) {
            return ModelAssetStatus(
                state: .cached,
                localURL: finalURL,
                partialURL: nil,
                bytes: try fileSize(at: finalURL),
                message: nil
            )
        }
        if let bundledURL = try bundledModelFileURL(named: finalURL.lastPathComponent) {
            return ModelAssetStatus(
                state: .cached,
                localURL: bundledURL,
                partialURL: nil,
                bytes: try fileSize(at: bundledURL),
                message: nil
            )
        }
        if try validFileExists(at: partialURL) {
            return ModelAssetStatus(
                state: .partial,
                localURL: nil,
                partialURL: partialURL,
                bytes: try fileSize(at: partialURL),
                message: nil
            )
        }
        return ModelAssetStatus(
            state: .missing,
            localURL: nil,
            partialURL: nil,
            bytes: 0,
            message: nil
        )
    }

    private func whisperStatus(for model: WhisperModelSize) throws -> ModelAssetStatus {
        let folder = try stableWhisperFolder(for: model)
        guard modelFolderExists(at: folder) else {
            return ModelAssetStatus(
                state: .missing,
                localURL: nil,
                partialURL: nil,
                bytes: 0,
                message: nil
            )
        }
        return ModelAssetStatus(
            state: .cached,
            localURL: folder,
            partialURL: nil,
            bytes: folderSize(at: folder),
            message: nil
        )
    }

    private func leapStatus(modelName: String, quantization: String) throws -> ModelAssetStatus {
        let folder = try leapFolder(modelName: modelName, quantization: quantization)
        let size = folderSize(at: folder)
        let disabledMessage = LeapSpeechTranscriber.isLoadTemporarilyDisabled
            ? LeapSpeechTranscriber.loadDisabledReason
            : nil
        if modelFolderExists(at: folder) {
            return ModelAssetStatus(
                state: LeapSpeechTranscriber.isLoadTemporarilyDisabled ? .blocked : .cached,
                localURL: folder,
                partialURL: nil,
                bytes: size,
                message: disabledMessage
            )
        }
        return ModelAssetStatus(
            state: LeapSpeechTranscriber.isLoadTemporarilyDisabled ? .blocked : .missing,
            localURL: nil,
            partialURL: nil,
            bytes: 0,
            message: disabledMessage.map { "Model files are missing locally. \($0)" }
        )
    }

    private func installWhisperFolder(_ downloadedFolder: URL, at stableFolder: URL) throws {
        if downloadedFolder.standardizedFileURL == stableFolder.standardizedFileURL,
           modelFolderExists(at: stableFolder) {
            return
        }

        let incomingFolder = stableFolder.deletingLastPathComponent()
            .appendingPathComponent(".\(stableFolder.lastPathComponent).incoming", isDirectory: true)
        if fileManager.fileExists(atPath: incomingFolder.path) {
            try fileManager.removeItem(at: incomingFolder)
        }
        if fileManager.fileExists(atPath: stableFolder.path) {
            try fileManager.removeItem(at: stableFolder)
        }

        do {
            try fileManager.moveItem(at: downloadedFolder, to: incomingFolder)
        } catch {
            try fileManager.copyItem(at: downloadedFolder, to: incomingFolder)
            try? fileManager.removeItem(at: downloadedFolder)
        }
        try fileManager.moveItem(at: incomingFolder, to: stableFolder)
        try excludeFromBackup(stableFolder)
    }

    private func discoverExistingWhisperFolder(for model: WhisperModelSize) throws -> URL? {
        for root in try whisperDiscoveryRoots() {
            guard fileManager.fileExists(atPath: root.path),
                  let children = try? fileManager.contentsOfDirectory(
                    at: root,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles]
                  )
            else {
                continue
            }
            if let match = children.first(where: { candidate in
                guard modelFolderExists(at: candidate) else { return false }
                return Self.matchesWhisperVariant(candidate.lastPathComponent, model: model)
            }) {
                return match
            }
        }
        return nil
    }

    private func prepareAppManagedDirectory(_ url: URL) throws {
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        try excludeFromBackup(url)
    }

    private func appManagedRoot() throws -> URL {
        let base = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let root = base.appendingPathComponent("ModelAssets", isDirectory: true)
        try prepareAppManagedDirectory(root)
        return root
    }

    private func ggufURL(for model: BenchmarkTextToToolModel) throws -> URL {
        try appManagedRoot()
            .appendingPathComponent("gguf", isDirectory: true)
            .appendingPathComponent(Self.safePathComponent(model.id), isDirectory: true)
            .appendingPathComponent(model.downloadFilename ?? Self.defaultGGUFFilename(for: model), isDirectory: false)
    }

    private func partialGGUFURL(for model: BenchmarkTextToToolModel) throws -> URL {
        try ggufURL(for: model).appendingPathExtension("partial")
    }

    private func manifestURL(for model: BenchmarkTextToToolModel) throws -> URL {
        try ggufURL(for: model).appendingPathExtension("manifest.json")
    }

    private func ggufProjectorURL(for model: BenchmarkTextToToolModel) throws -> URL {
        try appManagedRoot()
            .appendingPathComponent("mmproj", isDirectory: true)
            .appendingPathComponent(Self.safePathComponent(model.id), isDirectory: true)
            .appendingPathComponent(
                model.mmprojDownloadFilename ?? "mmproj-\(Self.defaultGGUFFilename(for: model))",
                isDirectory: false
            )
    }

    private func partialGGUFProjectorURL(for model: BenchmarkTextToToolModel) throws -> URL {
        try ggufProjectorURL(for: model).appendingPathExtension("partial")
    }

    private func ggufProjectorManifestURL(for model: BenchmarkTextToToolModel) throws -> URL {
        try ggufProjectorURL(for: model).appendingPathExtension("manifest.json")
    }

    private func stableWhisperFolder(for model: WhisperModelSize) throws -> URL {
        try appManagedRoot()
            .appendingPathComponent("whisper", isDirectory: true)
            .appendingPathComponent(Self.safePathComponent(model.whisperKitModelName), isDirectory: true)
    }

    private func whisperDownloadCacheRoot() throws -> URL {
        try appManagedRoot()
            .appendingPathComponent("whisper-download-cache", isDirectory: true)
    }

    private func whisperDiscoveryRoots() throws -> [URL] {
        let documents = try fileManager.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        )
        return [
            try whisperDownloadCacheRoot()
                .appendingPathComponent("models", isDirectory: true)
                .appendingPathComponent("argmaxinc", isDirectory: true)
                .appendingPathComponent("whisperkit-coreml", isDirectory: true),
            documents
                .appendingPathComponent("huggingface", isDirectory: true)
                .appendingPathComponent("models", isDirectory: true)
                .appendingPathComponent("argmaxinc", isDirectory: true)
                .appendingPathComponent("whisperkit-coreml", isDirectory: true)
        ]
    }

    private func leapFolder(modelName: String, quantization: String) throws -> URL {
        let documents = try fileManager.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        )
        return documents
            .appendingPathComponent("leap_models", isDirectory: true)
            .appendingPathComponent("\(modelName)-\(quantization)", isDirectory: true)
    }

    private func validFileExists(at url: URL) throws -> Bool {
        guard fileManager.fileExists(atPath: url.path) else { return false }
        return try fileSize(at: url) > 0
    }

    private func bundledModelFileURL(named filename: String) throws -> URL? {
        let nsFilename = filename as NSString
        let basename = nsFilename.deletingPathExtension
        let pathExtension = nsFilename.pathExtension
        let candidateSubdirectories: [String?] = [
            nil,
            "ModelAssets",
            "ModelAssets/gguf",
            "ModelAssets/mmproj"
        ]

        for subdirectory in candidateSubdirectories {
            let directURL = Bundle.main.url(
                forResource: filename,
                withExtension: nil,
                subdirectory: subdirectory
            )
            if let directURL, try validFileExists(at: directURL) {
                return directURL
            }

            let splitURL = Bundle.main.url(
                forResource: basename,
                withExtension: pathExtension.isEmpty ? nil : pathExtension,
                subdirectory: subdirectory
            )
            if let splitURL, try validFileExists(at: splitURL) {
                return splitURL
            }
        }

        return nil
    }

    private func modelFolderExists(at url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            return false
        }
        guard let contents = try? fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return false
        }
        return contents.isEmpty == false
    }

    private func fileSize(at url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values.fileSize ?? 0)
    }

    private func folderSize(at url: URL) -> Int64 {
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true
            else {
                continue
            }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }

    private func expectedByteCount(response: URLResponse, existingPartialBytes: Int64) -> Int64? {
        guard response.expectedContentLength > 0 else { return nil }
        return existingPartialBytes + response.expectedContentLength
    }

    private func reportDownloadProgress(
        receivedBytes: Int64,
        expectedBytes: Int64?,
        startedAt: Date,
        progressHandler: (@Sendable (ModelAssetDownloadProgress) -> Void)?
    ) {
        let elapsed = max(Date().timeIntervalSince(startedAt), 0.1)
        let speed = Int64(Double(receivedBytes) / elapsed)
        let progress: Double?
        if let expectedBytes, expectedBytes > 0 {
            progress = min(max(Double(receivedBytes) / Double(expectedBytes), 0), 1)
        } else {
            progress = nil
        }
        progressHandler?(
            ModelAssetDownloadProgress(
                phase: .downloading,
                progress: progress,
                speedBytesPerSecond: speed,
                receivedBytes: receivedBytes,
                expectedBytes: expectedBytes
            )
        )
    }

    private func writeManifest(_ manifest: GGUFModelManifest, at url: URL) throws {
        let data = try jsonEncoder.encode(manifest)
        try data.write(to: url, options: [.atomic])
    }

    private func excludeFromBackup(_ url: URL) throws {
        var mutableURL = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try mutableURL.setResourceValues(values)
    }

    private static func normalizedProgress(_ progress: Progress) -> Double {
        let fraction = progress.fractionCompleted
        guard fraction.isFinite else { return 0 }
        return min(max(fraction, 0), 1)
    }

    private static func progressSpeed(_ progress: Progress) -> Int64 {
        if let throughput = progress.userInfo[.throughputKey] as? NSNumber {
            return throughput.int64Value
        }
        return 0
    }

    private static func safePathComponent(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let mapped = raw.unicodeScalars.map { scalar -> Character in
            allowed.contains(scalar) ? Character(scalar) : "-"
        }
        let value = String(mapped)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".-_/ "))
        return value.isEmpty ? "model" : value
    }

    private static func matchesWhisperVariant(_ folderName: String, model: WhisperModelSize) -> Bool {
        let normalizedFolder = folderName.lowercased().replacingOccurrences(of: "_", with: "-")
        let normalizedModel = model.whisperKitModelName.lowercased().replacingOccurrences(of: "_", with: "-")
        return normalizedFolder == normalizedModel
            || normalizedFolder.hasSuffix("-\(normalizedModel)")
            || normalizedFolder.contains(normalizedModel)
    }

    private static func defaultGGUFFilename(for model: BenchmarkTextToToolModel) -> String {
        "\(safePathComponent(model.modelName)).gguf"
    }
}

private struct GGUFDownloadResult {
    let expectedBytes: Int64?
    let finalBytes: Int64
}

private struct GGUFModelManifest: Codable {
    let modelId: String
    let displayName: String
    let sourceURL: String
    let fileName: String
    let expectedBytes: Int64?
    let finalBytes: Int64
    let completedAt: Date
}
