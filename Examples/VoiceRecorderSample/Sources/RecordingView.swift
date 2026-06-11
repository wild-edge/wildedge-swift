import SwiftUI
import UIKit

struct RecordingView: View {
    @EnvironmentObject private var settingsStore: SettingsStore
    @StateObject private var viewModel = RecorderViewModel()
    @State private var isShowingSettings = false
    #if BENCHMARK_BUILD
    @State private var didCompleteBenchmarkStartupConfigRefresh = false
    #endif

    var body: some View {
        NavigationStack {
            ZStack {
                Color(.systemBackground).ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 28) {
                        #if BENCHMARK_BUILD
                        if shouldShowBenchmarkTable {
                            BenchmarkStatusCard(
                                isRunning: viewModel.isBenchmarking,
                                statusText: benchmarkStatusText,
                                inputName: viewModel.benchmarkCurrentInput,
                                preprocessingName: viewModel.benchmarkPreprocessingFile,
                                runProgress: viewModel.benchmarkRunProgress,
                                sleepCountdown: viewModel.benchmarkSleepCountdown,
                                transcript: viewModel.benchmarkTranscript,
                                expectedTranscript: viewModel.benchmarkExpectedTranscript,
                                stepsText: viewModel.benchmarkStepsText,
                                expectedToolCall: viewModel.benchmarkExpectedToolCall,
                                actualToolCall: viewModel.benchmarkActualToolCall,
                                latencyText: viewModel.benchmarkLatencyText,
                                transcriptMatchText: viewModel.benchmarkTranscriptMatchText,
                                toolCallMatchText: viewModel.benchmarkToolCallMatchText,
                                toolCallMatchSummary: viewModel.benchmarkToolCallMatchSummary,
                                toolCallMismatchDetails: viewModel.benchmarkToolCallMismatchDetails
                            )
                            .transition(.move(edge: .top).combined(with: .opacity))
                        } else {
                            voiceInputContent
                        }
                        #else
                        voiceInputContent
                        #endif
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 16)
                    .frame(maxWidth: .infinity)
                }
                .animation(.spring(response: 0.4, dampingFraction: 0.8), value: viewModel.lastRecording != nil)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isShowingSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Settings")
                }
            }
            .sheet(isPresented: $isShowingSettings) {
                SettingsView()
            }
            .task {
                #if BENCHMARK_BUILD
                await settingsStore.refreshSDKPayloadBeforeBenchmarkStart()
                didCompleteBenchmarkStartupConfigRefresh = true
                viewModel.syncBenchmark(settings: settingsStore.effectiveSettings)
                #else
                settingsStore.startRemoteConfigRefresh()
                #endif
            }
            #if BENCHMARK_BUILD
            .onAppear {
                guard didCompleteBenchmarkStartupConfigRefresh else { return }
                viewModel.syncBenchmark(settings: settingsStore.effectiveSettings)
            }
            .onChange(of: settingsStore.effectiveBenchmarkSignature) {
                guard didCompleteBenchmarkStartupConfigRefresh else { return }
                viewModel.syncBenchmark(settings: settingsStore.effectiveSettings)
            }
            #endif
        }
    }

    @ViewBuilder
    private var voiceInputContent: some View {
        ActiveConfigurationCard(
            sourceText: effectiveSettingsSourceText,
            flowText: settingsStore.effectiveSettings.flowDisplayName,
            modelText: settingsStore.effectiveSettings.modelDisplayName,
            configStatusText: settingsStore.effectiveSettings.remoteConfigWarning ?? "Config supported"
        )

        Spacer(minLength: 12)

        VoiceBarsView(levels: viewModel.barLevels)
            .frame(height: 80)
            .opacity(viewModel.isRecording ? 1 : 0.15)
            .animation(.easeInOut(duration: 0.3), value: viewModel.isRecording)

        Text(formattedDuration)
            .font(.system(size: 52, weight: .thin, design: .monospaced))
            .foregroundStyle(viewModel.isRecording ? Color.primary : Color.secondary)
            .animation(.easeInOut(duration: 0.3), value: viewModel.isRecording)
            .contentTransition(.numericText())

        RecordButton(
            isRecording: viewModel.isRecording,
            isFinishing: viewModel.isFinishing
        ) {
            Task {
                let effectiveSettings = settingsStore.effectiveSettings
                await viewModel.toggleRecording(
                    voiceToTextMode: effectiveSettings.voiceToTextMode,
                    whisperModelSize: effectiveSettings.whisperModelSize,
                    audioToToolArchitecture: effectiveSettings.audioToToolArchitecture,
                    includeSpectrogramAttachment: effectiveSettings.includeSpectrogramAttachment,
                    includeWAVAttachment: effectiveSettings.includeWAVAttachment
                )
            }
        }

        if viewModel.isProcessing {
            VStack(spacing: 8) {
                if let processingProgress = viewModel.processingProgress {
                    ProgressView(value: processingProgress)
                        .frame(maxWidth: 260)
                    Text("\(Int(processingProgress * 100))%")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView()
                        .controlSize(.small)
                }

                Text(viewModel.processingMessage.isEmpty ? "Processing voice..." : viewModel.processingMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 300)
            }
        } else if let processedAudioURL = viewModel.processedAudioURL {
            ProcessedAudioCard(
                url: processedAudioURL,
                isPlaying: viewModel.isPlayingProcessedAudio,
                statusText: viewModel.processingMessage,
                action: {
                    viewModel.toggleProcessedPlayback()
                }
            )
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }

        if let result = viewModel.lastRecording {
            RecordingResultCard(result: result)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }

        Spacer(minLength: 12)
    }

    private var formattedDuration: String {
        let total = Int(viewModel.duration)
        let tenths = Int(viewModel.duration * 10) % 10
        return String(format: "%02d:%02d.%d", total / 60, total % 60, tenths)
    }

    private var effectiveSettingsSourceText: String {
        let settings = settingsStore.effectiveSettings
        if settings.remoteConfigWarning != nil {
            #if BENCHMARK_BUILD
            if settings.benchmarkEnabled {
                return "SDK payload unsupported"
            }
            #endif
            return "SDK payload fallback"
        }
        return settings.isUsingSDKPayload ? "SDK payload" : "Local"
    }

    #if BENCHMARK_BUILD
    private var shouldShowBenchmarkTable: Bool {
        settingsStore.effectiveSettings.benchmarkEnabled
            || viewModel.isBenchmarking
            || !didCompleteBenchmarkStartupConfigRefresh
    }

    private var benchmarkStatusText: String {
        if !didCompleteBenchmarkStartupConfigRefresh {
            return "Refreshing SDK payload before benchmark..."
        }
        if !viewModel.benchmarkStatus.isEmpty {
            return viewModel.benchmarkStatus
        }
        return settingsStore.effectiveSettings.benchmarkEnabled
            ? "Benchmark enabled. Waiting for runner..."
            : "Benchmark disabled."
    }
    #endif
}

