import Foundation
import WhisperKit

struct WhisperModelDownloadProgress: Sendable {
    let model: WhisperModelSize
    let modelIndex: Int
    let totalModels: Int
    let modelProgress: Double
    let phase: ModelAssetPhase

    var overallProgress: Double {
        guard totalModels > 0 else { return 1 }
        return (Double(modelIndex) + modelProgress) / Double(totalModels)
    }

    init(
        model: WhisperModelSize,
        modelIndex: Int,
        totalModels: Int,
        modelProgress: Double,
        phase: ModelAssetPhase = .downloading
    ) {
        self.model = model
        self.modelIndex = modelIndex
        self.totalModels = totalModels
        self.modelProgress = modelProgress
        self.phase = phase
    }
}

actor WhisperSpeechTranscriber {
    static let shared = WhisperSpeechTranscriber()

    private let modelManager = VoiceRecorderModelManager.shared
    private var pipelines: [WhisperModelSize: WhisperKit] = [:]

    func prepareModels(
        _ models: [WhisperModelSize],
        progressHandler: (@Sendable (WhisperModelDownloadProgress) -> Void)? = nil
    ) async throws {
        for (index, model) in models.enumerated() {
            progressHandler?(
                WhisperModelDownloadProgress(
                    model: model,
                    modelIndex: index,
                    totalModels: models.count,
                    modelProgress: 0,
                    phase: .checking
                )
            )
            _ = try await pipeline(
                for: model,
                modelIndex: index,
                totalModels: models.count,
                progressHandler: progressHandler
            )
            progressHandler?(
                WhisperModelDownloadProgress(
                    model: model,
                    modelIndex: index,
                    totalModels: models.count,
                    modelProgress: 1,
                    phase: .cached
                )
            )
        }
    }

    func transcribe(url: URL, model: WhisperModelSize) async throws -> String {
        let pipe = try await pipeline(for: model)
        let results = try await pipe.transcribe(audioPath: url.path)
        let merged = TranscriptionUtilities.mergeTranscriptionResults(results.map { Optional($0) })
        let transcript = merged.text.trimmingCharacters(in: .whitespacesAndNewlines)

        if transcript.isEmpty {
            throw SpeechTranscriptionError.noTranscription
        }

        return transcript
    }

    private func pipeline(
        for model: WhisperModelSize,
        modelIndex: Int = 0,
        totalModels: Int = 1,
        progressHandler: (@Sendable (WhisperModelDownloadProgress) -> Void)? = nil
    ) async throws -> WhisperKit {
        if let pipeline = pipelines[model] {
            progressHandler?(
                WhisperModelDownloadProgress(
                    model: model,
                    modelIndex: modelIndex,
                    totalModels: totalModels,
                    modelProgress: 1,
                    phase: .cached
                )
            )
            return pipeline
        }

        let modelFolder = try await prepareModelFolder(
            model,
            modelIndex: modelIndex,
            totalModels: totalModels,
            progressHandler: progressHandler
        )

        let pipeline: WhisperKit
        do {
            progressHandler?(
                WhisperModelDownloadProgress(
                    model: model,
                    modelIndex: modelIndex,
                    totalModels: totalModels,
                    modelProgress: 1,
                    phase: .loading
                )
            )
            pipeline = try await makePipeline(model: model, modelFolder: modelFolder)
        } catch {
            await modelManager.invalidate(.whisper(model))
            let refreshedFolder = try await prepareModelFolder(
                model,
                modelIndex: modelIndex,
                totalModels: totalModels,
                progressHandler: progressHandler
            )
            progressHandler?(
                WhisperModelDownloadProgress(
                    model: model,
                    modelIndex: modelIndex,
                    totalModels: totalModels,
                    modelProgress: 1,
                    phase: .loading
                )
            )
            pipeline = try await makePipeline(model: model, modelFolder: refreshedFolder)
        }
        pipelines[model] = pipeline
        return pipeline
    }

    private func prepareModelFolder(
        _ model: WhisperModelSize,
        modelIndex: Int,
        totalModels: Int,
        progressHandler: (@Sendable (WhisperModelDownloadProgress) -> Void)?
    ) async throws -> URL {
        guard let modelFolder = try await modelManager.prepare(
            .whisper(model),
            progressHandler: { progress in
                let modelProgress: Double
                if let progressValue = progress.progress {
                    modelProgress = progressValue
                } else if progress.phase == .cached {
                    modelProgress = 1
                } else {
                    modelProgress = 0
                }
                progressHandler?(
                    WhisperModelDownloadProgress(
                        model: model,
                        modelIndex: modelIndex,
                        totalModels: totalModels,
                        modelProgress: modelProgress,
                        phase: progress.phase
                    )
                )
            }
        ) else {
            throw SpeechTranscriptionError.transcriptionFailed("Whisper \(model.displayName) did not resolve to a local model folder.")
        }
        return modelFolder
    }

    private func makePipeline(model: WhisperModelSize, modelFolder: URL) async throws -> WhisperKit {
        let config = WhisperKitConfig(
            model: model.whisperKitModelName,
            modelFolder: modelFolder.path,
            verbose: false,
            prewarm: false,
            load: true,
            download: false
        )
        return try await WhisperKit(config)
    }

}
