import Foundation

enum VoiceToTextMode: String, CaseIterable, Identifiable, Sendable {
    case disabled
    case apple
    case whisper
    case leap

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .disabled:
            return "Disabled"
        case .apple:
            return "Enabled - Apple"
        case .whisper:
            return "Enabled - Whisper"
        case .leap:
            return "Enabled - Leap LFM2.5 Audio"
        }
    }
}

enum WhisperModelSize: String, CaseIterable, Identifiable, Sendable {
    case tiny
    case base

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .tiny:
            return "Tiny"
        case .base:
            return "Base"
        }
    }

    var whisperKitModelName: String {
        "openai_whisper-\(rawValue)"
    }

    var wildEdgeModelId: String {
        "openai-whisper-\(rawValue)"
    }
}

enum AudioToToolArchitecture: String, CaseIterable, Identifiable, Sendable {
    case twoStep = "2step"
    case oneStep = "1step"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .twoStep:
            return "2step"
        case .oneStep:
            return "1step"
        }
    }
}

#if BENCHMARK_BUILD
enum BenchmarkStep: String, CaseIterable, Identifiable, Sendable {
    case speechToText = "speech_to_text"
    case textToTool = "text_to_tool"
    case speechToTool = "speech_to_tool"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .speechToText:
            return "speech to text"
        case .textToTool:
            return "text to tool"
        case .speechToTool:
            return "speech to tool"
        }
    }

    init?(remoteValue: String) {
        let normalized = remoteValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
        switch normalized {
        case "speech_to_text", "stt", "asr", "transcribe":
            self = .speechToText
        case "text_to_tool", "text_to_tools", "tool_from_text":
            self = .textToTool
        case "speech_to_tool", "speech_to_tools", "audio_to_tool", "direct_audio_to_tool":
            self = .speechToTool
        default:
            return nil
        }
    }
}
#endif

enum BenchmarkTextToToolModelKind: String, Sendable {
    case leapLFM25Audio
    case leapLFM25350M
    case leapLFM2512BInstruct
    case functionGemma
    case functionGemmaMLX
    case qwen35ZeroPointEightBOptiQMLX
    case qwen3ZeroPointSixBInstructMLX
    case qwen25ZeroPointFiveBInstructMLX
    case tinyLlamaOnePointOneB
    case qwen25OnePointFiveBInstruct
    case qwen3ZeroPointSixB
    case qwen3FourB
    case onnxRuntime
    case appleFoundationModels
    case custom
}

struct BenchmarkTextToToolModel: Hashable, Identifiable, Sendable {
    let kind: BenchmarkTextToToolModelKind
    let id: String
    let displayName: String
    let modelName: String
    let quantization: String
    let provider: String
    let modelSource: String
    let modelFormat: String
    let downloadURLString: String?
    let downloadFilename: String?
    let approximateDownloadSize: String?
    let contextSize: Int
    let maxGenerationTokens: Int

    init(
        kind: BenchmarkTextToToolModelKind,
        id: String,
        displayName: String,
        modelName: String,
        quantization: String,
        provider: String,
        modelSource: String,
        modelFormat: String,
        downloadURLString: String? = nil,
        downloadFilename: String? = nil,
        approximateDownloadSize: String? = nil,
        contextSize: Int = 1024,
        maxGenerationTokens: Int = 192
    ) {
        self.kind = kind
        self.id = id
        self.displayName = displayName
        self.modelName = modelName
        self.quantization = quantization
        self.provider = provider
        self.modelSource = modelSource
        self.modelFormat = modelFormat
        self.downloadURLString = downloadURLString
        self.downloadFilename = downloadFilename
        self.approximateDownloadSize = approximateDownloadSize
        self.contextSize = contextSize
        self.maxGenerationTokens = maxGenerationTokens
    }

    static let leapLFM25Audio = BenchmarkTextToToolModel(
        kind: .leapLFM25Audio,
        id: "leap-lfm2.5-audio-1.5b",
        displayName: "Leap LFM2.5 Audio 1.5B",
        modelName: LeapSpeechTranscriber.modelName,
        quantization: LeapSpeechTranscriber.quantization,
        provider: "leap_sdk",
        modelSource: "leap-sdk",
        modelFormat: "gguf"
    )