private struct ActiveConfigurationCard: View {
    let sourceText: String
    let flowText: String
    let modelText: String
    let configStatusText: String

    private var isWarning: Bool {
        configStatusText.localizedCaseInsensitiveContains("unsupported")
            || configStatusText.localizedCaseInsensitiveContains("falling back")
            || configStatusText.localizedCaseInsensitiveContains("stopped")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: isWarning ? "exclamationmark.triangle.fill" : "checkmark.shield.fill")
                    .foregroundStyle(isWarning ? .orange : .green)
                Text("Active configuration")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(sourceText)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            Divider()

            row(label: "Flow", value: flowText)
            row(label: "Model", value: modelText)
            row(label: "Config", value: configStatusText, emphasized: isWarning)
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private func row(label: String, value: String, emphasized: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 54, alignment: .leading)
            Text(value)
                .foregroundStyle(emphasized ? .orange : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(3, reservesSpace: true)
                .textSelection(.enabled)
        }
        .font(.caption)
    }
}

#if BENCHMARK_BUILD
private struct BenchmarkStatusCard: View {
    let isRunning: Bool
    let statusText: String
    let inputName: String
    let preprocessingName: String
    let runProgress: String
    let sleepCountdown: String
    let transcript: String
    let expectedTranscript: String
    let stepsText: String
    let expectedToolCall: String
    let actualToolCall: String
    let latencyText: String
    let transcriptMatchText: String
    let toolCallMatchText: String
    let toolCallMatchSummary: String
    let toolCallMismatchDetails: [String]
    @State private var isShowingToolMismatchDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                if isRunning {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "stopwatch")
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("Benchmark")
                        .font(.subheadline.weight(.semibold))
                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer()

