import Foundation
import Network
import WildEdge

typealias RemoteSDKConfig = [String: JSONValue]

enum JSONValue: Codable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            throw DecodingError.typeMismatch(
                JSONValue.self,
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Unsupported JSON value")
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()

        switch self {
        case .string(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }

    var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    var intValue: Int? {
        guard case .number(let value) = self else { return nil }
        return Int(value)
    }

    var boolValue: Bool? {
        guard case .bool(let value) = self else { return nil }
        return value
    }

    var objectValue: [String: JSONValue]? {
        guard case .object(let value) = self else { return nil }
        return value
    }
}

private struct RemoteSDKConfigResponse: Decodable {
    let config: RemoteSDKConfig

    init(from decoder: Decoder) throws {
        let rawObject = try RemoteSDKConfig(from: decoder)
        if let wrappedConfig = rawObject["config"]?.objectValue {
            config = wrappedConfig
            return
        }

        config = rawObject
    }
}

private actor RemoteSDKConfigRefreshGate {
    private var isRefreshing = false

    func begin() -> Bool {
        guard !isRefreshing else { return false }
        isRefreshing = true
        return true
    }

    func end() {
        isRefreshing = false
    }
}

final class RemoteSDKConfigStore {
    static let shared = RemoteSDKConfigStore()

    private let lock = NSLock()
    private var storedConfig: RemoteSDKConfig?
    private var storedAt: Date?

    var current: RemoteSDKConfig? {
        lock.lock()
        defer { lock.unlock() }
        return storedConfig
    }

    var lastUpdatedAt: Date? {
        lock.lock()
        defer { lock.unlock() }
        return storedAt
    }

    func replace(with config: RemoteSDKConfig) {
        lock.lock()
        storedConfig = config
        storedAt = Date()
        lock.unlock()
    }
}

final class RemoteSDKConfigRefresher {
    enum ConfigError: LocalizedError {
        case invalidDsn
        case missingProjectId
        case invalidConfigURL
        case badStatus(Int)

        var errorDescription: String? {
            switch self {
            case .invalidDsn:
                return "Invalid WILDEDGE_DSN"
            case .missingProjectId:
                return "WILDEDGE_DSN must include the project id as the path"
            case .invalidConfigURL:
                return "Could not build remote SDK config URL"
            case .badStatus(let statusCode):
                return "Remote SDK config request failed with HTTP \(statusCode)"
            }
        }
    }

    let endpointURL: URL

    private var refreshEvery: TimeInterval
    private let store: RemoteSDKConfigStore
    private let session: URLSession
    private let monitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "dev.wildedge.sample.remote-sdk-config")
    private var refreshTask: Task<Void, Never>?
    private var onFetchStarted: (() -> Void)?
    private var onChange: ((Result<RemoteSDKConfig, Swift.Error>) -> Void)?
    private let refreshGate = RemoteSDKConfigRefreshGate()

    init(
        dsn: String,
        refreshEvery: TimeInterval,
        store: RemoteSDKConfigStore = .shared,
        session: URLSession = .shared
    ) throws {
        self.endpointURL = try Self.makeConfigURL(fromDSN: dsn)
        self.refreshEvery = refreshEvery
        self.store = store
        self.session = session
    }

    func start(
        onFetchStarted: (() -> Void)? = nil,
        onChange: @escaping (Result<RemoteSDKConfig, Swift.Error>) -> Void,
        fetchImmediately: Bool = true
    ) {
        self.onFetchStarted = onFetchStarted
        self.onChange = onChange
        monitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            Task { await self?.refresh() }
        }
        monitor.start(queue: monitorQueue)
        startRefreshLoop()
        if fetchImmediately {
            Task { await refresh() }
        }
    }

    func stop() {
        monitor.cancel()
        refreshTask?.cancel()
        refreshTask = nil
    }

    func updateRefreshEvery(_ refreshEvery: TimeInterval) {
        guard self.refreshEvery != refreshEvery else { return }
        self.refreshEvery = refreshEvery
        startRefreshLoop()
    }

    deinit {
        stop()
    }

    @discardableResult
    func refresh() async -> RemoteSDKConfig? {
        guard await refreshGate.begin() else { return nil }

        do {
            onFetchStarted?()
            let request = URLRequest(url: endpointURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
            let (data, response) = try await session.data(for: request)
            if let httpResponse = response as? HTTPURLResponse, !(200..<300).contains(httpResponse.statusCode) {
                throw ConfigError.badStatus(httpResponse.statusCode)
            }

            let decoder = JSONDecoder()
            let config = try decoder.decode(RemoteSDKConfigResponse.self, from: data).config
            store.replace(with: config)
            onChange?(.success(config))
            await refreshGate.end()
            return config
        } catch {
            onChange?(.failure(error))
            await refreshGate.end()
            return nil
        }
    }

    private func startRefreshLoop() {
        refreshTask?.cancel()
        guard refreshEvery > 0 else { return }

        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let delay = UInt64(max(self.refreshEvery, 1) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: delay)
                guard !Task.isCancelled else { return }
                await self.refresh()
            }
        }
    }

    private static func makeConfigURL(fromDSN dsn: String) throws -> URL {
        guard
            var components = URLComponents(string: dsn),
            let scheme = components.scheme,
            let host = components.host,
            !scheme.isEmpty,
            !host.isEmpty
        else {
            throw ConfigError.invalidDsn
        }

        let projectId = components.path
            .split(separator: "/")
            .last
            .map(String.init)

        guard let projectId, !projectId.isEmpty else {
            throw ConfigError.missingProjectId
        }

        components.user = nil
        components.password = nil
        components.host = appHost(fromIngestHost: host)
        components.path = "/api/sdk-configs/\(projectId)"
        components.query = nil
        components.fragment = nil

        guard let url = components.url else {
            throw ConfigError.invalidConfigURL
        }
        return url
    }

    private static func appHost(fromIngestHost host: String) -> String {
        if host == "ingest.wildedge.dev" {
            return "app.wildedge.dev"
        }

        if host.hasPrefix("ingest.") {
            return "app." + String(host.dropFirst("ingest.".count))
        }

        return host
    }
}

#if BENCHMARK_BUILD
enum BenchmarkConfigError: LocalizedError, Equatable {
    case decoding(String)
    case remoteForbiddenSection(String)
    case remoteUnknownSection(String)
    case missingLocalSection(String)
    case missingBenchmarkParams
    case missingStep(String)
    case stepMissingModel(String)
    case missingModel(String)
    case disabledModel(String)
    case invalidStepChain(String)
    case unsupportedSourceScheme(String)
    case unsupportedLoader(String)
    case incompatibleSourceAndLoader(source: String, loader: String)
    case remoteRevisionNotPinned(String)
    case checksumRequired(String)
    case memoryPolicyExceeded(String)