    static let leapLFM25350M = BenchmarkTextToToolModel(
        kind: .leapLFM25350M,
        id: "lfm2.5-350m",
        displayName: "LFM2 350M Instruct",
        modelName: "LiquidAI/LFM2-350M-GGUF",
        quantization: "Q4_K_M",
        provider: "llama_cpp",
        modelSource: "huggingface",
        modelFormat: "gguf",
        downloadURLString: "https://huggingface.co/LiquidAI/LFM2-350M-GGUF/resolve/main/LFM2-350M-Q4_K_M.gguf",
        downloadFilename: "LFM2-350M-Q4_K_M.gguf",
        approximateDownloadSize: "229 MB",
        contextSize: 1024,
        maxGenerationTokens: 128
    )

    static let leapLFM2512BInstruct = BenchmarkTextToToolModel(
        kind: .leapLFM2512BInstruct,
        id: "lfm2.5-1.2b-instruct",
        displayName: "LFM2 1.2B Instruct",
        modelName: "LiquidAI/LFM2-1.2B-GGUF",
        quantization: "Q4_K_M",
        provider: "llama_cpp",
        modelSource: "huggingface",
        modelFormat: "gguf",
        downloadURLString: "https://huggingface.co/LiquidAI/LFM2-1.2B-GGUF/resolve/main/LFM2-1.2B-Q4_K_M.gguf",
        downloadFilename: "LFM2-1.2B-Q4_K_M.gguf",
        approximateDownloadSize: "697 MB",
        contextSize: 1024,
        maxGenerationTokens: 128
    )

    static let functionGemma = BenchmarkTextToToolModel(
        kind: .functionGemma,
        id: "functiongemma",
        displayName: "FunctionGemma",
        modelName: "bartowski/google_functiongemma-270m-it-GGUF",
        quantization: "Q4_K_M",
        provider: "llama_cpp",
        modelSource: "huggingface",
        modelFormat: "gguf",
        downloadURLString: "https://huggingface.co/bartowski/google_functiongemma-270m-it-GGUF/resolve/main/google_functiongemma-270m-it-Q4_K_M.gguf",
        downloadFilename: "google_functiongemma-270m-it-Q4_K_M.gguf",
        approximateDownloadSize: "253 MB",
        contextSize: 1024,
        maxGenerationTokens: 128
    )

    static let functionGemmaMLX = BenchmarkTextToToolModel(
        kind: .functionGemmaMLX,
        id: "functiongemma-mlx-4bit",
        displayName: "FunctionGemma MLX 4-bit",
        modelName: "mlx-community/functiongemma-270m-it-4bit",
        quantization: "4-bit",
        provider: "mlx",
        modelSource: "huggingface",
        modelFormat: "safetensors",
        approximateDownloadSize: "151 MB",
        contextSize: 1024,
        maxGenerationTokens: 40
    )

    static let qwen35ZeroPointEightBOptiQMLX = BenchmarkTextToToolModel(
        kind: .qwen35ZeroPointEightBOptiQMLX,
        id: "qwen3.5-0.8b-mlx-optiq-4bit",
        displayName: "Qwen3.5 0.8B OptiQ MLX 4-bit (experimental)",
        modelName: "mlx-community/Qwen3.5-0.8B-OptiQ-4bit",
        quantization: "OptiQ 4-bit",
        provider: "mlx",
        modelSource: "huggingface",
        modelFormat: "safetensors",
        approximateDownloadSize: "0.6 GB",
        contextSize: 1024,
        maxGenerationTokens: 40
    )

    static let qwen3ZeroPointSixBInstructMLX = BenchmarkTextToToolModel(
        kind: .qwen3ZeroPointSixBInstructMLX,
        id: "qwen3-0.6b-instruct-mlx-4bit",
        displayName: "Qwen3 0.6B Instruct MLX 4-bit",
        modelName: "mlx-community/Qwen3-0.6B-Instruct-4bit",
        quantization: "4-bit",
        provider: "mlx",
        modelSource: "huggingface",
        modelFormat: "safetensors",
        contextSize: 1024,
        maxGenerationTokens: 40
    )

    static let qwen25ZeroPointFiveBInstructMLX = BenchmarkTextToToolModel(
        kind: .qwen25ZeroPointFiveBInstructMLX,
        id: "qwen2.5-0.5b-instruct-mlx-4bit",
        displayName: "Qwen2.5 0.5B Instruct MLX 4-bit",
        modelName: "mlx-community/Qwen2.5-0.5B-Instruct-4bit",
        quantization: "4-bit",
        provider: "mlx",
        modelSource: "huggingface",
        modelFormat: "safetensors",
        contextSize: 1024,
        maxGenerationTokens: 40
    )

