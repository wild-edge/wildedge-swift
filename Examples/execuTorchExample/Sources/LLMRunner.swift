import Foundation
import ExecuTorchLLM
import WildEdge

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
    private var modelHandle: ModelHandle?

    var isModelLoaded: Bool { runner != nil }

    // MARK: - Model lifecycle

    func loadModel(modelURL: URL, tokenizerURL: URL) async throws {
        isLoading = true
        defer { isLoading = false }

        unload()

        let loadStart = Date()

        patchHFTokenizerIfNeeded(at: tokenizerURL)

        // TextRunner init is cheap; load() is the blocking C++ call
        let r = TextRunner(modelPath: modelURL.path, tokenizerPath: tokenizerURL.path)

        // load() blocks the calling thread — run off the main actor
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

        let loadDurationMs = Int(Date().timeIntervalSince(loadStart) * 1000)
        let modelId = modelURL.deletingPathExtension().lastPathComponent
        let handle = WildEdge.shared.registerModel(
            modelId: modelId,
            info: ModelInfo(
                modelName: modelId,
                modelSource: modelURL.lastPathComponent,
                modelFormat: "pte"
            )
        )
        handle.trackLoad(durationMs: loadDurationMs, accelerator: .cpu, success: true)
        modelHandle = handle
    }

    func unload() {
        generationTask?.cancel()
        runner?.stop()
        runner?.reset()
        runner = nil
        modelHandle?.trackUnload(reason: "explicit")
        modelHandle = nil
        isGenerating = false
        output = ""
        modelInfo = ""
    }

    // MARK: - Generation

    func generate(prompt: String, maxNewTokens: Int = 512) {
        guard let r = runner else { return }

        // Stop and reset any in-flight generation before starting a new one
        runner?.stop()
        generationTask?.cancel()
        output = ""
        isGenerating = true

        generationTask = Task.detached(priority: .userInitiated) { [weak self] in
            defer {
                Task { @MainActor [weak self] in self?.isGenerating = false }
            }

            let genStart = Date()
            var tokensOut = 0
            var stopReason = "max_tokens"

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
                    tokensOut += 1
                    Task { @MainActor [weak self] in self?.output += token }
                }
            } catch {
                if Task.isCancelled {
                    stopReason = "cancelled"
                } else {
                    stopReason = "error"
                    Task { @MainActor [weak self] in
                        self?.output = "[Error: \(error.localizedDescription)]"
                    }
                }
            }

            // Reset KV cache so the next generate() starts from a clean state
            r.reset()

            let durationMs = Int(Date().timeIntervalSince(genStart) * 1000)
            let tps = durationMs > 0 ? Double(tokensOut) / (Double(durationMs) / 1000.0) : 0

            // ExecuTorch exposes no token-count API. analyzeText gives a word-based
            // estimate for tokensIn; tokensOut is the exact callback-counted value.
            let inputMeta = WildEdge.analyzeText(prompt).toMap()
            let outputMeta = GenerationOutputMeta(
                tokensOut: tokensOut,
                tokensPerSecond: tps,
                stopReason: stopReason
            ).toMap()

            await MainActor.run { [weak self] in
                self?.modelHandle?.trackInference(
                    durationMs: durationMs,
                    inputModality: .text,
                    outputModality: .generation,
                    inputMeta: inputMeta,
                    outputMeta: outputMeta,
                    generationConfig: GenerationConfig(
                        temperature: 0.8,
                        maxTokens: maxNewTokens
                    ).toMap()
                )
            }
        }
    }

    func stop() {
        runner?.stop()
        generationTask?.cancel()
        isGenerating = false
    }

    // MARK: - Tokenizer patching

    // ExecuTorch's RE2 engine doesn't support PCRE features used by HuggingFace tokenizers.
    // This patches the JSON file in-place once so subsequent loads skip it (the patterns
    // won't be present after the first patch).
    private func patchHFTokenizerIfNeeded(at url: URL) {
        guard url.pathExtension == "json",
              let data = try? Data(contentsOf: url),
              var content = String(data: data, encoding: .utf8),
              content.contains("(?i:") || content.contains("(?!") else { return }

        // 1. (?i:'s|'t|...) — inline case-insensitive flag, not supported by RE2.
        //    Expand to explicit upper/lowercase alternatives.
        content = content.replacingOccurrences(
            of: "(?i:'s|'t|'re|'ve|'m|'ll|'d)",
            with: "(?:'[sS]|'[tT]|'[rR][eE]|'[vV][eE]|'[mM]|'[lL][lL]|'[dD])"
        )

        // 2. \s+(?!\S)|\s+ — negative lookahead, not supported by RE2.
        //    The two alternatives simplify to just \s+ (the second arm already covers
        //    every match the first arm would produce).
        //    In the JSON file backslashes are doubled, so \s appears as \\s.
        content = content.replacingOccurrences(
            of: "\\\\s+(?!\\\\S)|\\\\s+",
            with: "\\\\s+"
        )

        try? content.write(to: url, atomically: true, encoding: .utf8)
    }
}