    var errorDescription: String? {
        switch self {
        case .decoding(let message):
            return "Benchmark config could not be decoded: \(message)"
        case .remoteForbiddenSection(let section):
            return "Remote SDK config may not override \(section)."
        case .remoteUnknownSection(let section):
            return "Remote SDK config contains unsupported section \(section)."
        case .missingLocalSection(let section):
            return "Local benchmark config is missing \(section)."
        case .missingBenchmarkParams:
            return "Benchmark config is missing benchmark_params."
        case .missingStep(let step):
            return "Benchmark step \(step) is not defined."
        case .stepMissingModel(let step):
            return "Benchmark step \(step) does not reference model_name."
        case .missingModel(let model):
            return "Benchmark model \(model) is not defined."
        case .disabledModel(let model):
            return "Benchmark model \(model) is disabled."
        case .invalidStepChain(let message):
            return message
        case .unsupportedSourceScheme(let scheme):
            return "Model source scheme \(scheme) is not supported."
        case .unsupportedLoader(let loader):
            return "Model loader \(loader) is not supported."
        case .incompatibleSourceAndLoader(let source, let loader):
            return "Model source \(source) is not compatible with loader \(loader)."
        case .remoteRevisionNotPinned(let source):
            return "Remote model source must pin a revision: \(source)."
        case .checksumRequired(let model):
            return "Remote model \(model) must include a checksum."
        case .memoryPolicyExceeded(let message):
            return message
        }
    }
}

struct BenchmarkConfigResolution {
    let settings: VoiceRecorderEffectiveSettings
    let statusWarning: String?
}

struct BenchmarkConfigRuntime {
    static func resolveEffectiveSettings(
        remoteConfig: RemoteSDKConfig?,
        useRemoteConfig: Bool,
        benchmarkEnabled: Bool,
        localVoiceToTextMode: VoiceToTextMode,
        localWhisperModelSize: WhisperModelSize,
        localAudioToToolArchitecture: AudioToToolArchitecture,
        includeSpectrogramAttachment: Bool,
        includeWAVAttachment: Bool
    ) -> BenchmarkConfigResolution {
        guard benchmarkEnabled else {
            return BenchmarkConfigResolution(
                settings: VoiceRecorderEffectiveSettings(
                    voiceToTextMode: localVoiceToTextMode,
                    whisperModelSize: localWhisperModelSize,
                    audioToToolArchitecture: localAudioToToolArchitecture,
                    includeSpectrogramAttachment: includeSpectrogramAttachment,
                    includeWAVAttachment: includeWAVAttachment,
                    benchmarkEnabled: false,
                    benchmarkDelaySeconds: 10,
                    benchmarkRecordingsMatch: ["*"],
                    benchmarkNumberOfInferences: 1,
                    benchmarkSteps: [.speechToText],
                    benchmarkStepsError: nil,
                    benchmarkTextToToolModel: .default,
                    benchmarkSpeechToToolPrompt: nil,
                    isUsingSDKPayload: false,
                    remoteConfigWarning: nil
                ),
                statusWarning: nil
            )
        }

        let localConfig: BenchmarkAppConfig
        do {
            localConfig = try BenchmarkAppConfig.localDefault()
            try BenchmarkConfigValidator.validateLocalShape(localConfig)
            try BenchmarkConfigValidator.validateEffectiveConfig(localConfig, remoteModelNames: [])
        } catch {
            let message = error.localizedDescription
            return BenchmarkConfigResolution(
                settings: VoiceRecorderEffectiveSettings(
                    voiceToTextMode: .disabled,
                    whisperModelSize: .tiny,
                    audioToToolArchitecture: .twoStep,
                    includeSpectrogramAttachment: false,
                    includeWAVAttachment: false,
                    benchmarkEnabled: true,
                    benchmarkDelaySeconds: 10,
                    benchmarkRecordingsMatch: ["*"],
                    benchmarkNumberOfInferences: 1,
                    benchmarkSteps: [],
                    benchmarkStepsError: nil,
                    benchmarkTextToToolModel: .default,
                    benchmarkSpeechToToolPrompt: nil,
                    isUsingSDKPayload: false,
                    remoteConfigWarning: "Local benchmark config is invalid: \(message)"
                ),
                statusWarning: "Local benchmark config is invalid: \(message)"
            )
        }

        var effectiveConfig = localConfig
        var statusWarning: String?
        var isUsingRemote = false
        var remoteModelNames = Set<String>()

        if useRemoteConfig, let remoteConfig {
            do {
                let overlay = try BenchmarkRemoteOverlay.decode(from: remoteConfig)
                remoteModelNames = Set(overlay.modelDefinitions?.keys.map { $0 } ?? [])
                effectiveConfig = localConfig.merging(overlay)
                try BenchmarkConfigValidator.validateEffectiveConfig(
                    effectiveConfig,
                    remoteModelNames: remoteModelNames
                )
                isUsingRemote = true
            } catch {
                statusWarning = "SDK payload invalid: \(error.localizedDescription) Using local benchmark config."
                effectiveConfig = localConfig
                remoteModelNames = []
            }
        }

        let resolved: ResolvedBenchmarkConfig
        do {
            resolved = try BenchmarkConfigValidator.resolve(
                effectiveConfig,
                remoteModelNames: remoteModelNames
            )
        } catch {
            return BenchmarkConfigResolution(
                settings: VoiceRecorderEffectiveSettings(
                    voiceToTextMode: .disabled,
                    whisperModelSize: .tiny,
                    audioToToolArchitecture: .twoStep,
                    includeSpectrogramAttachment: false,
                    includeWAVAttachment: false,
                    benchmarkEnabled: true,
                    benchmarkDelaySeconds: max(effectiveConfig.benchmarkParams?.delaySeconds ?? 10, 0),
                    benchmarkRecordingsMatch: effectiveConfig.benchmarkParams?.recordingsMatchArray ?? ["*"],
                    benchmarkNumberOfInferences: max(effectiveConfig.benchmarkParams?.numberOfInferences ?? 1, 1),
                    benchmarkSteps: effectiveConfig.benchmarkParams?.benchmarkSteps.compactMap(BenchmarkStep.init(remoteValue:)) ?? [],
                    benchmarkStepsError: nil,
                    benchmarkTextToToolModel: .default,
                    benchmarkSpeechToToolPrompt: nil,
                    isUsingSDKPayload: isUsingRemote,
                    remoteConfigWarning: "Benchmark config is invalid: \(error.localizedDescription)"
                ),
                statusWarning: "Benchmark config is invalid: \(error.localizedDescription)"
            )
        }

        return BenchmarkConfigResolution(
            settings: VoiceRecorderEffectiveSettings(
                voiceToTextMode: resolved.voiceToTextMode,
                whisperModelSize: resolved.whisperModelSize,
                audioToToolArchitecture: resolved.audioToToolArchitecture,
                includeSpectrogramAttachment: false,
                includeWAVAttachment: false,
                benchmarkEnabled: true,
                benchmarkDelaySeconds: resolved.params.delaySeconds ?? 10,
                benchmarkRecordingsMatch: resolved.params.recordingsMatchArray,
                benchmarkNumberOfInferences: max(resolved.params.numberOfInferences ?? 1, 1),
                benchmarkSteps: resolved.steps,
                benchmarkStepsError: nil,
                benchmarkTextToToolModel: resolved.textToToolModel ?? .default,
                benchmarkSpeechToToolPrompt: resolved.speechToToolPrompt,
                isUsingSDKPayload: isUsingRemote,
                remoteConfigWarning: nil
            ),
            statusWarning: statusWarning
        )
    }

