import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var settingsStore: SettingsStore
    @State private var isDownloadingWhisperModels = false
    @State private var whisperDownloadStatus = "Models download automatically when Whisper is used."
    @State private var whisperDownloadProgress: Double?
    @State private var whisperDownloadModelProgress: Double?
    @State private var isPreparingLeapModel = false
    @State private var leapModelStatus = LeapSpeechTranscriber.statusMessage
    @State private var leapDownloadProgress: Double?
    @State private var leapDownloadSpeedBytesPerSecond: Int64 = 0
    @State private var modelDownloadStatuses: [String: ModelAssetStatus] = [:]
    @State private var isRefreshingModelDownloads = false
    @State private var clearingModelDownloadID: String?
    #if BENCHMARK_BUILD
    @State private var isDownloadingTextToToolModel = false
    #if canImport(LlamaSwift) || (canImport(MLXLLM) && canImport(MLXLMCommon))
    @State private var textToToolModelStatus = "Local text-to-tool models download automatically when selected."
    #else
    @State private var textToToolModelStatus = "Local text-to-tool models are not linked in this build."
    #endif
    @State private var textToToolDownloadProgress: Double?
    @State private var textToToolDownloadSpeedBytesPerSecond: Int64 = 0
    #endif

    var body: some View {
        NavigationStack {
            Form {
                Section("Source") {
                    Toggle("Use SDK payload settings", isOn: $settingsStore.useSDKPayloadSettings)

                    Text(settingsStore.effectiveSettingsSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                #if BENCHMARK_BUILD
                Section("Benchmark") {
                    Toggle("benchmark_enabled", isOn: benchmarkEnabledBinding)
                        .disabled(settingsStore.effectiveSettings.isUsingSDKPayload)

                    Picker("Text-to-tool model", selection: benchmarkTextToToolModelBinding) {
                        ForEach(selectableBenchmarkTextToToolModels) { model in
                            Text(model.displayName).tag(model)
                        }
                    }
                    .disabled(settingsStore.effectiveSettings.isUsingSDKPayload)

                    Picker("Speech-to-tool model", selection: benchmarkSpeechToToolModelBinding) {
                        ForEach(selectableBenchmarkSpeechToToolModels) { model in
                            Text(model.displayName).tag(model)
                        }
                    }
                    .disabled(settingsStore.effectiveSettings.isUsingSDKPayload)
                }
                #endif

                Section("Voice To Text") {
                    Picker("", selection: voiceToTextModeBinding) {
                        ForEach(VoiceToTextMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.inline)
                    .disabled(settingsStore.effectiveSettings.isUsingSDKPayload)
                }

                Section("Whisper") {
                    Picker("Model", selection: whisperModelSizeBinding) {
                        ForEach(WhisperModelSize.allCases) { model in
                            Text(model.displayName).tag(model)
                        }
                    }
                    .disabled(settingsStore.effectiveSettings.isUsingSDKPayload)

                    Button {
                        downloadWhisperModels()
                    } label: {
                        Label("Download Tiny + Base", systemImage: "arrow.down.circle")
                    }
                    .disabled(isDownloadingWhisperModels)

                    VStack(alignment: .leading, spacing: 8) {
                        Text(whisperDownloadStatus)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        if let whisperDownloadProgress {
                            ProgressView(value: whisperDownloadProgress)
                            HStack {
                                Text("\(Int(whisperDownloadProgress * 100))% overall")
                                Spacer()
                                if let whisperDownloadModelProgress {
                                    Text("\(Int(whisperDownloadModelProgress * 100))% current")
                                }
                            }
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                        } else if isDownloadingWhisperModels {
                            ProgressView()
                        }
                    }
                }

                Section("Leap") {
                    LabeledContent("Model", value: "LFM2.5-Audio-1.5B")
                    LabeledContent("Quantization", value: LeapSpeechTranscriber.quantization)
                    LabeledContent("Download", value: LeapSpeechTranscriber.approximateDownloadSize)

                    Button {
                        downloadLeapModel()
                    } label: {
                        Label("Prepare LFM2.5 Audio", systemImage: "arrow.down.circle")
                    }
                    .disabled(isPreparingLeapModel)

                    VStack(alignment: .leading, spacing: 8) {
                        Text(leapModelStatus)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        if let leapDownloadProgress {
                            ProgressView(value: leapDownloadProgress)
                            HStack {
                                Text("\(Int(leapDownloadProgress * 100))%")
                                Spacer()
                                Text(formattedByteRate(leapDownloadSpeedBytesPerSecond))
                            }
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                        } else if isPreparingLeapModel {
                            ProgressView()
                        }
                    }
                }

                #if BENCHMARK_BUILD
                Section("Speech To Tool") {
                    #if canImport(LlamaSwift)
                    ForEach([
                        BenchmarkTextToToolModel.liquidLFM25AudioOnePointFiveB,
                        .ultravoxLlama32OneB,
                        .qwen3ASRZeroPointSixB
                    ]) { model in
                        textToToolDownloadRow(model)
                    }
                    #endif

                    LabeledContent("Leap SDK", value: "Use the Leap section above")

                    #if !canImport(LlamaSwift)
                    Text("Local speech-to-tool models are disabled in this build because LlamaSwift is not linked.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    #endif
                }

                Section("Text To Tool") {
                    #if canImport(LlamaSwift)
                    ForEach([
                        BenchmarkTextToToolModel.leapLFM25350M,
                        .leapLFM2512BInstruct,
                        .functionGemma,
                        .tinyLlamaOnePointOneB,
                        .qwen2ZeroPointFiveBInstruct,
                        .qwen25OnePointFiveBInstruct,
                        .qwen3ZeroPointSixB4Bit,
                        .qwen3FourB4Bit
                    ]) { model in
                        textToToolDownloadRow(model)
                    }
                    #endif

                    #if canImport(MLXLLM) && canImport(MLXLMCommon)
                    ForEach([
                        BenchmarkTextToToolModel.functionGemmaMLX,
                        .qwen35ZeroPointEightBOptiQMLX
                    ]) { model in
                        textToToolDownloadRow(model)
                    }
                    #endif

                    #if !canImport(LlamaSwift) && !(canImport(MLXLLM) && canImport(MLXLMCommon))
                    Text("Local text-to-tool models are disabled in this build because neither LlamaSwift nor MLX is linked.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    #endif

                    #if !canImport(MLXLLM) || !canImport(MLXLMCommon)
                    if BenchmarkTextToToolModel.functionGemmaMLX.provider == "mlx" {
                        VStack(alignment: .leading, spacing: 4) {
                            LabeledContent(BenchmarkTextToToolModel.functionGemmaMLX.displayName, value: BenchmarkTextToToolModel.functionGemmaMLX.approximateDownloadSize ?? "Unknown size")
                            Text("MLX is not linked in this build.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    #endif

                    LabeledContent("ONNX", value: "Runtime linked; no text-to-tool model configured")

                    VStack(alignment: .leading, spacing: 8) {
                        Text(textToToolModelStatus)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        if let textToToolDownloadProgress {
                            ProgressView(value: textToToolDownloadProgress)
                            HStack {
                                Text("\(Int(textToToolDownloadProgress * 100))%")
                                Spacer()
                                Text(formattedByteRate(textToToolDownloadSpeedBytesPerSecond))
                            }
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                        } else if isDownloadingTextToToolModel {
                            ProgressView()
                        }
                    }
                }
                #endif

                Section("Model Downloads") {
                    HStack {
                        Text("Cached model assets")
                            .foregroundStyle(.secondary)
                        Spacer()
                        if isRefreshingModelDownloads {
                            ProgressView()
                        }
                    }

                    Button {
                        refreshModelDownloads()
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .disabled(isRefreshingModelDownloads)

                    ForEach(managedModelDownloads) { download in
                        modelDownloadRow(download)
                    }
                }

                Section("Attachments") {
                    Toggle("WAV", isOn: includeWAVAttachmentBinding)
                        .disabled(settingsStore.effectiveSettings.isUsingSDKPayload)
                    Toggle("Audio spectrogram", isOn: includeSpectrogramAttachmentBinding)
                        .disabled(settingsStore.effectiveSettings.isUsingSDKPayload)
                }

                Section("SDK Payload") {
                    LabeledContent("Refreshed at", value: settingsStore.formattedSDKPayloadRefreshedAt)

                    HStack {
                        Text(settingsStore.sdkPayloadStatus)
                            .foregroundStyle(.secondary)

                        Spacer()

                        if settingsStore.isRefreshingSDKPayload {
                            ProgressView()
                        }
                    }

                    Button {
                        settingsStore.refreshSDKPayload()
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }

                    Text(settingsStore.sdkPayloadText)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .task {
                refreshModelDownloads()
            }
        }
    }

    private var voiceToTextModeBinding: Binding<VoiceToTextMode> {
        Binding(
            get: { settingsStore.effectiveSettings.voiceToTextMode },
            set: { settingsStore.voiceToTextMode = $0 }
        )
    }

    private var whisperModelSizeBinding: Binding<WhisperModelSize> {
        Binding(
            get: { settingsStore.effectiveSettings.whisperModelSize },
            set: { settingsStore.whisperModelSize = $0 }
        )
    }

    private var includeWAVAttachmentBinding: Binding<Bool> {
        Binding(
            get: { settingsStore.effectiveSettings.includeWAVAttachment },
            set: { settingsStore.includeWAVAttachment = $0 }
        )
    }

    private var includeSpectrogramAttachmentBinding: Binding<Bool> {
        Binding(
            get: { settingsStore.effectiveSettings.includeSpectrogramAttachment },
            set: { settingsStore.includeSpectrogramAttachment = $0 }
        )
    }

    #if BENCHMARK_BUILD
    private var benchmarkEnabledBinding: Binding<Bool> {
        Binding(
            get: { settingsStore.effectiveSettings.benchmarkEnabled },
            set: { settingsStore.benchmarkEnabled = $0 }
        )
    }

    private var benchmarkTextToToolModelBinding: Binding<BenchmarkTextToToolModel> {
        Binding(
            get: { settingsStore.effectiveSettings.benchmarkTextToToolModel },
            set: { settingsStore.benchmarkTextToToolModel = $0 }
        )
    }

    private var benchmarkSpeechToToolModelBinding: Binding<BenchmarkTextToToolModel> {
        Binding(
            get: { settingsStore.effectiveSettings.benchmarkSpeechToToolModel },
            set: { settingsStore.benchmarkSpeechToToolModel = $0 }
        )
    }

    private var selectableBenchmarkTextToToolModels: [BenchmarkTextToToolModel] {
        SettingsStore.selectableBenchmarkTextToToolModels.filter { model in
            switch model.provider {
            case "llama_cpp":
                #if canImport(LlamaSwift)
                return true
                #else
                return false
                #endif
            case "mlx":
                #if canImport(MLXLLM) && canImport(MLXLMCommon)
                return true
                #else
                return false
                #endif
            case "foundation_models":
                #if canImport(FoundationModels)
                return true
                #else
                return false
                #endif
            default:
                return false
            }
        }
    }

    private var selectableBenchmarkSpeechToToolModels: [BenchmarkTextToToolModel] {
        SettingsStore.selectableBenchmarkSpeechToToolModels.filter { model in
            switch model.provider {
            case "llama_cpp_mtmd":
                #if canImport(LlamaSwift)
                return true
                #else
                return false
                #endif
            case "leap_sdk":
                return true
            default:
                return false
            }
        }
    }
    #endif

    private func downloadWhisperModels() {
        isDownloadingWhisperModels = true
        whisperDownloadStatus = "Checking Whisper models..."
        whisperDownloadProgress = nil
        whisperDownloadModelProgress = nil

        Task {
            do {
                try await WhisperSpeechTranscriber.shared.prepareModels(WhisperModelSize.allCases) { progress in
                    Task { @MainActor in
                        whisperDownloadProgress = progress.overallProgress
                        whisperDownloadModelProgress = progress.modelProgress
                        whisperDownloadStatus = whisperPreparationMessage(progress)
                    }
                }
                await MainActor.run {
                    whisperDownloadStatus = "Whisper Tiny and Base are ready."
                    whisperDownloadProgress = nil
                    whisperDownloadModelProgress = nil
                    isDownloadingWhisperModels = false
                }
            } catch {
                await MainActor.run {
                    whisperDownloadStatus = error.localizedDescription
                    whisperDownloadProgress = nil
                    whisperDownloadModelProgress = nil
                    isDownloadingWhisperModels = false
                }
            }
        }
    }

    private func downloadLeapModel() {
        isPreparingLeapModel = true
        leapModelStatus = "Checking Leap LFM2.5 Audio..."
        leapDownloadProgress = nil
        leapDownloadSpeedBytesPerSecond = 0

        Task {
            do {
                let status = await VoiceRecorderModelManager.shared.status(
                    for: .leapAudio(
                        modelName: LeapSpeechTranscriber.modelName,
                        quantization: LeapSpeechTranscriber.quantization
                    )
                )
                if status.state == .blocked {
                    await MainActor.run {
                        let cachedPrefix = status.localURL == nil ? "" : "Cached locally. "
                        leapModelStatus = "Blocked: \(cachedPrefix)\(status.message ?? LeapSpeechTranscriber.loadDisabledReason)"
                        leapDownloadProgress = nil
                        leapDownloadSpeedBytesPerSecond = 0
                        isPreparingLeapModel = false
                    }
                    return
                }
                if status.isCached {
                    await MainActor.run {
                        leapModelStatus = "Using cached Leap LFM2.5 Audio."
                        leapDownloadProgress = nil
                        leapDownloadSpeedBytesPerSecond = 0
                        isPreparingLeapModel = false
                    }
                    return
                }

                await MainActor.run {
                    leapModelStatus = "Starting Leap SDK download..."
                    leapDownloadProgress = 0
                }

                let transcriber = await LeapSpeechTranscriber.shared()
                await MainActor.run {
                    leapModelStatus = "Downloading Leap LFM2.5 Audio \(LeapSpeechTranscriber.quantization)..."
                }

                try await transcriber.downloadModel { progress, speed in
                    Task { @MainActor in
                        let percent = Int(progress * 100)
                        leapDownloadProgress = progress
                        leapDownloadSpeedBytesPerSecond = speed
                        leapModelStatus = "Downloading Leap LFM2.5 Audio \(percent)%"
                    }
                }
                await MainActor.run {
                    leapModelStatus = "Leap LFM2.5 Audio is downloaded. It will load when used."
                    leapDownloadProgress = nil
                    leapDownloadSpeedBytesPerSecond = 0
                    isPreparingLeapModel = false
                }
            } catch {
                await MainActor.run {
                    leapModelStatus = error.localizedDescription
                    leapDownloadProgress = nil
                    leapDownloadSpeedBytesPerSecond = 0
                    isPreparingLeapModel = false
                }
            }
        }
    }

    private var managedModelDownloads: [ManagedModelDownload] {
        var downloads: [ManagedModelDownload] = [
            ManagedModelDownload(
                id: "whisper-\(WhisperModelSize.tiny.rawValue)",
                title: "Whisper Tiny",
                subtitle: "speech_to_text",
                kind: .managed(.whisper(.tiny))
            ),
            ManagedModelDownload(
                id: "whisper-\(WhisperModelSize.base.rawValue)",
                title: "Whisper Base",
                subtitle: "speech_to_text",
                kind: .managed(.whisper(.base))
            ),
            ManagedModelDownload(
                id: "leap-audio-\(LeapSpeechTranscriber.quantization)",
                title: "Leap LFM2.5 Audio",
                subtitle: LeapSpeechTranscriber.quantization,
                kind: .managed(
                    .leapAudio(
                        modelName: LeapSpeechTranscriber.modelName,
                        quantization: LeapSpeechTranscriber.quantization
                    )
                )
            )
        ]

        #if BENCHMARK_BUILD
        #if canImport(LlamaSwift)
        downloads.append(contentsOf: [
            .textToTool(.liquidLFM25AudioOnePointFiveB),
            .ggufProjector(.liquidLFM25AudioOnePointFiveB),
            .textToTool(.ultravoxLlama32OneB),
            .ggufProjector(.ultravoxLlama32OneB),
            .textToTool(.qwen3ASRZeroPointSixB),
            .ggufProjector(.qwen3ASRZeroPointSixB),
            .textToTool(.leapLFM25350M),
            .textToTool(.leapLFM2512BInstruct),
            .textToTool(.functionGemma),
            .textToTool(.tinyLlamaOnePointOneB),
            .textToTool(.qwen2ZeroPointFiveBInstruct),
            .textToTool(.qwen25OnePointFiveBInstruct),
            .textToTool(.qwen3ZeroPointSixB4Bit),
            .textToTool(.qwen3FourB4Bit)
        ])
        #endif

        #if canImport(MLXLLM) && canImport(MLXLMCommon)
        downloads.append(contentsOf: [
            .mlxTextToTool(.functionGemmaMLX),
            .mlxTextToTool(.qwen35ZeroPointEightBOptiQMLX)
        ])
        #endif
        #endif

        return downloads
    }

    private func modelDownloadRow(_ download: ManagedModelDownload) -> some View {
        let status = modelDownloadStatuses[download.id]
        let isClearing = clearingModelDownloadID == download.id
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(download.title)
                        .font(.subheadline.weight(.semibold))
                    Text(download.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(modelDownloadStatusText(status))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(modelDownloadStatusColor(status))
                }

                Spacer()

                Button(role: .destructive) {
                    clearModelDownload(download)
                } label: {
                    if isClearing {
                        ProgressView()
                    } else {
                        Image(systemName: "trash")
                    }
                }
                .buttonStyle(.bordered)
                .disabled(isClearing || status?.state == .missing || status == nil)
                .accessibilityLabel("Clear \(download.title)")
            }

            if let message = status?.message, message.isEmpty == false {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func refreshModelDownloads() {
        let downloads = managedModelDownloads
        isRefreshingModelDownloads = true
        Task {
            var statuses: [String: ModelAssetStatus] = [:]
            for download in downloads {
                statuses[download.id] = await modelDownloadStatus(for: download)
            }
            await MainActor.run {
                modelDownloadStatuses = statuses
                isRefreshingModelDownloads = false
            }
        }
    }

    private func clearModelDownload(_ download: ManagedModelDownload) {
        clearingModelDownloadID = download.id
        Task {
            switch download.kind {
            case .managed(let asset):
                await VoiceRecorderModelManager.shared.invalidate(asset)
            case .mlx(let model):
                await MlxBenchmarkTextToToolModel.shared.invalidateModel(model)
            }
            let status = await modelDownloadStatus(for: download)
            await MainActor.run {
                modelDownloadStatuses[download.id] = status
                clearingModelDownloadID = nil
            }
        }
    }

    private func modelDownloadStatus(for download: ManagedModelDownload) async -> ModelAssetStatus {
        switch download.kind {
        case .managed(let asset):
            return await VoiceRecorderModelManager.shared.status(for: asset)
        case .mlx(let model):
            return await MlxBenchmarkTextToToolModel.shared.modelStatus(model)
        }
    }

    private func modelDownloadStatusText(_ status: ModelAssetStatus?) -> String {
        guard let status else { return "Checking..." }
        let size = formattedBytes(status.bytes)
        switch status.state {
        case .missing:
            return "Missing"
        case .partial:
            return "Partial \(size)"
        case .cached:
            return "Cached \(size)"
        case .blocked:
            return status.bytes > 0 ? "Blocked, cached \(size)" : "Blocked"
        }
    }

    private func modelDownloadStatusColor(_ status: ModelAssetStatus?) -> Color {
        guard let status else { return .secondary }
        switch status.state {
        case .cached:
            return .green
        case .partial, .blocked:
            return .orange
        case .missing:
            return .secondary
        }
    }

    #if BENCHMARK_BUILD
    private func textToToolDownloadRow(_ model: BenchmarkTextToToolModel) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            LabeledContent(model.displayName, value: model.approximateDownloadSize ?? "Unknown size")
            Button {
                downloadTextToToolModel(model)
            } label: {
                Label("Prepare \(model.displayName)", systemImage: "arrow.down.circle")
            }
            .disabled(isDownloadingTextToToolModel)
        }
    }

    private func downloadTextToToolModel(_ model: BenchmarkTextToToolModel) {
        isDownloadingTextToToolModel = true
        textToToolModelStatus = "Checking \(model.displayName)..."
        textToToolDownloadProgress = nil
        textToToolDownloadSpeedBytesPerSecond = 0

        Task {
            do {
                let status: ModelAssetStatus
                if model.provider == "mlx" {
                    status = await MlxBenchmarkTextToToolModel.shared.modelStatus(model)
                } else {
                    status = await LlamaCppBenchmarkTextToToolModel.shared.modelStatus(model)
                }
                if status.isCached {
                    await MainActor.run {
                        textToToolModelStatus = "Using cached \(model.displayName)."
                        textToToolDownloadProgress = nil
                        textToToolDownloadSpeedBytesPerSecond = 0
                    }
                } else if status.state == .partial {
                    await MainActor.run {
                        textToToolModelStatus = "Resuming \(model.displayName) download..."
                        textToToolDownloadProgress = nil
                        textToToolDownloadSpeedBytesPerSecond = 0
                    }
                } else {
                    await MainActor.run {
                        textToToolModelStatus = "Downloading \(model.displayName)..."
                        textToToolDownloadProgress = 0
                    }
                }
                if model.provider == "mlx" {
                    try await MlxBenchmarkTextToToolModel.shared.prepareModel(model) { progress, speed in
                        Task { @MainActor in
                            textToToolDownloadProgress = progress
                            textToToolDownloadSpeedBytesPerSecond = speed
                            textToToolModelStatus = "Downloading \(model.displayName) \(Int(progress * 100))%"
                        }
                    }
                } else if model.provider == "llama_cpp_mtmd" {
                    _ = try await VoiceRecorderModelManager.shared.prepare(
                        .gguf(model),
                        progressHandler: { progress in
                            guard progress.phase == .downloading,
                                  let fraction = progress.progress
                            else {
                                return
                            }
                            Task { @MainActor in
                                let combinedProgress = fraction * 0.5
                                textToToolDownloadProgress = combinedProgress
                                textToToolDownloadSpeedBytesPerSecond = progress.speedBytesPerSecond
                                textToToolModelStatus = "Downloading \(model.displayName) model \(Int(combinedProgress * 100))%"
                            }
                        }
                    )
                    _ = try await VoiceRecorderModelManager.shared.prepare(
                        .ggufProjector(model),
                        progressHandler: { progress in
                            guard progress.phase == .downloading,
                                  let fraction = progress.progress
                            else {
                                return
                            }
                            Task { @MainActor in
                                let combinedProgress = 0.5 + fraction * 0.5
                                textToToolDownloadProgress = combinedProgress
                                textToToolDownloadSpeedBytesPerSecond = progress.speedBytesPerSecond
                                textToToolModelStatus = "Downloading \(model.displayName) projector \(Int(combinedProgress * 100))%"
                            }
                        }
                    )
                } else {
                    _ = try await LlamaCppBenchmarkTextToToolModel.shared.downloadModel(model) { progress, speed in
                        Task { @MainActor in
                            textToToolDownloadProgress = progress
                            textToToolDownloadSpeedBytesPerSecond = speed
                            textToToolModelStatus = "Downloading \(model.displayName) \(Int(progress * 100))%"
                        }
                    }
                }
                await MainActor.run {
                    textToToolModelStatus = "\(model.displayName) is ready."
                    textToToolDownloadProgress = nil
                    textToToolDownloadSpeedBytesPerSecond = 0
                    isDownloadingTextToToolModel = false
                }
            } catch {
                await MainActor.run {
                    textToToolModelStatus = error.localizedDescription
                    textToToolDownloadProgress = nil
                    textToToolDownloadSpeedBytesPerSecond = 0
                    isDownloadingTextToToolModel = false
                }
            }
        }
    }
    #endif

    private func whisperPreparationMessage(_ progress: WhisperModelDownloadProgress) -> String {
        switch progress.phase {
        case .checking:
            return "Checking Whisper \(progress.model.displayName)..."
        case .cached:
            return "Using cached Whisper \(progress.model.displayName)."
        case .downloading:
            return "Downloading Whisper \(progress.model.displayName) \(Int(progress.modelProgress * 100))%"
        case .loading:
            return "Loading Whisper \(progress.model.displayName)..."
        case .blocked:
            return "Blocked: Whisper \(progress.model.displayName)"
        }
    }

    private func formattedByteRate(_ bytesPerSecond: Int64) -> String {
        guard bytesPerSecond > 0 else { return "Waiting..." }
        let value = Double(bytesPerSecond)
        if value >= 1_000_000 {
            return String(format: "%.1f MB/s", value / 1_000_000)
        }
        if value >= 1_000 {
            return String(format: "%.0f KB/s", value / 1_000)
        }
        return "\(bytesPerSecond) B/s"
    }

    private func formattedBytes(_ bytes: Int64) -> String {
        guard bytes > 0 else { return "0 B" }
        let value = Double(bytes)
        if value >= 1_000_000_000 {
            return String(format: "%.2f GB", value / 1_000_000_000)
        }
        if value >= 1_000_000 {
            return String(format: "%.1f MB", value / 1_000_000)
        }
        if value >= 1_000 {
            return String(format: "%.0f KB", value / 1_000)
        }
        return "\(bytes) B"
    }
}

private struct ManagedModelDownload: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let kind: ManagedModelDownloadKind

    static func textToTool(_ model: BenchmarkTextToToolModel) -> ManagedModelDownload {
        ManagedModelDownload(
            id: "text-to-tool-\(model.id)",
            title: model.displayName,
            subtitle: [model.provider, model.quantization].filter { !$0.isEmpty }.joined(separator: " - "),
            kind: .managed(.gguf(model))
        )
    }

    static func ggufProjector(_ model: BenchmarkTextToToolModel) -> ManagedModelDownload {
        ManagedModelDownload(
            id: "mmproj-\(model.id)",
            title: "\(model.displayName) mmproj",
            subtitle: [model.provider, "projector"].joined(separator: " - "),
            kind: .managed(.ggufProjector(model))
        )
    }

    static func mlxTextToTool(_ model: BenchmarkTextToToolModel) -> ManagedModelDownload {
        ManagedModelDownload(
            id: "mlx-text-to-tool-\(model.id)",
            title: model.displayName,
            subtitle: [model.provider, model.quantization].filter { !$0.isEmpty }.joined(separator: " - "),
            kind: .mlx(model)
        )
    }
}

private enum ManagedModelDownloadKind {
    case managed(VoiceRecorderModelAsset)
    case mlx(BenchmarkTextToToolModel)
}
