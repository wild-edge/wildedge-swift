import SwiftUI

struct ContentView: View {
    @StateObject private var runner = LLMRunner()
    @StateObject private var downloader = ModelDownloader()
    @State private var isShowingLibrary = false
    @State private var prompt = "Write a short poem about the ocean."
    @State private var errorMessage: String?
    @State private var showError = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Runs a local LLM fully on-device using ExecuTorch (XNNPACK backend). Download a model from the library or pick your own .pte file, then type a prompt and tap Generate to stream tokens — no internet connection required.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    modelSection
                    Divider()
                    promptSection

                    if !runner.output.isEmpty || runner.isGenerating {
                        outputSection
                    }
                }
                .padding()
            }
            .navigationTitle("ExecuTorch LLM")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                if runner.isModelLoaded {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Unload", role: .destructive) {
                            runner.unload()
                        }
                        .disabled(runner.isGenerating || runner.isLoading)
                    }
                }
            }
        }
        .sheet(isPresented: $isShowingLibrary) {
            ModelLibraryView(downloader: downloader) { modelURL, tokenizerURL in
                loadModel(modelURL: modelURL, tokenizerURL: tokenizerURL)
            }
        }
        .alert("Error", isPresented: $showError, presenting: errorMessage) { _ in
            Button("OK") {}
        } message: { msg in Text(msg) }
    }

    // MARK: - Sections

    @ViewBuilder
    private var modelSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                isShowingLibrary = true
            } label: {
                Label("Pick Model", systemImage: "arrow.down.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(runner.isLoading || runner.isGenerating)

            if runner.isLoading {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Loading model…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if !runner.modelInfo.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.caption)
                    Text(runner.modelInfo)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var promptSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Prompt")
                .font(.headline)

            TextEditor(text: $prompt)
                .frame(minHeight: 90, maxHeight: 160)
                .padding(8)
                .background(Color(.systemGray6))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .disabled(runner.isGenerating)

            Button {
                if runner.isGenerating {
                    runner.stop()
                } else {
                    runner.generate(prompt: prompt)
                }
            } label: {
                Label(
                    runner.isGenerating ? "Stop" : "Generate",
                    systemImage: runner.isGenerating ? "stop.circle.fill" : "play.fill"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(runner.isGenerating ? .red : .accentColor)
            .disabled(!runner.isModelLoaded || runner.isLoading)
        }
    }

    @ViewBuilder
    private var outputSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Output")
                    .font(.headline)
                Spacer()
                if runner.isGenerating {
                    ProgressView().scaleEffect(0.75)
                }
            }

            Text(runner.output.isEmpty ? " " : runner.output)
                .font(.system(.body, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Color(.systemGray6))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .textSelection(.enabled)
        }
    }

    // MARK: - Model loading

    private func loadModel(modelURL: URL, tokenizerURL: URL) {
        Task {
            do {
                try await runner.loadModel(modelURL: modelURL, tokenizerURL: tokenizerURL)
            } catch {
                errorMessage = error.localizedDescription
                showError = true
            }
        }
    }
}

#Preview {
    ContentView()
}
