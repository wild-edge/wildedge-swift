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
    #endif
    let isUsingSDKPayload: Bool
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
    private static let defaultBenchmarkDelaySeconds: TimeInterval = 10
    private static let defaultBenchmarkSteps: [BenchmarkStep] = [.speechToText]
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
        useSDKPayloadSettings = userDefaults.bool(forKey: Self.useSDKPayloadSettingsKey)
        #if BENCHMARK_BUILD
        benchmarkEnabled = userDefaults.bool(forKey: Self.benchmarkEnabledKey)
        #endif
        sdkPayload = RemoteSDKConfigStore.shared.current
        sdkPayloadRefreshedAt = RemoteSDKConfigStore.shared.lastUpdatedAt
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
        let sdkPayload = sdkPayload ?? [:]
        let sdkBenchmarkEnabled = Self.benchmarkEnabled(from: sdkPayload) ?? false
        guard useSDKPayloadSettings || sdkBenchmarkEnabled else {
            return VoiceRecorderEffectiveSettings(
                voiceToTextMode: voiceToTextMode,
                whisperModelSize: whisperModelSize,
                audioToToolArchitecture: audioToToolArchitecture,
                includeSpectrogramAttachment: benchmarkEnabled ? false : includeSpectrogramAttachment,
                includeWAVAttachment: benchmarkEnabled ? false : includeWAVAttachment,
                benchmarkEnabled: benchmarkEnabled,
                benchmarkDelaySeconds: Self.defaultBenchmarkDelaySeconds,
                benchmarkRecordingsMatch: ["*"],
                benchmarkNumberOfInferences: 1,
                benchmarkSteps: Self.defaultBenchmarkSteps,
                benchmarkStepsError: nil,
                isUsingSDKPayload: false
            )
        }
        #else
        guard useSDKPayloadSettings else {
            return VoiceRecorderEffectiveSettings(
                voiceToTextMode: voiceToTextMode,
                whisperModelSize: whisperModelSize,
                audioToToolArchitecture: audioToToolArchitecture,
                includeSpectrogramAttachment: includeSpectrogramAttachment,
                includeWAVAttachment: includeWAVAttachment,
                isUsingSDKPayload: false
            )
        }
        let sdkPayload = sdkPayload ?? [:]
        #endif

        #if BENCHMARK_BUILD
        let benchmarkEnabled = useSDKPayloadSettings ? sdkBenchmarkEnabled : true
        let sdkAudioToToolArchitecture = Self.audioToToolArchitecture(from: sdkPayload)
        let benchmarkStepConfiguration = Self.benchmarkSteps(from: sdkPayload)
            ?? sdkAudioToToolArchitecture.map { (Self.benchmarkSteps(for: $0), nil) }
            ?? (Self.defaultBenchmarkSteps, nil)
        return VoiceRecorderEffectiveSettings(
            voiceToTextMode: Self.voiceToTextMode(from: sdkPayload) ?? .apple,
            whisperModelSize: Self.whisperModelSize(from: sdkPayload) ?? .tiny,
            audioToToolArchitecture: sdkAudioToToolArchitecture ?? .twoStep,
            includeSpectrogramAttachment: benchmarkEnabled ? false : Self.boolValue(
                from: sdkPayload,
                preferredKeys: [
                    "audio_spectrogram",
                    "audioSpectrogram",
                    "spectrogram",
                    "spectogram",
                    "include_spectrogram_attachment",
                    "includeSpectrogramAttachment"
                ]
            ) ?? false,
            includeWAVAttachment: benchmarkEnabled ? false : Self.boolValue(
                from: sdkPayload,
                preferredKeys: [
                    "wav",
                    "audio_wav",
                    "audioWAV",
                    "include_wav_attachment",
                    "includeWAVAttachment",
                    "includeWavAttachment"
                ]
            ) ?? true,
            benchmarkEnabled: benchmarkEnabled,
            benchmarkDelaySeconds: Self.benchmarkDelaySeconds(from: sdkPayload) ?? Self.defaultBenchmarkDelaySeconds,
            benchmarkRecordingsMatch: Self.stringArrayValue(
                from: sdkPayload,
                preferredKeys: [
                    "recordings_match",
                    "recordingsMatch",
                    "benchmark_recordings",
                    "benchmarkRecordings",
                    "recording_ids",
                    "recordingIds"
                ]
            ) ?? ["*"],
            benchmarkNumberOfInferences: Self.benchmarkNumberOfInferences(from: sdkPayload) ?? 1,
            benchmarkSteps: benchmarkStepConfiguration.0,
            benchmarkStepsError: benchmarkStepConfiguration.1,
            isUsingSDKPayload: true
        )
        #else
        return VoiceRecorderEffectiveSettings(
            voiceToTextMode: Self.voiceToTextMode(from: sdkPayload) ?? .apple,
            whisperModelSize: Self.whisperModelSize(from: sdkPayload) ?? .tiny,
            audioToToolArchitecture: Self.audioToToolArchitecture(from: sdkPayload) ?? .twoStep,
            includeSpectrogramAttachment: Self.boolValue(
                from: sdkPayload,
                preferredKeys: [
                    "audio_spectrogram",
                    "audioSpectrogram",
                    "spectrogram",
                    "spectogram",
                    "include_spectrogram_attachment",
                    "includeSpectrogramAttachment"
                ]
            ) ?? false,
            includeWAVAttachment: Self.boolValue(
                from: sdkPayload,
                preferredKeys: [
                    "wav",
                    "audio_wav",
                    "audioWAV",
                    "include_wav_attachment",
                    "includeWAVAttachment",
                    "includeWavAttachment"
                ]
            ) ?? true,
            isUsingSDKPayload: true
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
            settings.isUsingSDKPayload ? "sdk" : "local"
        ].joined(separator: "|")
    }
    #endif

    var effectiveSettingsSummary: String {
        let settings = effectiveSettings
        let source = settings.isUsingSDKPayload ? "SDK payload" : "Local"
        let spectrogram = settings.includeSpectrogramAttachment ? "on" : "off"
        let wav = settings.includeWAVAttachment ? "on" : "off"
        let architecture = settings.audioToToolArchitecture.displayName
        let whisper = settings.voiceToTextMode == .whisper
            ? ", Whisper \(settings.whisperModelSize.displayName)"
            : ""
        #if BENCHMARK_BUILD
        let steps = settings.benchmarkSteps.map(\.rawValue).joined(separator: "+")
        let benchmark = settings.benchmarkEnabled
            ? ", benchmark on, steps \(steps), delay \(Int(settings.benchmarkDelaySeconds))s, \(settings.benchmarkNumberOfInferences)x"
            : ", benchmark off"
        #else
        let benchmark = ""
        #endif
        return "\(source): \(settings.voiceToTextMode.displayName)\(whisper), audio to tool \(architecture), WAV \(wav), spectrogram \(spectrogram)\(benchmark)"
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
            sdkPayloadStatus = "SDK payload refreshed"
            if let refreshEvery = Self.sdkConfigFetchInterval(from: config) {
                remoteConfigRefresher?.updateRefreshEvery(refreshEvery)
            }
        case .failure(let error):
            sdkPayloadStatus = error.localizedDescription
        }
    }

    private static func voiceToTextMode(from config: RemoteSDKConfig) -> VoiceToTextMode? {
        guard let value = jsonValue(
            from: config,
            preferredKeys: [
                "voice_to_text_model",
                "voiceToTextModel",
                "voice_to_text",
                "voiceToText",
                "speech_to_text_model",
                "speechToTextModel",
                "model_name",
                "modelName"
            ]
        ) else {
            return nil
        }

        switch value {
        case .object(let object):
            for key in ["model", "value", "provider", "name", "type"] {
                if let nested = object[key],
                   let mode = voiceToTextMode(from: ["value": nested]) {
                    return mode
                }
            }
            return nil
        case .null:
            return .disabled
        case .string(let model):
            let normalized = model
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
                .replacingOccurrences(of: "-", with: "_")
                .replacingOccurrences(of: ".", with: "_")
                .replacingOccurrences(of: " ", with: "_")
            switch normalized {
            case "", "null", "none", "disabled", "off", "false":
                return .disabled
            case "apple", "enabled_apple", "apple_speech", "apple_speech_recognizer":
                return .apple
            case "whisper", "enabled_whisper", "whisper_tiny", "whisper_base", "openai_whisper_tiny", "openai_whisper_base":
                return .whisper
            case "leap", "enabled_leap", "leap_sdk", "leap_lfm2_5_audio_1_5b", "leap_lfm2_5_audio_1_5b_q8_0", "lfm25_audio", "lfm2_5_audio", "lfm2_5_audio_1_5b", "lfm2_5_audio_1_5b_q8_0":
                return .leap
            default:
                return nil
            }
        case .bool(let enabled):
            return enabled ? .apple : .disabled
        default:
            return nil
        }
    }

    private static func whisperModelSize(from config: RemoteSDKConfig) -> WhisperModelSize? {
        if let voiceToText = jsonValue(
            from: config,
            preferredKeys: [
                "voice_to_text_model",
                "voiceToTextModel",
                "voice_to_text",
                "voiceToText",
                "speech_to_text_model",
                "speechToTextModel",
                "model_name",
                "modelName"
            ]
        ),
           case .object(let object) = voiceToText {
            for key in ["whisper_model", "whisperModel", "model_size", "modelSize", "size", "variant"] {
                if let nested = object[key],
                   let model = whisperModelSize(from: ["value": nested]) {
                    return model
                }
            }
        }

        guard let value = jsonValue(
            from: config,
            preferredKeys: [
                "whisper_model",
                "whisperModel",
                "whisper_model_size",
                "whisperModelSize",
                "voice_to_text_model_size",
                "voiceToTextModelSize",
                "speech_to_text_model_size",
                "speechToTextModelSize",
                "model_name",
                "modelName"
            ]
        ) else {
            return nil
        }

        switch value {
        case .object(let object):
            for key in ["model", "value", "name", "type", "size", "variant"] {
                if let nested = object[key],
                   let model = whisperModelSize(from: ["value": nested]) {
                    return model
                }
            }
            return nil
        case .string(let model):
            let normalized = model
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
                .replacingOccurrences(of: "-", with: "_")
                .replacingOccurrences(of: ".", with: "_")
                .replacingOccurrences(of: " ", with: "_")
            switch normalized {
            case "tiny", "openai_whisper_tiny", "whisper_tiny":
                return .tiny
            case "base", "openai_whisper_base", "whisper_base":
                return .base
            default:
                return nil
            }
        default:
            return nil
        }
    }

    private static func audioToToolArchitecture(from config: RemoteSDKConfig) -> AudioToToolArchitecture? {
        guard let value = jsonValue(
            from: config,
            preferredKeys: [
                "audio_to_tool_architecture",
                "audioToToolArchitecture",
                "audio_to_tool",
                "audioToTool",
                "tool_architecture",
                "toolArchitecture",
                "tool_call_architecture",
                "toolCallArchitecture"
            ]
        ) else {
            return nil
        }

        switch value {
        case .object(let object):
            for key in ["architecture", "mode", "value", "name", "type"] {
                if let nested = object[key],
                   let architecture = audioToToolArchitecture(from: ["value": nested]) {
                    return architecture
                }
            }
            return nil
        case .string(let architecture):
            let normalized = architecture
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
                .replacingOccurrences(of: "-", with: "_")
                .replacingOccurrences(of: " ", with: "_")
            switch normalized {
            case "2step", "2_step", "two_step", "twostep", "transcribe_then_tool", "stt_then_tool":
                return .twoStep
            case "1step", "1_step", "one_step", "onestep", "direct_audio_to_tool", "audio_to_tool":
                return .oneStep
            default:
                return nil
            }
        case .number(let number):
            if number == 1 {
                return .oneStep
            }
            if number == 2 {
                return .twoStep
            }
            return nil
        default:
            return nil
        }
    }

    private static func sdkConfigFetchInterval(from config: RemoteSDKConfig) -> TimeInterval? {
        guard let value = jsonValue(
            from: config,
            preferredKeys: [
                "config_fetch",
                "configFetch",
                "sdk_config_fetch",
                "sdkConfigFetch",
                "config_fetch_seconds",
                "configFetchSeconds"
            ]
        ),
              let seconds = durationSeconds(from: value)
        else {
            return nil
        }
        return max(1, seconds)
    }

    private static func durationSeconds(from value: JSONValue) -> Double? {
        switch value {
        case .number(let number):
            return number
        case .string(let string):
            return durationSeconds(from: string)
        case .object(let object):
            for key in ["seconds", "value", "interval", "every", "delay_seconds", "delaySeconds", "config_fetch", "configFetch"] {
                if let nested = object[key],
                   let seconds = durationSeconds(from: nested) {
                    return seconds
                }
            }
            return nil
        default:
            return nil
        }
    }

    private static func durationSeconds(from string: String) -> Double? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let seconds = Double(trimmed) {
            return seconds
        }
        if trimmed.hasSuffix("ms") {
            let value = trimmed.dropLast(2).trimmingCharacters(in: .whitespacesAndNewlines)
            return Double(value).map { $0 / 1_000 }
        }
        for suffix in ["seconds", "second", "secs", "sec", "s"] where trimmed.hasSuffix(suffix) {
            let value = trimmed.dropLast(suffix.count).trimmingCharacters(in: .whitespacesAndNewlines)
            return Double(value)
        }
        return nil
    }

    #if BENCHMARK_BUILD
    private static func benchmarkEnabled(from config: RemoteSDKConfig) -> Bool? {
        Self.boolValue(
            from: config,
            preferredKeys: [
                "benchmark_enabled",
                "benchmarkEnabled",
                "benchmark_mode",
                "benchmarkMode",
                "bnechmark_mode",
                "bnechmarkMode",
                "benchmark",
                "stt_benchmark_enabled",
                "sttBenchmarkEnabled"
            ]
        )
    }

    private static func benchmarkDelaySeconds(from config: RemoteSDKConfig) -> TimeInterval? {
        guard let value = jsonValue(
            from: config,
            preferredKeys: [
                "benchmark_delay_seconds",
                "benchmarkDelaySeconds",
                "delay_seconds",
                "delaySeconds"
            ]
        ),
              let seconds = durationSeconds(from: value)
        else {
            return nil
        }
        return max(0, seconds)
    }

    private static func benchmarkNumberOfInferences(from config: RemoteSDKConfig) -> Int? {
        guard let value = jsonValue(
            from: config,
            preferredKeys: [
                "number_of_inferences",
                "numberOfInferences",
                "benchmark_number_of_inferences",
                "benchmarkNumberOfInferences",
                "inference_count",
                "inferenceCount",
                "runs_per_file",
                "runsPerFile"
            ]
        ),
              let count = intValue(from: value)
        else {
            return nil
        }
        return max(1, count)
    }

    private static func benchmarkSteps(from config: RemoteSDKConfig) -> ([BenchmarkStep], String?)? {
        guard let value = jsonValue(
            from: config,
            preferredKeys: [
                "benchmark_steps",
                "benchmarkSteps"
            ]
        ) else {
            return nil
        }

        let stepStrings = benchmarkStepStrings(from: value)
        guard stepStrings.error == nil else {
            return ([], stepStrings.error)
        }
        guard let rawSteps = stepStrings.steps else {
            return ([], "benchmark_steps must be a string or array of strings.")
        }
        let parsedSteps = rawSteps.compactMap(BenchmarkStep.init(remoteValue:))
        guard parsedSteps.count == rawSteps.count else {
            let unsupported = rawSteps.filter { BenchmarkStep(remoteValue: $0) == nil }
            return (parsedSteps, "Unsupported benchmark steps: \(unsupported.joined(separator: ", ")).")
        }
        guard isSupportedBenchmarkStepSequence(parsedSteps) else {
            return (parsedSteps, "Unsupported benchmark step sequence: \(rawSteps.joined(separator: ", ")).")
        }
        return (parsedSteps, nil)
    }

    private static func benchmarkStepStrings(from value: JSONValue) -> (steps: [String]?, error: String?) {
        switch value {
        case .array(let values):
            var steps: [String] = []
            for (index, value) in values.enumerated() {
                guard case .string(let rawStep) = value else {
                    return (nil, "benchmark_steps[\(index)] must be a string.")
                }
                let step = rawStep.trimmingCharacters(in: .whitespacesAndNewlines)
                guard step.isEmpty == false else {
                    return (nil, "benchmark_steps[\(index)] must not be empty.")
                }
                steps.append(step)
            }
            return (steps, nil)
        case .string(let string):
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.isEmpty == false else { return ([], nil) }
            if trimmed.contains(",") {
                let steps = trimmed
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { $0.isEmpty == false }
                return (steps, nil)
            }
            return ([trimmed], nil)
        case .object(let object):
            for key in ["values", "value", "items", "benchmark_steps", "benchmarkSteps"] {
                if let nested = object[key] {
                    return benchmarkStepStrings(from: nested)
                }
            }
            return (nil, "benchmark_steps must be a string or array of strings.")
        default:
            return (nil, "benchmark_steps must be a string or array of strings.")
        }
    }

    private static func benchmarkSteps(for architecture: AudioToToolArchitecture) -> [BenchmarkStep] {
        switch architecture {
        case .twoStep:
            return [.speechToText, .textToTool]
        case .oneStep:
            return [.speechToTool]
        }
    }

    private static func isSupportedBenchmarkStepSequence(_ steps: [BenchmarkStep]) -> Bool {
        switch steps {
        case [.speechToText], [.speechToText, .textToTool], [.speechToTool]:
            return true
        default:
            return false
        }
    }

    private static func stringArrayValue(from config: RemoteSDKConfig, preferredKeys: [String]) -> [String]? {
        guard let value = jsonValue(from: config, preferredKeys: preferredKeys) else {
            return nil
        }
        return strings(from: value)
    }

    private static func strings(from value: JSONValue) -> [String]? {
        switch value {
        case .array(let values):
            return values.compactMap { string(from: $0) }
        case .string(let string):
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return [] }
            if trimmed.contains(",") {
                return trimmed
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            }
            return [trimmed]
        case .object(let object):
            for key in ["values", "value", "items", "recordings", "recordings_match", "recordingsMatch"] {
                if let nested = object[key],
                   let values = strings(from: nested) {
                    return values
                }
            }
            return nil
        default:
            return nil
        }
    }

    private static func string(from value: JSONValue) -> String? {
        guard case .string(let string) = value else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func intValue(from value: JSONValue) -> Int? {
        switch value {
        case .number(let number):
            return Int(number)
        case .string(let string):
            return Int(string.trimmingCharacters(in: .whitespacesAndNewlines))
        case .object(let object):
            for key in ["value", "count", "number", "runs", "inferences"] {
                if let nested = object[key],
                   let int = intValue(from: nested) {
                    return int
                }
            }
            return nil
        default:
            return nil
        }
    }

    #endif

    private static func boolValue(from config: RemoteSDKConfig, preferredKeys: [String]) -> Bool? {
        guard let value = jsonValue(from: config, preferredKeys: preferredKeys) else {
            return nil
        }

        switch value {
        case .bool(let bool):
            return bool
        case .number(let number):
            return number != 0
        case .string(let string):
            switch string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true", "1", "yes", "on", "enabled":
                return true
            case "false", "0", "no", "off", "disabled", "null", "none":
                return false
            default:
                return nil
            }
        case .object(let object):
            for key in ["enabled", "value", "on", "include", "send"] {
                if let nested = object[key],
                   let bool = boolValue(from: ["value": nested], preferredKeys: ["value"]) {
                    return bool
                }
            }
            return nil
        case .null:
            return false
        default:
            return nil
        }
    }

    private static func jsonValue(from config: RemoteSDKConfig, preferredKeys: [String]) -> JSONValue? {
        let normalizedKeys = Set(preferredKeys.map(normalizeKey))
        return findValue(in: .object(config), matching: normalizedKeys)
    }

    private static func findValue(in value: JSONValue, matching normalizedKeys: Set<String>) -> JSONValue? {
        switch value {
        case .object(let object):
            for (key, candidate) in object where normalizedKeys.contains(normalizeKey(key)) {
                return candidate
            }
            for descriptorKey in ["key", "name", "type", "id", "setting"] {
                if let descriptor = object[descriptorKey]?.stringValue,
                   normalizedKeys.contains(normalizeKey(descriptor)) {
                    return object["enabled"]
                        ?? object["value"]
                        ?? object["on"]
                        ?? object["include"]
                        ?? object["send"]
                        ?? value
                }
            }
            for candidate in object.values {
                if let found = findValue(in: candidate, matching: normalizedKeys) {
                    return found
                }
            }
            return nil
        case .array(let array):
            for candidate in array {
                if let found = findValue(in: candidate, matching: normalizedKeys) {
                    return found
                }
            }
            return nil
        default:
            return nil
        }
    }

    private static func normalizeKey(_ key: String) -> String {
        key
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .medium
        return formatter
    }()
}