    static func statusWarning(for remoteConfig: RemoteSDKConfig) -> String? {
        do {
            let local = try BenchmarkAppConfig.localDefault()
            try BenchmarkConfigValidator.validateLocalShape(local)
            let overlay = try BenchmarkRemoteOverlay.decode(from: remoteConfig)
            let merged = local.merging(overlay)
            try BenchmarkConfigValidator.validateEffectiveConfig(
                merged,
                remoteModelNames: Set(overlay.modelDefinitions?.keys.map { $0 } ?? [])
            )
            _ = try BenchmarkConfigValidator.resolve(
                merged,
                remoteModelNames: Set(overlay.modelDefinitions?.keys.map { $0 } ?? [])
            )
            return nil
        } catch {
            return "SDK payload invalid: \(error.localizedDescription) Using local benchmark config."
        }
    }

    static func localConfigStartupWarning() -> String? {
        do {
            let local = try BenchmarkAppConfig.localDefault()
            try BenchmarkConfigValidator.validateLocalShape(local)
            _ = try BenchmarkConfigValidator.resolve(local, remoteModelNames: [])
            return nil
        } catch {
            return "Local benchmark config is invalid: \(error.localizedDescription)"
        }
    }
}

struct BenchmarkAppConfig: Codable, Equatable {
    var configVersion: Int
    var appSettings: BenchmarkAppSettings?
    var sdkSettings: BenchmarkSDKSettings?
    var benchmarkParams: BenchmarkParams?
    var stepDefinitions: [String: BenchmarkStepDefinition]
    var modelDefinitions: [String: BenchmarkModelDefinition]
    var capabilities: BenchmarkCapabilities?
    var downloadPolicy: BenchmarkDownloadPolicy?
    var securityPolicy: BenchmarkSecurityPolicy?
    var memoryPolicy: BenchmarkMemoryPolicy?
    var fallbacks: BenchmarkFallbacks?

    enum CodingKeys: String, CodingKey {
        case configVersion = "config_version"
        case appSettings = "app_settings"
        case sdkSettings = "sdk_settings"
        case benchmarkParams = "benchmark_params"
        case stepDefinitions = "step_definitions"
        case modelDefinitions = "model_definitions"
        case capabilities
        case downloadPolicy = "download_policy"
        case securityPolicy = "security_policy"
        case memoryPolicy = "memory_policy"
        case fallbacks
    }

    func merging(_ overlay: BenchmarkRemoteOverlay) -> BenchmarkAppConfig {
        var merged = self
        if let params = overlay.benchmarkParams {
            merged.benchmarkParams = (merged.benchmarkParams ?? BenchmarkParams()).merging(params)
        }
        if let steps = overlay.stepDefinitions {
            for (name, step) in steps {
                merged.stepDefinitions[name] = (merged.stepDefinitions[name] ?? BenchmarkStepDefinition()).merging(step)
            }
        }
        if let models = overlay.modelDefinitions {
            for (name, model) in models {
                merged.modelDefinitions[name] = (merged.modelDefinitions[name] ?? BenchmarkModelDefinition()).merging(model)
            }
        }
        return merged
    }

    static func localDefault() throws -> BenchmarkAppConfig {
        let data = Data(Self.localDefaultJSON.utf8)
        do {
            return try JSONDecoder().decode(BenchmarkAppConfig.self, from: data)
        } catch {
            throw BenchmarkConfigError.decoding(error.localizedDescription)
        }
    }

    private static let localDefaultJSON = """
    {
      "config_version": 1,
      "app_settings": {
        "benchmark_mode_supported": true,
        "remote_config_enabled": true,
        "remote_model_loading_enabled": true
      },
      "sdk_settings": {
        "config_fetch": "30s"
      },
      "benchmark_params": {
        "benchmark_steps": ["speech_to_text", "text_to_tool"],
        "delay_seconds": 10,
        "number_of_inferences": 10,
        "recordings_match": "*"
      },
      "step_definitions": {
        "speech_to_text": {
          "input_type": "audio",
          "output_type": "text",
          "model_name": "whisper-tiny"
        },
        "text_to_tool": {
          "input_type": "text",
          "output_type": "json",
          "model_name": "qwen3-4b-4bit"
        },
        "speech_to_tool": {
          "input_type": "audio",
          "output_type": "json",
          "model_name": "leap-lfm2.5-audio-1.5b"
        }
      },
      "model_definitions": {
        "whisper-tiny": {
          "enabled": true,
          "source": "bundle://Models/whisper-tiny",
          "loader": "whisper",
          "memory_estimate_mb": 768
        },
        "qwen3-4b-4bit": {
          "enabled": true,
          "source": "hf://Qwen/Qwen3-4B-GGUF/Qwen3-4B-Q4_K_M.gguf@main",
          "loader": "llama.cpp",
          "inference": {
            "temperature": 0,
            "max_tokens": 512
          },
          "memory_estimate_mb": 3500
        },
        "leap-lfm2.5-audio-1.5b": {
          "enabled": false,
          "source": "bundle://Models/leap-lfm2.5-audio-1.5b/model.mlpackage",
          "loader": "coreml",
          "memory_estimate_mb": 2200
        }
      },
      "capabilities": {
        "supported_sources": ["bundle", "hf"],
        "supported_loaders": ["whisper", "llama.cpp", "coreml", "onnx"]
      },
      "download_policy": {
        "allow_cellular_download": false,
        "max_model_size_mb": 4096,
        "cache_directory": "ApplicationSupport/Models",
        "min_free_disk_space_mb": 1024
      },
      "security_policy": {
        "allow_arbitrary_code_execution": false,
        "allow_dynamic_imports": false,
        "allow_package_installation": false,
        "verify_checksum_for_remote_models": false
      },
      "memory_policy": {
        "max_model_memory_mb": 6144,
        "safety_margin_mb": 768,
        "default_model_file_size_mb": 1024,
        "loader_overhead_ratio": 0.25,
        "loader_overhead_min_mb": 256,
        "temporary_buffer_mb": 256,
        "kv_cache_mb_per_1k_tokens": 128
      },
      "fallbacks": {
        "on_remote_config_invalid": "use_local_config",
        "on_model_download_failed": "skip_benchmark",
        "on_model_load_failed": "skip_step"
      }
    }
    """
}

