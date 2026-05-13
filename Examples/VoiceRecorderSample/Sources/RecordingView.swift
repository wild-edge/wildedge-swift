import SwiftUI

struct RecordingView: View {
    @StateObject private var viewModel = RecorderViewModel()

    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()

            ScrollView {
                VStack(spacing: 28) {
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
                        Task { await viewModel.toggleRecording() }
                    }

                    if viewModel.isProcessing {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text(viewModel.processingMessage.isEmpty ? "Processing voice..." : viewModel.processingMessage)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
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
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity)
            }
            .animation(.spring(response: 0.4, dampingFraction: 0.8), value: viewModel.lastRecording != nil)
        }
    }

    private var formattedDuration: String {
        let total = Int(viewModel.duration)
        let tenths = Int(viewModel.duration * 10) % 10
        return String(format: "%02d:%02d.%d", total / 60, total % 60, tenths)
    }
}

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
                    Image(systemName: isRecording ? "stop.fill" : "mic.fill")
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundStyle(.white)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isFinishing)
        }
        .disabled(isFinishing)
        .scaleEffect(isRecording ? 1.1 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: isRecording)
        .animation(.easeInOut(duration: 0.2), value: isFinishing)
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
