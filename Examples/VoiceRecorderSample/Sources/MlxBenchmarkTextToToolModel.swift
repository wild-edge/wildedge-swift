import Foundation

#if canImport(Hub) && canImport(MLXLLM) && canImport(MLXLMCommon)
import Hub
import MLXLLM
import MLXLMCommon
#endif

actor MlxBenchmarkTextToToolModel {
    static let shared = MlxBenchmarkTextToToolModel()

    private let fileManager = FileManager.default
    private var loadedConfiguration: BenchmarkTextToToolModel?

    #if canImport(Hub) && canImport(MLXLLM) && canImport(MLXLMCommon)
    private var loadedContainer: ModelContainer?
    #endif

    private init() {
    }

    func modelStatus(_ model: BenchmarkTextToToolModel) async -> ModelAssetStatus {
        guard model.provider == "mlx", model.modelFormat == "safetensors" else {
            return ModelAssetStatus(
                state: .blocked,
                localURL: nil,
                partialURL: nil,
                bytes: 0,
                message: "\(model.displayName) is not an MLX Safetensors model."
            )
        }

        do {
            guard let directory = try cachedModelDirectory(for: model) else {
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
                localURL: directory,
                partialURL: nil,
                bytes: try directorySize(directory),
                message: nil
            )
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

    func prepareModel(
        _ model: BenchmarkTextToToolModel,
        progressHandler: (@Sendable (_ progress: Double, _ speed: Int64) -> Void)? = nil
    ) async throws {
        guard model.provider == "mlx", model.modelFormat == "safetensors" else {
            throw SpeechTranscriptionError.transcriptionFailed(
                "\(model.displayName) is not an MLX Safetensors model."
            )
        }

        #if canImport(Hub) && canImport(MLXLLM) && canImport(MLXLMCommon)
        if loadedConfiguration == model, loadedContainer != nil {
            return
        }

        let hub = try HubApi(downloadBase: mlxDownloadRoot())
        let container = try await MLXLMCommon.loadModelContainer(
            hub: hub,
            id: model.modelName,
            progressHandler: { progress in
                progressHandler?(Self.normalizedProgress(progress), Self.progressSpeed(progress))
            }
        )
        loadedContainer = container
        loadedConfiguration = model
        #else
        throw SpeechTranscriptionError.transcriptionFailed(
            "MLX is not linked in this build. Cannot run \(model.displayName)."
        )
        #endif
    }

    func invalidateModel(_ model: BenchmarkTextToToolModel) async {
        guard model.provider == "mlx", model.modelFormat == "safetensors" else { return }
        #if canImport(Hub) && canImport(MLXLLM) && canImport(MLXLMCommon)
        if loadedConfiguration == model {
            loadedContainer = nil
            loadedConfiguration = nil
        }
        #endif
        do {
            if let directory = try cachedModelDirectory(for: model) {
                try? fileManager.removeItem(at: directory)
            }
        } catch {
            return
        }
    }

    func toolCall(
        fromTranscript transcript: String,
        model: BenchmarkTextToToolModel,
        progressHandler: (@Sendable (_ progress: Double, _ speed: Int64) -> Void)? = nil
    ) async throws -> String {
        #if canImport(Hub) && canImport(MLXLLM) && canImport(MLXLMCommon)
        try await prepareModel(model, progressHandler: progressHandler)
        guard let loadedContainer else {
            throw SpeechTranscriptionError.transcriptionFailed("\(model.displayName) is not loaded.")
        }

        let session = ChatSession(
            loadedContainer,
            instructions: ToolCallPromptBuilder.systemPrompt,
            generateParameters: Self.generateParameters(for: model),
            additionalContext: ["enable_thinking": false]
        )
        var response = ""
        for try await chunk in session.streamResponse(
            to: ToolCallPromptBuilder.chatTextToToolUserPrompt(transcript: transcript)
        ) {
            response += chunk
            if let toolCallJSON = ToolCallJSON.firstValidToolCallJSONString(from: response) {
                return toolCallJSON
            }
        }

        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            throw SpeechTranscriptionError.transcriptionFailed("\(model.displayName) returned no text output.")
        }
        let cleaned = ToolCallJSON.textWithoutThinkBlocks(from: trimmed)
        return ToolCallJSON.firstValidToolCallJSONString(from: trimmed)
            ?? cleaned
        #else
        throw SpeechTranscriptionError.transcriptionFailed(
            "MLX is not linked in this build. Cannot run \(model.displayName)."
        )
        #endif
    }

    private func cachedModelDirectory(for model: BenchmarkTextToToolModel) throws -> URL? {
        let root = try mlxDownloadRoot()
        guard fileManager.fileExists(atPath: root.path) else {
            return nil
        }

        let repoKey = model.modelName
            .replacingOccurrences(of: "/", with: "--")
            .lowercased()
        let repoName = model.modelName
            .split(separator: "/")
            .last
            .map(String.init)?
            .lowercased()
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension == "safetensors" else {
                continue
            }
            let lowercasedPath = fileURL.path.lowercased()
            if lowercasedPath.contains(repoKey) || repoName.map(lowercasedPath.contains) == true {
                return fileURL.deletingLastPathComponent()
            }
        }
        return nil
    }

    private func mlxDownloadRoot() throws -> URL {
        let base = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let root = base
            .appendingPathComponent("ModelAssets", isDirectory: true)
            .appendingPathComponent("mlx", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try excludeFromBackup(root)
        return root
    }

    private func directorySize(_ directory: URL) throws -> Int64 {
        var total: Int64 = 0
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }
        for case let fileURL as URL in enumerator {
            let values = try fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if values.isRegularFile == true {
                total += Int64(values.fileSize ?? 0)
            }
        }
        return total
    }

    private func excludeFromBackup(_ url: URL) throws {
        var mutableURL = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try mutableURL.setResourceValues(values)
    }

    private nonisolated static func normalizedProgress(_ progress: Progress) -> Double {
        let fraction = progress.fractionCompleted
        guard fraction.isFinite else { return 0 }
        return min(max(fraction, 0), 1)
    }

    private nonisolated static func progressSpeed(_ progress: Progress) -> Int64 {
        if let throughput = progress.userInfo[.throughputKey] as? NSNumber {
            return throughput.int64Value
        }
        return 0
    }

    #if canImport(Hub) && canImport(MLXLLM) && canImport(MLXLMCommon)
    private nonisolated static func generateParameters(
        for model: BenchmarkTextToToolModel
    ) -> GenerateParameters {
        GenerateParameters(
            maxTokens: min(max(model.maxGenerationTokens, 24), 64),
            temperature: 0.0,
            topP: 1.0,
            topK: 1
        )
    }
    #endif
}