struct BenchmarkRemoteOverlay: Codable, Equatable {
    var configVersion: Int?
    var benchmarkParams: BenchmarkParams?
    var stepDefinitions: [String: BenchmarkStepDefinition]?
    var modelDefinitions: [String: BenchmarkModelDefinition]?

    enum CodingKeys: String, CodingKey {
        case configVersion = "config_version"
        case benchmarkParams = "benchmark_params"
        case stepDefinitions = "step_definitions"
        case modelDefinitions = "model_definitions"
    }

    static func decode(from rawConfig: RemoteSDKConfig) throws -> BenchmarkRemoteOverlay {
        let allowed = Set(["config_version", "benchmark_params", "step_definitions", "model_definitions"])
        let forbidden = Set([
            "capabilities",
            "security_policy",
            "download_policy",
            "memory_policy",
            "fallbacks",
            "app_settings",
            "sdk_settings"
        ])
        for key in rawConfig.keys {
            if forbidden.contains(key) {
                throw BenchmarkConfigError.remoteForbiddenSection(key)
            }
            if allowed.contains(key) == false {
                throw BenchmarkConfigError.remoteUnknownSection(key)
            }
        }

        do {
            let data = try JSONEncoder().encode(rawConfig)
            return try JSONDecoder().decode(BenchmarkRemoteOverlay.self, from: data)
        } catch let error as BenchmarkConfigError {
            throw error
        } catch {
            throw BenchmarkConfigError.decoding(error.localizedDescription)
        }
    }
}

struct BenchmarkAppSettings: Codable, Equatable {
    var benchmarkModeSupported: Bool?
    var remoteConfigEnabled: Bool?
    var remoteModelLoadingEnabled: Bool?

    enum CodingKeys: String, CodingKey {
        case benchmarkModeSupported = "benchmark_mode_supported"
        case remoteConfigEnabled = "remote_config_enabled"
        case remoteModelLoadingEnabled = "remote_model_loading_enabled"
    }
}

struct BenchmarkSDKSettings: Codable, Equatable {
    var configFetch: String?

    enum CodingKeys: String, CodingKey {
        case configFetch = "config_fetch"
    }
}

struct BenchmarkParams: Codable, Equatable {
    var benchmarkSteps: [String] = []
    var delaySeconds: Double?
    var numberOfInferences: Int?
    var recordingsMatch: BenchmarkStringList?

    enum CodingKeys: String, CodingKey {
        case benchmarkSteps = "benchmark_steps"
        case delaySeconds = "delay_seconds"
        case numberOfInferences = "number_of_inferences"
        case recordingsMatch = "recordings_match"
    }

    init(
        benchmarkSteps: [String] = [],
        delaySeconds: Double? = nil,
        numberOfInferences: Int? = nil,
        recordingsMatch: BenchmarkStringList? = nil
    ) {
        self.benchmarkSteps = benchmarkSteps
        self.delaySeconds = delaySeconds
        self.numberOfInferences = numberOfInferences
        self.recordingsMatch = recordingsMatch
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        benchmarkSteps = try container.decodeIfPresent([String].self, forKey: .benchmarkSteps) ?? []
        delaySeconds = try container.decodeIfPresent(Double.self, forKey: .delaySeconds)
        numberOfInferences = try container.decodeIfPresent(Int.self, forKey: .numberOfInferences)
        recordingsMatch = try container.decodeIfPresent(BenchmarkStringList.self, forKey: .recordingsMatch)
    }

    var recordingsMatchArray: [String] {
        recordingsMatch?.values ?? ["*"]
    }

    func merging(_ overlay: BenchmarkParams) -> BenchmarkParams {
        var merged = self
        if overlay.benchmarkSteps.isEmpty == false {
            merged.benchmarkSteps = overlay.benchmarkSteps
        }
        if overlay.delaySeconds != nil {
            merged.delaySeconds = overlay.delaySeconds
        }
        if overlay.numberOfInferences != nil {
            merged.numberOfInferences = overlay.numberOfInferences
        }
        if overlay.recordingsMatch != nil {
            merged.recordingsMatch = overlay.recordingsMatch
        }
        return merged
    }
}

struct BenchmarkStepDefinition: Codable, Equatable {
    var inputType: String?
    var outputType: String?
    var modelName: String?

    enum CodingKeys: String, CodingKey {
        case inputType = "input_type"
        case outputType = "output_type"
        case modelName = "model_name"
    }

    init(inputType: String? = nil, outputType: String? = nil, modelName: String? = nil) {
        self.inputType = inputType
        self.outputType = outputType
        self.modelName = modelName
    }

    func merging(_ overlay: BenchmarkStepDefinition) -> BenchmarkStepDefinition {
        BenchmarkStepDefinition(
            inputType: overlay.inputType ?? inputType,
            outputType: overlay.outputType ?? outputType,
            modelName: overlay.modelName ?? modelName
        )
    }
}

struct BenchmarkModelDefinition: Codable, Equatable {
    var enabled: Bool?
    var source: BenchmarkSourceConfig?
    var loader: BenchmarkLoaderConfig?
    var inference: [String: JSONValue]?
    var sha256: String?
    var memoryEstimateMB: Int?

    enum CodingKeys: String, CodingKey {
        case enabled
        case source
        case loader
        case inference
        case sha256
        case memoryEstimateMB = "memory_estimate_mb"
    }

    init(
        enabled: Bool? = nil,
        source: BenchmarkSourceConfig? = nil,
        loader: BenchmarkLoaderConfig? = nil,
        inference: [String: JSONValue]? = nil,
        sha256: String? = nil,
        memoryEstimateMB: Int? = nil
    ) {
        self.enabled = enabled
        self.source = source
        self.loader = loader
        self.inference = inference
        self.sha256 = sha256
        self.memoryEstimateMB = memoryEstimateMB
    }