    static let tinyLlamaOnePointOneB = BenchmarkTextToToolModel(
        kind: .tinyLlamaOnePointOneB,
        id: "tinyllama-1.1b-4bit",
        displayName: "TinyLlama 1.1B 4-bit GGUF",
        modelName: "TheBloke/TinyLlama-1.1B-Chat-v1.0-GGUF",
        quantization: "Q4_K_M",
        provider: "llama_cpp",
        modelSource: "huggingface",
        modelFormat: "gguf",
        downloadURLString: "https://huggingface.co/TheBloke/TinyLlama-1.1B-Chat-v1.0-GGUF/resolve/main/tinyllama-1.1b-chat-v1.0.Q4_K_M.gguf",
        downloadFilename: "tinyllama-1.1b-chat-v1.0.Q4_K_M.gguf",
        approximateDownloadSize: "about 700 MB",
        contextSize: 1024,
        maxGenerationTokens: 128
    )

    static let qwen25OnePointFiveBInstruct = BenchmarkTextToToolModel(
        kind: .qwen25OnePointFiveBInstruct,
        id: "qwen2.5-1.5b-instruct",
        displayName: "Qwen2.5 1.5B Instruct",
        modelName: "Qwen/Qwen2.5-1.5B-Instruct-GGUF",
        quantization: "Q4_K_M",
        provider: "llama_cpp",
        modelSource: "huggingface",
        modelFormat: "gguf",
        downloadURLString: "https://huggingface.co/Qwen/Qwen2.5-1.5B-Instruct-GGUF/resolve/main/qwen2.5-1.5b-instruct-q4_k_m.gguf",
        downloadFilename: "qwen2.5-1.5b-instruct-q4_k_m.gguf",
        approximateDownloadSize: "1.04 GB",
        contextSize: 1024,
        maxGenerationTokens: 128
    )

    static let qwen3ZeroPointSixB4Bit = BenchmarkTextToToolModel(
        kind: .qwen3ZeroPointSixB,
        id: "qwen3-0.6b-4bit",
        displayName: "Qwen3 0.6B 4-bit",
        modelName: "unsloth/Qwen3-0.6B-GGUF",
        quantization: "Q4_K_M",
        provider: "llama_cpp",
        modelSource: "huggingface",
        modelFormat: "gguf",
        downloadURLString: "https://huggingface.co/unsloth/Qwen3-0.6B-GGUF/resolve/main/Qwen3-0.6B-Q4_K_M.gguf",
        downloadFilename: "Qwen3-0.6B-Q4_K_M.gguf",
        approximateDownloadSize: "397 MB",
        contextSize: 1024,
        maxGenerationTokens: 128
    )

    static let qwen3FourB4Bit = BenchmarkTextToToolModel(
        kind: .qwen3FourB,
        id: "qwen3-4b-4bit",
        displayName: "Qwen3-4B 4-bit",
        modelName: "Qwen/Qwen3-4B-GGUF",
        quantization: "Q4_K_M",
        provider: "llama_cpp",
        modelSource: "huggingface",
        modelFormat: "gguf",
        downloadURLString: "https://huggingface.co/Qwen/Qwen3-4B-GGUF/resolve/main/Qwen3-4B-Q4_K_M.gguf",
        downloadFilename: "Qwen3-4B-Q4_K_M.gguf",
        approximateDownloadSize: "2.5 GB",
        contextSize: 1024,
        maxGenerationTokens: 128
    )

    static let onnxRuntime = BenchmarkTextToToolModel(
        kind: .onnxRuntime,
        id: "onnx-text-to-tool",
        displayName: "ONNX Text To Tool",
        modelName: "onnx-text-to-tool",
        quantization: "",
        provider: "onnxruntime",
        modelSource: "remote",
        modelFormat: "onnx"
    )

    static let appleFoundationModels = BenchmarkTextToToolModel(
        kind: .appleFoundationModels,
        id: "apple-foundation-models",
        displayName: "Apple Foundation Models",
        modelName: "SystemLanguageModel.default",
        quantization: "",
        provider: "foundation_models",
        modelSource: "apple",
        modelFormat: "foundationmodels"
    )

    static let `default` = functionGemma

    var modelId: String {
        if quantization.isEmpty {
            return modelName
        }
        return "\(modelName)-\(quantization)"
    }

    var logicalModelId: String {
        "\(id)-text-to-tool"
    }

    var signature: String {
        [
            kind.rawValue,
            id,
            modelName,
            quantization,
            provider,
            modelSource,
            modelFormat,
            downloadURLString ?? "",
            downloadFilename ?? "",
            String(contextSize),
            String(maxGenerationTokens)
        ].joined(separator: ":")
    }

    var usesSharedAudioModel: Bool {
        kind == .leapLFM25Audio
            && modelName == Self.leapLFM25Audio.modelName
            && quantization == Self.leapLFM25Audio.quantization
    }

