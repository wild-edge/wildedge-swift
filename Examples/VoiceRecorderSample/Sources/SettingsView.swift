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
    #endif

    private func downloadWhisperModels() {
        isDownloadingWhisperModels = true
        whisperDownloadStatus = "Starting Whisper Tiny and Base downloads..."
        whisperDownloadProgress = 0
        whisperDownloadModelProgress = nil

        Task {
            do {
                try await WhisperSpeechTranscriber.shared.prepareModels(WhisperModelSize.allCases) { progress in
                    Task { @MainActor in
                        whisperDownloadProgress = progress.overallProgress
                        whisperDownloadModelProgress = progress.modelProgress
                        whisperDownloadStatus = "Downloading Whisper \(progress.model.displayName) \(Int(progress.modelProgress * 100))%"
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
        leapModelStatus = "Preparing Leap downloader..."
        leapDownloadProgress = nil
        leapDownloadSpeedBytesPerSecond = 0

        Task {
            do {
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
                    leapModelStatus = "Leap LFM2.5 Audio is downloaded."
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
}