    func merging(_ overlay: BenchmarkModelDefinition) -> BenchmarkModelDefinition {
        BenchmarkModelDefinition(
            enabled: overlay.enabled ?? enabled,
            source: overlay.source ?? source,
            loader: overlay.loader ?? loader,
            inference: overlay.inference ?? inference,
            sha256: overlay.sha256 ?? sha256,
            memoryEstimateMB: overlay.memoryEstimateMB ?? memoryEstimateMB
        )
    }
}

enum BenchmarkSourceConfig: Codable, Equatable {
    case compact(String)
    case expanded(BenchmarkExpandedSource)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            self = .compact(string)
            return
        }
        self = .expanded(try container.decode(BenchmarkExpandedSource.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .compact(let string):
            try container.encode(string)
        case .expanded(let source):
            try container.encode(source)
        }
    }

    var rawDescription: String {
        switch self {
        case .compact(let string):
            return string
        case .expanded(let source):
            if source.type == "huggingface" || source.type == "hf" {
                let file = source.filename.map { "/\($0)" } ?? ""
                let revision = source.revision.map { "@\($0)" } ?? ""
                return "hf://\(source.repoID ?? "")\(file)\(revision)"
            }
            return "\(source.type ?? "unknown")://\(source.filename ?? source.repoID ?? "")"
        }
    }
}

struct BenchmarkExpandedSource: Codable, Equatable {
    var type: String?
    var repoID: String?
    var filename: String?
    var revision: String?
    var sha256: String?

    enum CodingKeys: String, CodingKey {
        case type
        case repoID = "repo_id"
        case filename
        case revision
        case sha256
    }
}

enum BenchmarkLoaderConfig: Codable, Equatable {
    case compact(String)
    case expanded(BenchmarkExpandedLoader)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            self = .compact(string)
            return
        }
        self = .expanded(try container.decode(BenchmarkExpandedLoader.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .compact(let string):
            try container.encode(string)
        case .expanded(let loader):
            try container.encode(loader)
        }
    }

    var type: String? {
        switch self {
        case .compact(let string):
            return string
        case .expanded(let loader):
            return loader.type
        }
    }
}

struct BenchmarkExpandedLoader: Codable, Equatable {
    var type: String?
    var nCtx: Int?
    var nGPULayers: Int?

    enum CodingKeys: String, CodingKey {
        case type
        case nCtx = "n_ctx"
        case nGPULayers = "n_gpu_layers"
    }
}

struct BenchmarkCapabilities: Codable, Equatable {
    var supportedSources: [String]
    var supportedLoaders: [String]

    enum CodingKeys: String, CodingKey {
        case supportedSources = "supported_sources"
        case supportedLoaders = "supported_loaders"
    }
}

struct BenchmarkDownloadPolicy: Codable, Equatable {
    var allowCellularDownload: Bool?
    var maxModelSizeMB: Int?
    var cacheDirectory: String?
    var minFreeDiskSpaceMB: Int?

    enum CodingKeys: String, CodingKey {
        case allowCellularDownload = "allow_cellular_download"
        case maxModelSizeMB = "max_model_size_mb"
        case cacheDirectory = "cache_directory"
        case minFreeDiskSpaceMB = "min_free_disk_space_mb"
    }
}

struct BenchmarkSecurityPolicy: Codable, Equatable {
    var allowArbitraryCodeExecution: Bool?
    var allowDynamicImports: Bool?
    var allowPackageInstallation: Bool?
    var verifyChecksumForRemoteModels: Bool?

    enum CodingKeys: String, CodingKey {
        case allowArbitraryCodeExecution = "allow_arbitrary_code_execution"
        case allowDynamicImports = "allow_dynamic_imports"
        case allowPackageInstallation = "allow_package_installation"
        case verifyChecksumForRemoteModels = "verify_checksum_for_remote_models"
    }
}

struct BenchmarkMemoryPolicy: Codable, Equatable {
    var maxModelMemoryMB: Int
    var safetyMarginMB: Int
    var defaultModelFileSizeMB: Int
    var loaderOverheadRatio: Double
    var loaderOverheadMinMB: Int
    var temporaryBufferMB: Int
    var kvCacheMBPer1KTokens: Int

    enum CodingKeys: String, CodingKey {
        case maxModelMemoryMB = "max_model_memory_mb"
        case safetyMarginMB = "safety_margin_mb"
        case defaultModelFileSizeMB = "default_model_file_size_mb"
        case loaderOverheadRatio = "loader_overhead_ratio"
        case loaderOverheadMinMB = "loader_overhead_min_mb"
        case temporaryBufferMB = "temporary_buffer_mb"
        case kvCacheMBPer1KTokens = "kv_cache_mb_per_1k_tokens"
    }
}

struct BenchmarkFallbacks: Codable, Equatable {
    var onRemoteConfigInvalid: String?
    var onModelDownloadFailed: String?
    var onModelLoadFailed: String?

    enum CodingKeys: String, CodingKey {
        case onRemoteConfigInvalid = "on_remote_config_invalid"
        case onModelDownloadFailed = "on_model_download_failed"
        case onModelLoadFailed = "on_model_load_failed"
    }
}

struct BenchmarkStringList: Codable, Equatable {
    let values: [String]

    init(_ values: [String]) {
        self.values = values
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.contains(",") {
                values = trimmed
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { $0.isEmpty == false }
            } else {
                values = trimmed.isEmpty ? [] : [trimmed]
            }
            return
        }
        values = try container.decode([String].self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(values)
    }
}

struct ResolvedBenchmarkConfig {
    let params: BenchmarkParams
    let steps: [BenchmarkStep]
    let voiceToTextMode: VoiceToTextMode
    let whisperModelSize: WhisperModelSize
    let audioToToolArchitecture: AudioToToolArchitecture
    let textToToolModel: BenchmarkTextToToolModel?
    let speechToToolPrompt: String?
}

struct ParsedBenchmarkSource {
    let scheme: String
    let raw: String
    let path: String
    let repoID: String?
    let filename: String?
    let revision: String?
    let sha256: String?

    var pathExtension: String? {
        guard let filename else {
            return URL(fileURLWithPath: path).pathExtension.nilIfEmpty
        }
        return URL(fileURLWithPath: filename).pathExtension.nilIfEmpty
    }

    var isRemote: Bool {
        scheme == "hf"
    }

    var huggingFaceDownloadURL: String? {
        guard scheme == "hf",
              let repoID,
              let filename,
              let revision
        else {
            return nil
        }
        return "https://huggingface.co/\(repoID)/resolve/\(revision)/\(filename)"
    }
}