    func matchesRemoteAllowlistPreset(_ preset: BenchmarkTextToToolModel) -> Bool {
        kind == preset.kind
            && modelName == preset.modelName
            && quantization == preset.quantization
            && provider == preset.provider
            && modelSource == preset.modelSource
            && modelFormat == preset.modelFormat
    }

    func withOverrides(
        displayName: String? = nil,
        modelName: String? = nil,
        quantization: String? = nil,
        provider: String? = nil,
        modelSource: String? = nil,
        modelFormat: String? = nil,
        downloadURLString: String? = nil,
        downloadFilename: String? = nil,
        contextSize: Int? = nil,
        maxGenerationTokens: Int? = nil
    ) -> BenchmarkTextToToolModel {
        let resolvedModelName = modelName ?? self.modelName
        return BenchmarkTextToToolModel(
            kind: kind,
            id: id,
            displayName: displayName ?? self.displayName,
            modelName: resolvedModelName,
            quantization: quantization ?? self.quantization,
            provider: provider ?? self.provider,
            modelSource: modelSource ?? self.modelSource,
            modelFormat: modelFormat ?? self.modelFormat,
            downloadURLString: downloadURLString ?? self.downloadURLString,
            downloadFilename: downloadFilename ?? self.downloadFilename,
            approximateDownloadSize: approximateDownloadSize,
            contextSize: contextSize ?? self.contextSize,
            maxGenerationTokens: maxGenerationTokens ?? self.maxGenerationTokens
        )
    }

    static func custom(
        modelName: String,
        displayName: String? = nil,
        quantization: String? = nil,
        provider: String? = nil,
        modelSource: String? = nil,
        modelFormat: String? = nil,
        downloadURLString: String? = nil,
        downloadFilename: String? = nil,
        contextSize: Int? = nil,
        maxGenerationTokens: Int? = nil
    ) -> BenchmarkTextToToolModel {
        let trimmedModelName = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        let id = normalizedIdentifier(trimmedModelName)
        return BenchmarkTextToToolModel(
            kind: .custom,
            id: id.isEmpty ? "custom-text-to-tool" : id,
            displayName: displayName?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? trimmedModelName,
            modelName: trimmedModelName,
            quantization: quantization?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "Q4_K_M",
            provider: provider?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "leap_sdk",
            modelSource: modelSource?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "remote",
            modelFormat: modelFormat?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "gguf",
            downloadURLString: downloadURLString?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            downloadFilename: downloadFilename?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            contextSize: contextSize ?? 1024,
            maxGenerationTokens: maxGenerationTokens ?? 192
        )
    }

