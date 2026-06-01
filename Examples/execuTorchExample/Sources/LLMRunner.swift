import Foundation
import ExecuTorchLLM

// WildEdge telemetry is handled automatically by ExecuTorchLLMInterceptor —
// no manual trackLoad / trackInference / trackUnload calls needed here.

enum LLMError: LocalizedError {
    case notLoaded
    case loadFailed(String)

    var errorDescription: String? {
        switch self {
        case .notLoaded:          return "No model loaded."
        case .loadFailed(let m):  return "Failed to load model: \(m)"
        }
    }
}

@MainActor
final class LLMRunner: ObservableObject {
    @Published var output = ""
    @Published var isLoading = false
    @Published var isGenerating = false
    @Published var modelInfo = ""

    private var runner: TextRunner?
    private var generationTask: Task<Void, Never>?

    var isModelLoaded: Bool { runner != nil }

    // MARK: - Model lifecycle

    func loadModel(modelURL: URL, tokenizerURL: URL) async throws {
        isLoading = true
        defer { isLoading = false }

        unload()

        patchHFTokenizerIfNeeded(at: tokenizerURL)

        // TextRunner init is cheap; load() is the blocking C++ call.
        // ExecuTorchLLMInterceptor tracks the load duration automatically.
        let r = TextRunner(modelPath: modelURL.path, tokenizerPath: tokenizerURL.path)

        let loadTask = Task.detached(priority: .userInitiated) {
            try r.load()
        }
        do {
            try await loadTask.value
        } catch {
            throw LLMError.loadFailed(error.localizedDescription)
        }

        runner = r
        modelInfo = modelURL.deletingPathExtension().lastPathComponent
    }

    func unload() {
        generationTask?.cancel()
        runner?.stop()
        runner?.reset()
        runner = nil
        isGenerating = false
        output = ""
        modelInfo = ""
    }

    // MARK: - Generation

    func generate(prompt: String, maxNewTokens: Int = 512) {
        guard let r = runner else { return }

        runner?.stop()
        generationTask?.cancel()
        output = ""
        isGenerating = true

        generationTask = Task.detached(priority: .userInitiated) { [weak self] in
            defer {
                Task { @MainActor [weak self] in self?.isGenerating = false }
            }

            // ExecuTorchLLMInterceptor wraps this call automatically:
            // it counts tokens via the callback and emits trackInference on return.
            let config = Config { c in
                c.sequenceLength = maxNewTokens + 128
                c.maximumNewTokens = maxNewTokens
                c.temperature = 0.8
                c.isEchoEnabled = false
            }

            do {
                try r.generate(prompt, config) { [weak self] token in
                    if Task.isCancelled {
                        r.stop()
                        return
                    }
                    Task { @MainActor [weak self] in self?.output += token }
                }
            } catch {
                if !Task.isCancelled {
                    Task { @MainActor [weak self] in
                        self?.output = "[Error: \(error.localizedDescription)]"
                    }
                }
            }

            r.reset()
        }
    }

    func stop() {
        runner?.stop()
        generationTask?.cancel()
        isGenerating = false
    }

    // MARK: - Tokenizer patching

    // ExecuTorch's RE2 engine doesn't support PCRE features used by HuggingFace
    // tokenizers. Patches the JSON file in-place once — subsequent loads are no-ops
    // because the patterns won't be present after the first pass.
    private func patchHFTokenizerIfNeeded(at url: URL) {
        guard url.pathExtension == "json",
              let data = try? Data(contentsOf: url),
              var content = String(data: data, encoding: .utf8),
              content.contains("(?i:") || content.contains("(?!") else { return }

        // (?i:'s|'t|...) — inline case flag, unsupported by RE2
        content = content.replacingOccurrences(
            of: "(?i:'s|'t|'re|'ve|'m|'ll|'d)",
            with: "(?:'[sS]|'[tT]|'[rR][eE]|'[vV][eE]|'[mM]|'[lL][lL]|'[dD])"
        )

        // \s+(?!\S)|\s+ — negative lookahead, unsupported by RE2; simplifies to \s+
        content = content.replacingOccurrences(
            of: "\\\\s+(?!\\\\S)|\\\\s+",
            with: "\\\\s+"
        )

        try? content.write(to: url, atomically: true, encoding: .utf8)
    }
}