enum BenchmarkSourceParser {
    static func parse(_ source: BenchmarkSourceConfig) throws -> ParsedBenchmarkSource {
        switch source {
        case .compact(let raw):
            return try parseCompact(raw)
        case .expanded(let expanded):
            return try parseExpanded(expanded)
        }
    }

    private static func parseCompact(_ raw: String) throws -> ParsedBenchmarkSource {
        guard let components = URLComponents(string: raw),
              let scheme = components.scheme?.lowercased()
        else {
            throw BenchmarkConfigError.unsupportedSourceScheme(raw)
        }

        switch scheme {
        case "bundle":
            let host = components.host ?? ""
            let path = (host + components.path).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return ParsedBenchmarkSource(
                scheme: scheme,
                raw: raw,
                path: path,
                repoID: nil,
                filename: URL(fileURLWithPath: path).lastPathComponent.nilIfEmpty,
                revision: nil,
                sha256: nil
            )
        case "hf":
            let host = components.host ?? ""
            let parts = components.path
                .split(separator: "/", omittingEmptySubsequences: true)
                .map(String.init)
            guard host.isEmpty == false, parts.isEmpty == false else {
                throw BenchmarkConfigError.unsupportedSourceScheme(raw)
            }
            let repoID = "\(host)/\(parts[0])"
            let filename = parts.dropFirst().joined(separator: "/").nilIfEmpty
            let revision = revisionSuffix(in: raw)
            return ParsedBenchmarkSource(
                scheme: scheme,
                raw: raw,
                path: parts.joined(separator: "/"),
                repoID: repoID,
                filename: filename,
                revision: revision,
                sha256: nil
            )
        default:
            return ParsedBenchmarkSource(
                scheme: scheme,
                raw: raw,
                path: components.path,
                repoID: nil,
                filename: nil,
                revision: nil,
                sha256: nil
            )
        }
    }

    private static func parseExpanded(_ expanded: BenchmarkExpandedSource) throws -> ParsedBenchmarkSource {
        let type = (expanded.type ?? "").lowercased()
        let scheme = type == "huggingface" ? "hf" : type
        let raw: String
        if scheme == "hf" {
            let revision = expanded.revision.map { "@\($0)" } ?? ""
            let filename = expanded.filename.map { "/\($0)" } ?? ""
            raw = "hf://\(expanded.repoID ?? "")\(filename)\(revision)"
        } else {
            raw = "\(scheme)://\(expanded.filename ?? expanded.repoID ?? "")"
        }
        return ParsedBenchmarkSource(
            scheme: scheme,
            raw: raw,
            path: expanded.filename ?? expanded.repoID ?? "",
            repoID: expanded.repoID,
            filename: expanded.filename,
            revision: expanded.revision,
            sha256: expanded.sha256
        )
    }

    private static func revisionSuffix(in raw: String) -> String? {
        guard let atIndex = raw.lastIndex(of: "@") else { return nil }
        let suffix = raw[raw.index(after: atIndex)...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return suffix.isEmpty ? nil : suffix
    }
}

enum BenchmarkConfigValidator {
    static func validateLocalShape(_ config: BenchmarkAppConfig) throws {
        if config.benchmarkParams == nil { throw BenchmarkConfigError.missingLocalSection("benchmark_params") }
        if config.stepDefinitions.isEmpty { throw BenchmarkConfigError.missingLocalSection("step_definitions") }
        if config.modelDefinitions.isEmpty { throw BenchmarkConfigError.missingLocalSection("model_definitions") }
        if config.capabilities == nil { throw BenchmarkConfigError.missingLocalSection("capabilities") }
        if config.downloadPolicy == nil { throw BenchmarkConfigError.missingLocalSection("download_policy") }
        if config.securityPolicy == nil { throw BenchmarkConfigError.missingLocalSection("security_policy") }
        if config.memoryPolicy == nil { throw BenchmarkConfigError.missingLocalSection("memory_policy") }
        if config.fallbacks == nil { throw BenchmarkConfigError.missingLocalSection("fallbacks") }
    }

    static func validateEffectiveConfig(
        _ config: BenchmarkAppConfig,
        remoteModelNames: Set<String>
    ) throws {
        guard let params = config.benchmarkParams else {
            throw BenchmarkConfigError.missingBenchmarkParams
        }
        let capabilities = config.capabilities ?? BenchmarkCapabilities(supportedSources: [], supportedLoaders: [])
        for stepName in params.benchmarkSteps {
            guard let step = config.stepDefinitions[stepName] else {
                throw BenchmarkConfigError.missingStep(stepName)
            }
            guard step.inputType?.nilIfBlank != nil else {
                throw BenchmarkConfigError.invalidStepChain("Benchmark step \(stepName) is missing input_type.")
            }
            guard step.outputType?.nilIfBlank != nil else {
                throw BenchmarkConfigError.invalidStepChain("Benchmark step \(stepName) is missing output_type.")
            }
            guard let modelName = step.modelName?.nilIfBlank else {
                throw BenchmarkConfigError.stepMissingModel(stepName)
            }
            guard let model = config.modelDefinitions[modelName] else {
                throw BenchmarkConfigError.missingModel(modelName)
            }
            guard model.enabled == true else {
                throw BenchmarkConfigError.disabledModel(modelName)
            }
            try validateModel(
                name: modelName,
                model,
                capabilities: capabilities,
                downloadPolicy: config.downloadPolicy,
                securityPolicy: config.securityPolicy,
                remoteModelNames: remoteModelNames
            )
        }
        try validateStepChain(params: params, steps: config.stepDefinitions)
    }

    static func resolve(
        _ config: BenchmarkAppConfig,
        remoteModelNames: Set<String>
    ) throws -> ResolvedBenchmarkConfig {
        try validateEffectiveConfig(config, remoteModelNames: remoteModelNames)
        guard let params = config.benchmarkParams else {
            throw BenchmarkConfigError.missingBenchmarkParams
        }
        let steps = params.benchmarkSteps.compactMap(BenchmarkStep.init(remoteValue:))
        guard steps.count == params.benchmarkSteps.count else {
            throw BenchmarkConfigError.invalidStepChain("Unsupported benchmark step names: \(params.benchmarkSteps.joined(separator: ", ")).")
        }
        try validateMemory(config, remoteModelNames: remoteModelNames)

        var voiceMode: VoiceToTextMode = .disabled
        var whisperSize: WhisperModelSize = .tiny
        var textToToolModel: BenchmarkTextToToolModel?
        var speechToToolPrompt: String?

        for stepName in params.benchmarkSteps {
            guard let step = config.stepDefinitions[stepName],
                  let modelName = step.modelName,
                  let model = config.modelDefinitions[modelName]
            else {
                continue
            }
            switch BenchmarkStep(remoteValue: stepName) {
            case .speechToText:
                let speech = try resolveSpeechModel(modelName: modelName)
                voiceMode = speech.mode
                whisperSize = speech.whisperSize
            case .textToTool:
                textToToolModel = try resolveTextToToolModel(
                    modelName: modelName,
                    definition: model
                )
            case .speechToTool, .none:
                voiceMode = .leap
                speechToToolPrompt = resolvePromptOverride(definition: model)
            }
        }

        let architecture: AudioToToolArchitecture = steps == [.speechToTool] ? .oneStep : .twoStep
        return ResolvedBenchmarkConfig(
            params: params,
            steps: steps,
            voiceToTextMode: voiceMode,
            whisperModelSize: whisperSize,
            audioToToolArchitecture: architecture,
            textToToolModel: textToToolModel,
            speechToToolPrompt: speechToToolPrompt
        )
    }