    static func preset(remoteValue: String) -> BenchmarkTextToToolModel? {
        let normalized = normalizedIdentifier(remoteValue)
        switch normalized {
        case "", "default", "leap", "leapsdk", "lfm25audio", "lfm25audio15b", "leaplfm25audio15b", "leaplfm25audio15bq40":
            return .leapLFM25Audio
        case "lfm25350m", "lfm25350mq4km", "leaplfm25350m", "leaplfm25350mq4km", "lfm25small", "smallest":
            return .leapLFM25350M
        case "lfm2350m", "lfm2350mq4km", "leaplfm2350m", "leaplfm2350mq4km", "lfm2small":
            return .leapLFM25350M
        case "lfm2512binstruct", "lfm2512binstructq4km", "lfm2512b", "lfm25instruct", "leaplfm2512binstruct", "leaplfm2512binstructq4km":
            return .leapLFM2512BInstruct
        case "functiongemma", "functiongemma4bit", "functiongemmaq40", "gemmafunction", "gemmafunctioncalling":
            return .functionGemma
        case "functiongemmamlx", "functiongemmamlx4bit", "functiongemma270mmlx", "functiongemma270mmlx4bit":
            return .functionGemmaMLX
        case "qwen3508bmlx", "qwen3508bmlx4bit", "qwen3508boptiq", "qwen3508boptiq4bit", "qwen3508bmlxoptiq4bit", "qwen3508b", "qwen35small":
            return .qwen35ZeroPointEightBOptiQMLX
        case "qwen306binstruct", "qwen306binstruct4bit", "qwen306binstructmlx", "qwen306binstructmlx4bit", "qwen306bmlx", "qwen306bmlx4bit", "qwen306bmlxcommunity", "qwen3600minstruct", "qwen3600minstruct4bit", "qwen3600minstructmlx", "qwen3600mmlx", "qwen3smallmlx", "mlxcommunityqwen306binstruct4bit":
            return .qwen3ZeroPointSixBInstructMLX
        case "qwen2505binstruct", "qwen2505binstruct4bit", "qwen2505binstructmlx", "qwen2505binstructmlx4bit", "qwen2505bmlx", "qwen2505bmlx4bit", "qwen2505b", "qwen2505b4bit", "qwen25mini", "qwen25smallest", "qwen05bmlx", "qwen05binstruct", "qwen05binstruct4bit", "qwen05binstructmlx", "qwen500mmlx", "qwen500minstruct", "qwen500minstruct4bit", "qwen500minstructmlx", "mlxcommunityqwen2505binstruct4bit":
            return .qwen25ZeroPointFiveBInstructMLX
        case "tinyllama", "tinyllama11b", "tinyllama11b4bit", "tinyllama11bgguf", "tinyllama11b4bitgguf", "tinyllama11bq4km", "tinyllama11bchat", "tinyllama11bchatv10", "tinyllama1b":
            return .tinyLlamaOnePointOneB
        case "qwen15b", "qwen15binstruct", "qwen2515b", "qwen2515binstruct", "qwen25small":
            return .qwen25OnePointFiveBInstruct
        case "qwen306b", "qwen306b4bit", "qwen306bq4km", "qwen306bgguf", "qwen3600m", "qwen3600m4bit", "qwen3600mq4km", "qwen3small":
            return .qwen3ZeroPointSixB4Bit
        case "qwen34b", "qwen34b4bit", "qwen34bq40", "qwen34bq4":
            return .qwen3FourB4Bit
        case "qwen3":
            return .functionGemma
        case "onnx", "onnxruntime", "onnxtexttotool":
            return .onnxRuntime
        case "applefoundationmodels", "foundationmodels", "appleintelligence", "systemlanguagemodel", "apple":
            return .appleFoundationModels
        default:
            if normalized.contains("functiongemma") {
                if normalized.contains("mlx") {
                    return .functionGemmaMLX
                }
                return .functionGemma
            }
            if normalized.contains("qwen35") || normalized.contains("qwen3.5") || normalized.contains("qwen3_5") {
                if normalized.contains("08b") || normalized.contains("0.8b") || normalized.contains("800m") || normalized.contains("optiq") {
                    return .qwen35ZeroPointEightBOptiQMLX
                }
            }
            if normalized.contains("qwen25"),
               normalized.contains("mlx"),
               normalized.contains("05b") || normalized.contains("0.5b") || normalized.contains("500m") {
                return .qwen25ZeroPointFiveBInstructMLX
            }
            if normalized.contains("qwen3"),
               normalized.contains("mlx"),
               normalized.contains("06b") || normalized.contains("0.6b") || normalized.contains("600m") {
                return .qwen3ZeroPointSixBInstructMLX
            }
            if normalized.contains("tinyllama") {
                return .tinyLlamaOnePointOneB
            }
            if normalized.contains("qwen"), normalized.contains("15b") || normalized.contains("1b5") {
                return .qwen25OnePointFiveBInstruct
            }
            if normalized.contains("qwen3"), (normalized.contains("06b") || normalized.contains("600m")) {
                return .qwen3ZeroPointSixB4Bit
            }
            if normalized.contains("qwen3"), normalized.contains("4b") {
                return .qwen3FourB4Bit
            }
            if normalized.contains("lfm25") || normalized.contains("lfm2.5") || normalized.contains("lfm2_5") {
                if normalized.contains("12b") && normalized.contains("instruct") {
                    return .leapLFM2512BInstruct
                }
                if normalized.contains("350m") {
                    return .leapLFM25350M
                }
            }
            if normalized.contains("lfm2"), normalized.contains("350m") {
                return .leapLFM25350M
            }
            if normalized.contains("onnx") {
                return .onnxRuntime
            }
            if normalized.contains("foundationmodels") || normalized.contains("appleintelligence") {
                return .appleFoundationModels
            }
            return nil
        }
    }

    static func from(remoteValue: String) -> BenchmarkTextToToolModel? {
        let trimmed = remoteValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return nil }
        if let preset = preset(remoteValue: trimmed) {
            return preset
        }
        if trimmed.contains("/") {
            return custom(modelName: trimmed)
        }
        return custom(modelName: trimmed)
    }

    private static func normalizedIdentifier(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
    }
}