                Text(displayValue(latencyText, processingWhenEmpty: isRunning))
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(latencyText.isEmpty ? .secondary : .primary)
            }

            Divider()

            stableRow("Benchmark input file", value: inputName)
            stableRow("Preprocessing file", value: preprocessingName)
            stableRow("Measuring inference time", value: runProgress)
            stableRow("Benchmark steps", value: stepsText)
            stableRow("Sleep countdown", value: sleepCountdown)
            if includesTranscriptStep {
                Divider()
                stableBlock("Expected speech_to_text", value: expectedTranscript)
                stableBlock(
                    "Actual speech_to_text",
                    value: transcript,
                    processingWhenEmpty: isRunning
                )
                resultRow(label: "Speech-to-text result", value: transcriptMatchText)
            }

            if includesToolStep {
                Divider()
                stableBlock("Expected tool JSON", value: expectedToolCall)
                stableBlock(
                    actualToolCallLabel,
                    value: actualToolCall,
                    processingWhenEmpty: isRunning
                )
                resultRow(label: "Tool JSON result", value: toolCallMatchText)
                resultRow(label: "Tool JSON matches", value: toolCallMatchSummary)
                toolMismatchDisclosure
            }
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private func stableRow(
        _ label: String,
        value: String,
        processingWhenEmpty: Bool = false
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 150, alignment: .leading)
            Spacer(minLength: 4)
            Text(displayValue(value, processingWhenEmpty: processingWhenEmpty))
                .foregroundStyle(value.isEmpty ? .secondary : .primary)
                .multilineTextAlignment(.trailing)
                .lineLimit(2, reservesSpace: true)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .textSelection(.enabled)
        }
        .font(.caption)
    }

    private func stableBlock(
        _ label: String,
        value: String,
        processingWhenEmpty: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(displayValue(value, processingWhenEmpty: processingWhenEmpty))
                .font(.caption.monospaced())
                .foregroundStyle(value.isEmpty ? .secondary : .primary)
                .textSelection(.enabled)
                .lineLimit(6, reservesSpace: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func resultRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(displayValue(value))
                .font(.caption.weight(.semibold))
                .foregroundStyle(resultColor(for: value))
        }
        .font(.caption)
    }

    @ViewBuilder
    private var toolMismatchDisclosure: some View {
        if toolCallMismatchDetails.isEmpty == false {
            DisclosureGroup(isExpanded: $isShowingToolMismatchDetails) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(toolCallMismatchDetails, id: \.self) { detail in
                        Text(detail)
                            .font(.caption.monospaced())
                            .foregroundStyle(.orange)
                            .textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
            } label: {
                Text("show details")
                    .font(.caption.weight(.semibold))
            }
        }
    }

    private func displayValue(_ value: String, processingWhenEmpty: Bool = false) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return value
        }
        return processingWhenEmpty ? "(processing)" : "null / empty"
    }

    private func resultColor(for value: String) -> Color {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return .secondary
        }
        return trimmed == "match" ? .green : .orange
    }

    private var includesTranscriptStep: Bool {
        stepsText.contains("speech_to_text")
    }

    private var includesToolStep: Bool {
        stepsText.contains("text_to_tool") || stepsText.contains("speech_to_tool")
    }

    private var actualToolCallLabel: String {
        stepsText.contains("speech_to_tool")
            ? "Actual speech_to_tool JSON"
            : "Actual text_to_tool JSON"
    }
}
#endif