    private static func resolvePromptOverride(definition: BenchmarkModelDefinition) -> String? {
        guard let inference = definition.inference else { return nil }
        let prompt = inference["system_prompt"]?.stringValue
            ?? inference["systemPrompt"]?.stringValue
            ?? inference["prompt"]?.stringValue
            ?? inference["user_prompt"]?.stringValue
            ?? inference["tool_prompt"]?.stringValue
        return prompt?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    private static func validateStepChain(
        params: BenchmarkParams,
        steps: [String: BenchmarkStepDefinition]
    ) throws {
        var previousOutput: String?
        for stepName in params.benchmarkSteps {
            guard let step = steps[stepName] else { continue }
            let input = step.inputType?.lowercased()
            let output = step.outputType?.lowercased()
            if let previousOutput,
               let input,
               previousOutput != input {
                throw BenchmarkConfigError.invalidStepChain(
                    "Benchmark step chain is invalid: \(stepName) expects \(input), but previous step outputs \(previousOutput)."
                )
            }
            previousOutput = output
        }
    }

    private static func validateModel(
        name: String,
        _ model: BenchmarkModelDefinition,
        capabilities: BenchmarkCapabilities,
        downloadPolicy: BenchmarkDownloadPolicy?,
        securityPolicy: BenchmarkSecurityPolicy?,
        remoteModelNames: Set<String>
    ) throws {
        guard let sourceConfig = model.source else {
            throw BenchmarkConfigError.unsupportedSourceScheme(name)
        }
        guard let loader = model.loader?.type?.nilIfBlank else {
            throw BenchmarkConfigError.unsupportedLoader(name)
        }
        let source = try BenchmarkSourceParser.parse(sourceConfig)
        guard capabilities.supportedSources.contains(source.scheme) else {
            throw BenchmarkConfigError.unsupportedSourceScheme(source.scheme)
        }
        guard capabilities.supportedLoaders.contains(loader) else {
            throw BenchmarkConfigError.unsupportedLoader(loader)
        }
        try validateCompatibility(source: source, loader: loader)
        if remoteModelNames.contains(name), source.isRemote {
            guard let revision = source.revision, isPinnedRevision(revision) else {
                throw BenchmarkConfigError.remoteRevisionNotPinned(source.raw)
            }
            if securityPolicy?.verifyChecksumForRemoteModels == true,
               (model.sha256 ?? source.sha256)?.nilIfBlank == nil {
                throw BenchmarkConfigError.checksumRequired(name)
            }
            try validateRemoteDownloadPolicy(
                name: name,
                model: model,
                source: source,
                downloadPolicy: downloadPolicy
            )
        }
    }

    private static func validateRemoteDownloadPolicy(
        name: String,
        model: BenchmarkModelDefinition,
        source: ParsedBenchmarkSource,
        downloadPolicy: BenchmarkDownloadPolicy?
    ) throws {
        guard let downloadPolicy else { return }
        let estimatedFileMB = BenchmarkMemoryEstimator.estimatedFileSizeMB(modelName: name, definition: model)
        if let maxModelSize = downloadPolicy.maxModelSizeMB,
           estimatedFileMB > maxModelSize {
            throw BenchmarkConfigError.memoryPolicyExceeded(
                "Remote model \(name) is estimated at \(estimatedFileMB) MB, above download policy limit \(maxModelSize) MB."
            )
        }
        guard let minFreeDisk = downloadPolicy.minFreeDiskSpaceMB,
              let availableDisk = availableDiskMB()
        else {
            return
        }
        if estimatedFileMB + minFreeDisk > availableDisk {
            throw BenchmarkConfigError.memoryPolicyExceeded(
                "Remote model \(name) needs about \(estimatedFileMB) MB plus \(minFreeDisk) MB free disk margin, but only \(availableDisk) MB is available."
            )
        }
        _ = source
    }

    private static func availableDiskMB() -> Int? {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        guard let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let bytes = values.volumeAvailableCapacityForImportantUsage,
              bytes > 0
        else {
            return nil
        }
        return Int(bytes / 1_048_576)
    }

    private static func validateCompatibility(source: ParsedBenchmarkSource, loader: String) throws {
        guard let ext = source.pathExtension?.lowercased(), ext.isEmpty == false else {
            return
        }
        let valid: Bool
        switch ext {
        case "gguf":
            valid = loader == "llama.cpp"
        case "mlpackage":
            valid = loader == "coreml"
        case "onnx":
            valid = loader == "onnx"
        default:
            valid = true
        }
        if valid == false {
            throw BenchmarkConfigError.incompatibleSourceAndLoader(source: source.raw, loader: loader)
        }
    }

    private static func validateMemory(
        _ config: BenchmarkAppConfig,
        remoteModelNames: Set<String>
    ) throws {
        guard let params = config.benchmarkParams,
              let memoryPolicy = config.memoryPolicy
        else {
            return
        }
        let availableMB = BenchmarkMemoryProbe.availableMemoryMB()
        for stepName in params.benchmarkSteps {
            guard let modelName = config.stepDefinitions[stepName]?.modelName,
                  let model = config.modelDefinitions[modelName]
            else {
                continue
            }
            let estimate = try BenchmarkMemoryEstimator.estimateMB(
                modelName: modelName,
                definition: model,
                policy: memoryPolicy
            )
            if estimate > memoryPolicy.maxModelMemoryMB {
                throw BenchmarkConfigError.memoryPolicyExceeded(
                    "Model \(modelName) is estimated to need \(estimate) MB, above local memory policy limit \(memoryPolicy.maxModelMemoryMB) MB."
                )
            }
            if let availableMB,
               estimate + memoryPolicy.safetyMarginMB > availableMB {
                throw BenchmarkConfigError.memoryPolicyExceeded(
                    "Model \(modelName) is estimated to need \(estimate) MB plus \(memoryPolicy.safetyMarginMB) MB safety margin, but only \(availableMB) MB is available."
                )
            }
        }
    }

    private static func resolveSpeechModel(modelName: String) throws -> (mode: VoiceToTextMode, whisperSize: WhisperModelSize) {
        switch modelName {
        case "whisper-tiny", "openai-whisper-tiny":
            return (.whisper, .tiny)
        case "whisper-base", "openai-whisper-base":
            return (.whisper, .base)
        case "apple-speech-recognizer", "apple-speech":
            return (.apple, .tiny)
        case "leap-lfm2.5-audio-1.5b":
            return (.leap, .tiny)
        default:
            if modelName.localizedCaseInsensitiveContains("whisper") {
                return (modelName.localizedCaseInsensitiveContains("base") ? .whisper : .whisper,
                        modelName.localizedCaseInsensitiveContains("base") ? .base : .tiny)
            }
            throw BenchmarkConfigError.missingModel(modelName)
        }
    }

    private static func resolveTextToToolModel(
        modelName: String,
        definition: BenchmarkModelDefinition
    ) throws -> BenchmarkTextToToolModel {
        if let preset = BenchmarkTextToToolModel.preset(remoteValue: modelName) {
            return preset
        }
        guard let sourceConfig = definition.source,
              let loader = definition.loader?.type
        else {
            throw BenchmarkConfigError.missingModel(modelName)
        }
        let source = try BenchmarkSourceParser.parse(sourceConfig)
        if loader == "llama.cpp", source.scheme == "hf" {
            return BenchmarkTextToToolModel.custom(
                modelName: source.repoID ?? modelName,
                displayName: modelName,
                provider: "llama_cpp",
                modelSource: "huggingface",
                modelFormat: source.pathExtension ?? "gguf",
                downloadURLString: source.huggingFaceDownloadURL,
                downloadFilename: source.filename,
                contextSize: inferenceInt(definition, keys: ["n_ctx", "context_size"]) ?? 1024,
                maxGenerationTokens: inferenceInt(definition, keys: ["max_tokens", "max_generation_tokens"]) ?? 192
            )
        }
        return BenchmarkTextToToolModel.custom(
            modelName: modelName,
            displayName: modelName,
            provider: loader.replacingOccurrences(of: ".", with: "_"),
            modelSource: source.scheme,
            modelFormat: source.pathExtension ?? "",
            contextSize: inferenceInt(definition, keys: ["n_ctx", "context_size"]) ?? 1024,
            maxGenerationTokens: inferenceInt(definition, keys: ["max_tokens", "max_generation_tokens"]) ?? 192
        )
    }

    private static func inferenceInt(_ model: BenchmarkModelDefinition, keys: [String]) -> Int? {
        guard let inference = model.inference else { return nil }
        for key in keys {
            guard let value = inference[key] else { continue }
            switch value {
            case .number(let number):
                return Int(number)
            case .string(let string):
                return Int(string)
            default:
                continue
            }
        }
        return nil
    }

    private static func isPinnedRevision(_ revision: String) -> Bool {
        let trimmed = revision.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != "main", trimmed != "master", trimmed.count >= 7 else {
            return false
        }
        return trimmed.allSatisfy { $0.isHexDigit }
    }
}

enum BenchmarkMemoryEstimator {
    static func estimateMB(
        modelName: String,
        definition: BenchmarkModelDefinition,
        policy: BenchmarkMemoryPolicy
    ) throws -> Int {
        let source = try definition.source.map(BenchmarkSourceParser.parse)
        let loader = definition.loader?.type ?? ""
        let hint = definition.memoryEstimateMB ?? 0
        let fileSize = localBundleFileSizeMB(source) ?? presetApproximateFileSizeMB(modelName) ?? min(hint, policy.defaultModelFileSizeMB)
        let resolvedFileSize = max(fileSize, policy.defaultModelFileSizeMB)
        let contextTokens = inferenceInt(definition, keys: ["n_ctx", "context_size"]) ?? 1024
        let kvCache = loader == "llama.cpp"
            ? Int(ceil(Double(max(contextTokens, 1)) / 1000.0 * Double(policy.kvCacheMBPer1KTokens)))
            : 0
        let overhead = max(Int(ceil(Double(resolvedFileSize) * policy.loaderOverheadRatio)), policy.loaderOverheadMinMB)
        let calculated = resolvedFileSize + kvCache + overhead + policy.temporaryBufferMB
        return max(calculated, hint)
    }