struct VoiceRecorderEffectiveSettings: Sendable {
    let voiceToTextMode: VoiceToTextMode
    let whisperModelSize: WhisperModelSize
    let audioToToolArchitecture: AudioToToolArchitecture
    let includeSpectrogramAttachment: Bool
    let includeWAVAttachment: Bool
    #if BENCHMARK_BUILD
    let benchmarkEnabled: Bool
    let benchmarkDelaySeconds: TimeInterval
    let benchmarkRecordingsMatch: [String]
    let benchmarkNumberOfInferences: Int
    let benchmarkSteps: [BenchmarkStep]
    let benchmarkStepsError: String?
    let benchmarkTextToToolModel: BenchmarkTextToToolModel
    let benchmarkSpeechToToolPrompt: String?
    #endif
    let isUsingSDKPayload: Bool
    let remoteConfigWarning: String?

    var flowDisplayName: String {
        #if BENCHMARK_BUILD
        if benchmarkEnabled {
            if remoteConfigWarning != nil {
                return "benchmark stopped"
            }
            return benchmarkSteps.map(\.rawValue).joined(separator: " + ")
        }
        #endif
        return "manual recording"
    }

    var modelDisplayName: String {
        let speechModel = speechToTextModelDisplayName
        #if BENCHMARK_BUILD
        if benchmarkEnabled {
            if remoteConfigWarning != nil {
                return "No benchmark model running"
            }
            if benchmarkSteps == [.speechToTool] {
                return "Leap LFM2.5 Audio 1.5B"
            }
            if benchmarkSteps.contains(.textToTool) {
                return "\(speechModel) + \(benchmarkTextToToolModel.displayName)"
            }
        }
        #endif
        return speechModel
    }

    private var speechToTextModelDisplayName: String {
        switch voiceToTextMode {
        case .disabled:
            return "No speech-to-text model"
        case .apple:
            return "Apple Speech Recognizer"
        case .whisper:
            return "Whisper \(whisperModelSize.displayName)"
        case .leap:
            return "Leap LFM2.5 Audio 1.5B"
        }
    }
}

@MainActor
final class SettingsStore: ObservableObject {
    @Published var voiceToTextMode: VoiceToTextMode {
        didSet {
            userDefaults.set(voiceToTextMode.rawValue, forKey: Self.voiceToTextModeKey)
        }
    }

    @Published var whisperModelSize: WhisperModelSize {
        didSet {
            userDefaults.set(whisperModelSize.rawValue, forKey: Self.whisperModelSizeKey)
        }
    }

    @Published var includeSpectrogramAttachment: Bool {
        didSet {
            userDefaults.set(includeSpectrogramAttachment, forKey: Self.includeSpectrogramAttachmentKey)
        }
    }

    @Published var includeWAVAttachment: Bool {
        didSet {
            userDefaults.set(includeWAVAttachment, forKey: Self.includeWAVAttachmentKey)
        }
    }

    @Published var audioToToolArchitecture: AudioToToolArchitecture {
        didSet {
            userDefaults.set(audioToToolArchitecture.rawValue, forKey: Self.audioToToolArchitectureKey)
        }
    }

    @Published var useSDKPayloadSettings: Bool {
        didSet {
            userDefaults.set(useSDKPayloadSettings, forKey: Self.useSDKPayloadSettingsKey)
        }
    }

    #if BENCHMARK_BUILD
    @Published var benchmarkEnabled: Bool {
        didSet {
            userDefaults.set(benchmarkEnabled, forKey: Self.benchmarkEnabledKey)
        }
    }
    #endif

    @Published private(set) var sdkPayload: RemoteSDKConfig?
    @Published private(set) var sdkPayloadRefreshedAt: Date?
    @Published private(set) var sdkPayloadStatus: String = "Not refreshed"
    @Published private(set) var isRefreshingSDKPayload = false

    private static let voiceToTextModeKey = "VoiceRecorderSample.voiceToTextMode"
    private static let whisperModelSizeKey = "VoiceRecorderSample.whisperModelSize"
    private static let didDefaultToAppleSpeechKey = "VoiceRecorderSample.didDefaultToAppleSpeech"
    private static let includeSpectrogramAttachmentKey = "VoiceRecorderSample.includeSpectrogramAttachment"
    private static let includeWAVAttachmentKey = "VoiceRecorderSample.includeWAVAttachment"
    private static let includeWAVAttachmentInitializedKey = "VoiceRecorderSample.includeWAVAttachmentInitialized"
    private static let audioToToolArchitectureKey = "VoiceRecorderSample.audioToToolArchitecture"
    private static let useSDKPayloadSettingsKey = "VoiceRecorderSample.useSDKPayloadSettings"
    #if BENCHMARK_BUILD
    private static let benchmarkEnabledKey = "VoiceRecorderSample.benchmarkEnabled"
    #endif
    private static let sdkConfigRefreshInterval: TimeInterval = 30