private struct ProcessedAudioCard: View {
    let url: URL
    let isPlaying: Bool
    let statusText: String
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("TPain output", systemImage: "waveform.circle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.purple)

            Divider()

            Text(url.lastPathComponent)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)

            if !statusText.isEmpty {
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button(action: action) {
                Label(isPlaying ? "Stop playback" : "Play processed audio", systemImage: isPlaying ? "stop.fill" : "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }
}

private struct RecordButton: View {
    let isRecording: Bool
    let isFinishing: Bool
    let action: () -> Void

    private var circleColor: Color {
        isRecording ? .red : (isFinishing ? Color(.systemGray3) : .accentColor)
    }

    private var shadowColor: Color {
        isRecording ? Color.red.opacity(0.45) : (isFinishing ? .clear : Color.accentColor.opacity(0.3))
    }

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(circleColor)
                    .frame(width: 80, height: 80)
                    .shadow(color: shadowColor, radius: isRecording ? 16 : 8)

                if isFinishing {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(.white)
                        .transition(.scale.combined(with: .opacity))
                } else {
                    if isRecording {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 30, weight: .semibold))
                            .foregroundStyle(.white)
                            .transition(.scale.combined(with: .opacity))
                    } else {
                        RecordProcessIcon()
                            .transition(.scale.combined(with: .opacity))
                    }
                }
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isFinishing)
        }
        .disabled(isFinishing)
        .accessibilityLabel(isRecording ? "Stop recording" : "Record and process")
        .scaleEffect(isRecording ? 1.1 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: isRecording)
        .animation(.easeInOut(duration: 0.2), value: isFinishing)
    }
}

private struct RecordProcessIcon: View {
    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Image(systemName: "mic.fill")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(.white)

            ZStack {
                Circle()
                    .fill(.white)
                Image(systemName: "doc.text.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color.accentColor)
            }
            .frame(width: 22, height: 22)
            .offset(x: 9, y: 7)
        }
        .frame(width: 44, height: 44)
    }
}

private struct RecordingResultCard: View {
    let result: RecordingResult

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Recording saved", systemImage: "checkmark.circle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.green)

            Divider()

            row(label: "Duration", value: result.formattedDuration)
            row(label: "Size", value: result.formattedFileSize)
            row(label: "File", value: result.fileURL.lastPathComponent)
            row(label: "Inference ID", value: String(result.inferenceId.prefix(16)) + "…")

            if let transcriptionDurationMs = result.transcriptionDurationMs {
                row(label: "STT", value: "\(result.transcriptionModelName ?? "Voice to text") - \(transcriptionDurationMs) ms")
            }

            if let speechInferenceId = result.speechInferenceId {
                row(label: "STT ID", value: String(speechInferenceId.prefix(16)) + "…")
            }

            if let transcript = result.transcript, !transcript.isEmpty {
                Divider()

                Text("Transcript")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(transcript)
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let spectrogramURL = result.spectrogramURL {
                Divider()

                row(label: "Spectrogram", value: "generated")

                SpectrogramPreview(url: spectrogramURL)
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private func row(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .leading)
            Text(value)
                .font(.caption.monospaced())
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
    }
}

private struct SpectrogramPreview: View {
    let url: URL

    var body: some View {
        if let image = UIImage(contentsOfFile: url.path) {
            Image(uiImage: image)
                .resizable()
                .interpolation(.none)
                .scaledToFit()
                .frame(maxWidth: .infinity)
                .frame(height: 160)
                .background(Color.black.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .accessibilityLabel("Generated audio spectrogram")
        }
    }
}

private struct VoiceBarsView: View {
    let levels: [Float]

    var body: some View {
        GeometryReader { geo in
            let barWidth = (geo.size.width - CGFloat(levels.count - 1) * 3) / CGFloat(levels.count)
            HStack(alignment: .center, spacing: 3) {
                ForEach(Array(levels.enumerated()), id: \.offset) { index, level in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.accentColor.opacity(0.45 + Double(level) * 0.55))
                        .frame(
                            width: barWidth,
                            height: max(4, CGFloat(level) * geo.size.height)
                        )
                        .animation(.easeOut(duration: 0.08), value: level)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
    }
}