    static func estimatedFileSizeMB(modelName: String, definition: BenchmarkModelDefinition) -> Int {
        let source = try? definition.source.map(BenchmarkSourceParser.parse)
        return localBundleFileSizeMB(source)
            ?? presetApproximateFileSizeMB(modelName)
            ?? definition.memoryEstimateMB
            ?? 0
    }

    private static func localBundleFileSizeMB(_ source: ParsedBenchmarkSource?) -> Int? {
        guard let source, source.scheme == "bundle" else { return nil }
        let resourcePath = source.path
        guard let url = Bundle.main.resourceURL?.appendingPathComponent(resourcePath),
              let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
              let fileSize = values.fileSize,
              fileSize > 0
        else {
            return nil
        }
        return Int(ceil(Double(fileSize) / 1_048_576.0))
    }

    private static func presetApproximateFileSizeMB(_ modelName: String) -> Int? {
        guard let preset = BenchmarkTextToToolModel.preset(remoteValue: modelName),
              let size = preset.approximateDownloadSize?.lowercased()
        else {
            return nil
        }
        let number = Double(size.components(separatedBy: CharacterSet(charactersIn: "0123456789.").inverted).joined())
        guard let number else { return nil }
        if size.contains("gb") {
            return Int(ceil(number * 1024))
        }
        if size.contains("mb") {
            return Int(ceil(number))
        }
        return nil
    }

    private static func inferenceInt(_ model: BenchmarkModelDefinition, keys: [String]) -> Int? {
        guard let inference = model.inference else { return nil }
        for key in keys {
            guard let value = inference[key] else { continue }
            switch value {
            case .number(let number):
                return Int(number)
            case .string(let string):
                return Int(string)
            default:
                continue
            }
        }
        return nil
    }
}

enum BenchmarkMemoryProbe {
    static func availableMemoryMB() -> Int? {
        if let bytes = WildEdge.shared.diagnostics().systemAvailableMemoryBytes, bytes > 0 {
            return Int(bytes / 1_048_576)
        }
        return nil
    }
}
#endif

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