    private let userDefaults: UserDefaults
    private var remoteConfigRefresher: RemoteSDKConfigRefresher?
    private var didStartRemoteRefresh = false

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        let storedMode = userDefaults.string(forKey: Self.voiceToTextModeKey)
        let didDefaultToAppleSpeech = userDefaults.bool(forKey: Self.didDefaultToAppleSpeechKey)
        if didDefaultToAppleSpeech {
            voiceToTextMode = VoiceToTextMode(rawValue: storedMode ?? "") ?? .apple
        } else {
            voiceToTextMode = .apple
            userDefaults.set(VoiceToTextMode.apple.rawValue, forKey: Self.voiceToTextModeKey)
            userDefaults.set(true, forKey: Self.didDefaultToAppleSpeechKey)
        }
        whisperModelSize = WhisperModelSize(
            rawValue: userDefaults.string(forKey: Self.whisperModelSizeKey) ?? ""
        ) ?? .tiny
        includeSpectrogramAttachment = userDefaults.bool(forKey: Self.includeSpectrogramAttachmentKey)
        if userDefaults.bool(forKey: Self.includeWAVAttachmentInitializedKey) {
            includeWAVAttachment = userDefaults.bool(forKey: Self.includeWAVAttachmentKey)
        } else {
            includeWAVAttachment = true
            userDefaults.set(true, forKey: Self.includeWAVAttachmentKey)
            userDefaults.set(true, forKey: Self.includeWAVAttachmentInitializedKey)
        }
        audioToToolArchitecture = AudioToToolArchitecture(
            rawValue: userDefaults.string(forKey: Self.audioToToolArchitectureKey) ?? ""
        ) ?? .twoStep
        #if BENCHMARK_BUILD
        useSDKPayloadSettings = true
        userDefaults.set(true, forKey: Self.useSDKPayloadSettingsKey)
        benchmarkEnabled = true
        userDefaults.set(true, forKey: Self.benchmarkEnabledKey)
        #else
        useSDKPayloadSettings = userDefaults.bool(forKey: Self.useSDKPayloadSettingsKey)
        #endif
        sdkPayload = RemoteSDKConfigStore.shared.current
        sdkPayloadRefreshedAt = RemoteSDKConfigStore.shared.lastUpdatedAt
        #if BENCHMARK_BUILD
        if let localConfigWarning = BenchmarkConfigRuntime.localConfigStartupWarning() {
            sdkPayloadStatus = localConfigWarning
        }
        #endif
    }

    func startRemoteConfigRefresh(fetchImmediately: Bool = true) {
        guard !didStartRemoteRefresh else { return }
        didStartRemoteRefresh = true

        guard let dsn = Bundle.main.object(forInfoDictionaryKey: "WILDEDGE_DSN") as? String,
              !dsn.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            sdkPayloadStatus = "No DSN configured"
            return
        }

        do {
            let refresher = try RemoteSDKConfigRefresher(
                dsn: dsn,
                refreshEvery: Self.sdkConfigRefreshInterval
            )
            remoteConfigRefresher = refresher
            sdkPayloadStatus = "Waiting for SDK payload"

            refresher.start(
                onFetchStarted: { [weak self] in
                    Task { @MainActor in
                        self?.isRefreshingSDKPayload = true
                        self?.sdkPayloadStatus = "Refreshing SDK payload..."
                    }
                },
                onChange: { [weak self] result in
                    Task { @MainActor in
                        self?.handleRemoteConfigResult(result)
                    }
                },
                fetchImmediately: fetchImmediately
            )
        } catch {
            sdkPayloadStatus = error.localizedDescription
        }
    }

    #if BENCHMARK_BUILD
    func refreshSDKPayloadBeforeBenchmarkStart() async {
        startRemoteConfigRefresh(fetchImmediately: false)

        guard let remoteConfigRefresher else { return }

        sdkPayloadStatus = "Refreshing SDK payload before benchmark..."
        _ = await remoteConfigRefresher.refresh()
    }
    #endif

    func refreshSDKPayload() {
        guard let remoteConfigRefresher else {
            startRemoteConfigRefresh()
            return
        }

        Task {
            await remoteConfigRefresher.refresh()
        }
    }

    var sdkPayloadText: String {
        guard let sdkPayload else {
            return "No SDK payload has been downloaded yet."
        }

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(sdkPayload)
            return String(data: data, encoding: .utf8) ?? "{}"
        } catch {
            return "Could not render SDK payload: \(error.localizedDescription)"
        }
    }

    var effectiveSettings: VoiceRecorderEffectiveSettings {
        #if BENCHMARK_BUILD
        return BenchmarkConfigRuntime.resolveEffectiveSettings(
            remoteConfig: sdkPayload,
            useRemoteConfig: useSDKPayloadSettings,
            benchmarkEnabled: benchmarkEnabled,
            localVoiceToTextMode: voiceToTextMode,
            localWhisperModelSize: whisperModelSize,
            localAudioToToolArchitecture: audioToToolArchitecture,
            includeSpectrogramAttachment: includeSpectrogramAttachment,
            includeWAVAttachment: includeWAVAttachment
        ).settings
        #else
        return VoiceRecorderEffectiveSettings(
            voiceToTextMode: voiceToTextMode,
            whisperModelSize: whisperModelSize,
            audioToToolArchitecture: audioToToolArchitecture,
            includeSpectrogramAttachment: includeSpectrogramAttachment,
            includeWAVAttachment: includeWAVAttachment,
            isUsingSDKPayload: false,
            remoteConfigWarning: nil
        )
        #endif
    }

    #if BENCHMARK_BUILD
    var effectiveBenchmarkSignature: String {
        let settings = effectiveSettings
        return [
            settings.benchmarkEnabled ? "1" : "0",
            settings.voiceToTextMode.rawValue,
            settings.whisperModelSize.rawValue,
            settings.audioToToolArchitecture.rawValue,
            String(settings.benchmarkDelaySeconds),
            settings.benchmarkRecordingsMatch.joined(separator: ","),
            String(settings.benchmarkNumberOfInferences),
            settings.benchmarkSteps.map(\.rawValue).joined(separator: ","),
            settings.benchmarkStepsError ?? "",
            settings.benchmarkTextToToolModel.signature,
            settings.benchmarkSpeechToToolPrompt ?? "",
            settings.isUsingSDKPayload ? "sdk" : "local",
            settings.remoteConfigWarning ?? ""
        ].joined(separator: "|")
    }
    #endif

    var effectiveSettingsSummary: String {
        let settings = effectiveSettings
        let source = settings.remoteConfigWarning == nil
            ? (settings.isUsingSDKPayload ? "SDK payload" : "Local")
            : Self.sdkPayloadWarningSourceDescription(for: settings)
        let spectrogram = settings.includeSpectrogramAttachment ? "on" : "off"
        let wav = settings.includeWAVAttachment ? "on" : "off"
        let architecture = settings.audioToToolArchitecture.displayName
        let whisper = settings.voiceToTextMode == .whisper
            ? ", Whisper \(settings.whisperModelSize.displayName)"
            : ""
        #if BENCHMARK_BUILD
        let steps = settings.benchmarkSteps.map(\.rawValue).joined(separator: "+")
        let benchmark: String
        if settings.benchmarkEnabled && settings.remoteConfigWarning != nil {
            benchmark = ", benchmark stopped"
        } else if settings.benchmarkEnabled {
            benchmark = ", benchmark on, steps \(steps), text-to-tool \(settings.benchmarkTextToToolModel.displayName), delay \(Int(settings.benchmarkDelaySeconds))s, \(settings.benchmarkNumberOfInferences)x"
        } else {
            benchmark = ", benchmark off"
        }
        #else
        let benchmark = ""
        #endif
        let warning = settings.remoteConfigWarning.map { ", \($0)" } ?? ""
        return "\(source): \(settings.voiceToTextMode.displayName)\(whisper), audio to tool \(architecture), WAV \(wav), spectrogram \(spectrogram)\(benchmark)\(warning)"
    }

    var formattedSDKPayloadRefreshedAt: String {
        guard let sdkPayloadRefreshedAt else { return "Never" }
        return Self.dateFormatter.string(from: sdkPayloadRefreshedAt)
    }

    private func handleRemoteConfigResult(_ result: Result<RemoteSDKConfig, Error>) {
        isRefreshingSDKPayload = false

        switch result {
        case .success(let config):
            sdkPayload = config
            sdkPayloadRefreshedAt = RemoteSDKConfigStore.shared.lastUpdatedAt ?? Date()
            #if BENCHMARK_BUILD
            sdkPayloadStatus = BenchmarkConfigRuntime.statusWarning(for: config) ?? "SDK payload refreshed"
            #else
            sdkPayloadStatus = "SDK payload refreshed"
            #endif
        case .failure(let error):
            sdkPayloadStatus = error.localizedDescription
        }
    }

    private static func sdkPayloadWarningSourceDescription(for settings: VoiceRecorderEffectiveSettings) -> String {
        #if BENCHMARK_BUILD
        if settings.benchmarkEnabled {
            return "SDK payload unsupported"
        }
        #endif
        return "SDK payload fallback"
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .medium
        return formatter
    }()
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
