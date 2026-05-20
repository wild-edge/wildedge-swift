import Foundation
import WhisperKit

struct WhisperModelDownloadProgress: Sendable {
    let model: WhisperModelSize
    let modelIndex: Int
    let totalModels: Int
    let modelProgress: Double

    var overallProgress: Double {
        guard totalModels > 0 else { return 1 }
        return (Double(modelIndex) + modelProgress) / Double(totalModels)
    }
}

actor WhisperSpeechTranscriber {
    static let shared = WhisperSpeechTranscriber()

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
                    modelProgress: 0
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
                    modelProgress: 1
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
                    modelProgress: 1
                )
            )
            return pipeline
        }

        let modelFolder = try await WhisperKit.download(
            variant: model.whisperKitModelName,
            progressCallback: { progress in
                progressHandler?(
                    WhisperModelDownloadProgress(
                        model: model,
                        modelIndex: modelIndex,
                        totalModels: totalModels,
                        modelProgress: Self.normalizedProgress(progress)
                    )
                )
            }
        )
        let config = WhisperKitConfig(
            model: model.whisperKitModelName,
            modelFolder: modelFolder.path,
            verbose: false,
            prewarm: false,
            load: true,
            download: false
        )
        let pipeline = try await WhisperKit(config)
        pipelines[model] = pipeline
        return pipeline
    }

    private static func normalizedProgress(_ progress: Progress) -> Double {
        let fraction = progress.fractionCompleted
        guard fraction.isFinite else { return 0 }
        return min(max(fraction, 0), 1)
    }
}
