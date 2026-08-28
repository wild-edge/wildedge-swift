import Foundation
import Speech

enum SpeechTranscriptionError: LocalizedError {
    case recognizerUnavailable
    case onDeviceRecognitionUnavailable
    case noTranscription
    case transcriptionFailed(String)

    var errorDescription: String? {
        switch self {
        case .recognizerUnavailable:
            return "Apple Speech recognizer is unavailable."
        case .onDeviceRecognitionUnavailable:
            return "On-device Apple Speech recognition is unavailable for the current locale."
        case .noTranscription:
            return "Speech to text did not produce a transcript."
        case .transcriptionFailed(let message):
            return message
        }
    }
}

struct SpeechTranscriptionResult {
    let transcript: String?
    let durationMs: Int
    let errorDescription: String?
    let provider: String
    let modelId: String
    let modelName: String
    let requiresOnDeviceRecognition: Bool
    let whisperModelSize: WhisperModelSize?
}

struct AppleSpeechTranscriber {
    func transcribe(url: URL, locale: Locale = .current) async throws -> String {
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            throw SpeechTranscriptionError.recognizerUnavailable
        }

        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = false

        if #available(iOS 13.0, *) {
            guard recognizer.supportsOnDeviceRecognition else {
                throw SpeechTranscriptionError.onDeviceRecognitionUnavailable
            }
            request.requiresOnDeviceRecognition = true
        }

        return try await withCheckedThrowingContinuation { continuation in
            let gate = TranscriptionContinuationGate()

            let task = recognizer.recognitionTask(with: request) { result, error in
                if let error {
                    gate.resumeOnce {
                        continuation.resume(throwing: error)
                    }
                    return
                }

                guard let result, result.isFinal else { return }
                let transcript = result.bestTranscription.formattedString
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                if transcript.isEmpty {
                    gate.resumeOnce {
                        continuation.resume(throwing: SpeechTranscriptionError.noTranscription)
                    }
                } else {
                    gate.resumeOnce {
                        continuation.resume(returning: transcript)
                    }
                }
            }

            Task {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                gate.resumeOnce {
                    task.cancel()
                    continuation.resume(throwing: SpeechTranscriptionError.noTranscription)
                }
            }
        }
    }
}

private final class TranscriptionContinuationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var didResume = false

    func resumeOnce(_ resume: () -> Void) {
        lock.lock()
        guard !didResume else {
            lock.unlock()
            return
        }
        didResume = true
        lock.unlock()
        resume()
    }
}
