import Foundation
#if canImport(LlamaSwift)
import LlamaSwift
#endif
#if canImport(OnnxRuntimeBindings)
import OnnxRuntimeBindings
#endif

actor LlamaCppBenchmarkTextToToolModel {
    static let shared = LlamaCppBenchmarkTextToToolModel()

    private let modelManager = VoiceRecorderModelManager.shared
    private var loadedConfiguration: BenchmarkTextToToolModel?

    #if canImport(LlamaSwift)
    private var didInitializeBackend = false
    private var loadedModel: OpaquePointer?
    private var loadedVocab: OpaquePointer?
    private var loadedPromptEnvelope: PromptEnvelope?
    #endif

    private init() {
    }

    deinit {
        #if canImport(LlamaSwift)
        if let loadedModel {
            llama_model_free(loadedModel)
        }
        #endif
    }

    func downloadModel(
        _ model: BenchmarkTextToToolModel,
        progressHandler: (@Sendable (_ progress: Double, _ speed: Int64) -> Void)? = nil
    ) async throws -> URL {
        guard Self.supportsTextInference(model) else {
            throw SpeechTranscriptionError.transcriptionFailed("\(model.displayName) is not a llama.cpp GGUF model.")
        }
        guard let url = try await modelManager.prepare(
            .gguf(model),
            progressHandler: { progress in
                guard progress.phase == .downloading,
                      let fraction = progress.progress
                else {
                    return
                }
                progressHandler?(fraction, progress.speedBytesPerSecond)
            }
        ) else {
            throw SpeechTranscriptionError.transcriptionFailed("\(model.displayName) did not resolve to a local GGUF file.")
        }
        return url
    }

    func modelStatus(_ model: BenchmarkTextToToolModel) async -> ModelAssetStatus {
        await modelManager.status(for: .gguf(model))
    }

    func prepareModel(
        _ model: BenchmarkTextToToolModel,
        progressHandler: (@Sendable (_ progress: Double, _ speed: Int64) -> Void)? = nil
    ) async throws {
        let modelURL = try await downloadModel(model, progressHandler: progressHandler)
        #if canImport(LlamaSwift)
        try loadModelIfNeeded(model, modelURL: modelURL)
        #endif
    }

    func toolCall(
        fromTranscript transcript: String,
        model: BenchmarkTextToToolModel,
        progressHandler: (@Sendable (_ progress: Double, _ speed: Int64) -> Void)? = nil
    ) async throws -> String {
        #if canImport(LlamaSwift)
        try await prepareModel(model, progressHandler: progressHandler)
        return try generateToolCall(fromTranscript: transcript, model: model)
        #else
        throw SpeechTranscriptionError.transcriptionFailed(
            "llama.cpp is not linked in this build. Cannot run \(model.displayName)."
        )
        #endif
    }

    private nonisolated static func supportsTextInference(_ model: BenchmarkTextToToolModel) -> Bool {
        (model.provider == "llama_cpp" || model.provider == "llama_cpp_mtmd")
            && model.modelFormat == "gguf"
    }

    #if canImport(LlamaSwift)
    private func loadModelIfNeeded(
        _ model: BenchmarkTextToToolModel,
        modelURL: URL
    ) throws {
        if loadedConfiguration == model, loadedModel != nil, loadedVocab != nil {
            return
        }

        if didInitializeBackend == false {
            llama_backend_init()
            didInitializeBackend = true
        }

        if let loadedModel {
            llama_model_free(loadedModel)
        }
        loadedModel = nil
        loadedVocab = nil
        loadedPromptEnvelope = nil
        loadedConfiguration = nil

        var modelParams = llama_model_default_params()
        modelParams.n_gpu_layers = 99
        modelParams.use_mmap = true
        modelParams.check_tensors = true

        let loaded = modelURL.path.withCString { path in
            llama_model_load_from_file(path, modelParams)
        }
        guard let loaded else {
            throw SpeechTranscriptionError.transcriptionFailed(
                "llama.cpp could not load \(model.displayName) from \(modelURL.lastPathComponent)."
            )
        }

        guard let vocab = llama_model_get_vocab(loaded) else {
            llama_model_free(loaded)
            throw SpeechTranscriptionError.transcriptionFailed(
                "llama.cpp loaded \(model.displayName), but the model vocabulary is unavailable."
            )
        }

        loadedModel = loaded
        loadedVocab = vocab
        loadedConfiguration = model
    }

    private func generateToolCall(
        fromTranscript transcript: String,
        model: BenchmarkTextToToolModel
    ) throws -> String {
        guard let loadedModel, let loadedVocab else {
            throw SpeechTranscriptionError.transcriptionFailed("\(model.displayName) is not loaded.")
        }

        var contextParams = llama_context_default_params()
        contextParams.n_ctx = UInt32(max(256, model.contextSize))
        contextParams.n_batch = contextParams.n_ctx
        contextParams.n_ubatch = min(contextParams.n_batch, 512)
        let threads = Int32(max(1, min(4, ProcessInfo.processInfo.activeProcessorCount)))
        contextParams.n_threads = threads
        contextParams.n_threads_batch = threads

        guard let context = llama_init_from_model(loadedModel, contextParams) else {
            throw SpeechTranscriptionError.transcriptionFailed(
                "llama.cpp could not create a context for \(model.displayName)."
            )
        }
        if let memory = llama_get_memory(context) {
            llama_memory_clear(memory, true)
        }
        defer {
            llama_free(context)
        }

        var samplerParams = llama_sampler_chain_default_params()
        samplerParams.no_perf = true
        guard let sampler = llama_sampler_chain_init(samplerParams),
              let greedySampler = llama_sampler_init_greedy()
        else {
            throw SpeechTranscriptionError.transcriptionFailed("llama.cpp could not create a greedy sampler.")
        }
        llama_sampler_chain_add(sampler, greedySampler)
        defer {
            llama_sampler_free(sampler)
        }

        let prompt = prompt(transcript: transcript, loadedModel: loadedModel) + Self.jsonObjectPrefill
        let promptTokens = try tokenize(prompt, vocab: loadedVocab)
        guard promptTokens.count < Int(contextParams.n_ctx) else {
            throw SpeechTranscriptionError.transcriptionFailed(
                "\(model.displayName) prompt is \(promptTokens.count) tokens, which exceeds context \(contextParams.n_ctx)."
            )
        }

        try decode(promptTokens, context: context)

        var generated = Self.jsonObjectPrefill
        for _ in 0..<max(1, model.maxGenerationTokens) {
            let token = llama_sampler_sample(sampler, context, -1)
            if llama_vocab_is_eog(loadedVocab, token) {
                break
            }

            generated += piece(for: token, vocab: loadedVocab)
            if ToolCallJSON.parseAndValidate(from: generated).parsedSuccessfully {
                break
            }

            try decode([token], context: context)
        }

        let trimmed = generated.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            throw SpeechTranscriptionError.transcriptionFailed("\(model.displayName) returned no text output.")
        }
        let cleaned = ToolCallJSON.textWithoutThinkBlocks(from: trimmed)
        return ToolCallJSON.firstValidToolCallJSONString(from: trimmed)
            ?? cleaned
    }

    private func prompt(
        transcript: String,
        loadedModel: OpaquePointer
    ) -> String {
        let envelope: PromptEnvelope
        if let cachedEnvelope = loadedPromptEnvelope {
            envelope = cachedEnvelope
        } else {
            envelope = Self.makePromptEnvelope(loadedModel: loadedModel)
            loadedPromptEnvelope = envelope
        }
        return envelope.prompt(transcript: transcript)
    }

    private nonisolated static func makePromptEnvelope(
        loadedModel: OpaquePointer
    ) -> PromptEnvelope {
        let userPrompt = ToolCallPromptBuilder.localTextToToolPrompt(transcript: transcriptPlaceholder)
        let renderedPrompt: String
        guard let template = llama_model_chat_template(loadedModel, nil),
              let chatPrompt = chatPrompt(userPrompt: userPrompt, template: template)
        else {
            renderedPrompt = userPrompt
            return PromptEnvelope(renderedPrompt: renderedPrompt, placeholder: transcriptPlaceholder)
        }
        renderedPrompt = chatPrompt
        return PromptEnvelope(renderedPrompt: renderedPrompt, placeholder: transcriptPlaceholder)
    }

    private nonisolated static func chatPrompt(
        userPrompt: String,
        template: UnsafePointer<CChar>
    ) -> String? {
        let role = "user"
        return role.withCString { rolePointer in
            userPrompt.withCString { contentPointer in
                var message = llama_chat_message(role: rolePointer, content: contentPointer)
                let requiredLength = llama_chat_apply_template(
                    template,
                    &message,
                    1,
                    true,
                    nil,
                    0
                )
                guard requiredLength > 0 else {
                    return nil
                }

                var buffer = [CChar](repeating: 0, count: Int(requiredLength) + 1)
                let writtenLength = llama_chat_apply_template(
                    template,
                    &message,
                    1,
                    true,
                    &buffer,
                    Int32(buffer.count)
                )
                guard writtenLength > 0 else {
                    return nil
                }
                return String(cString: buffer)
            }
        }
    }

    private nonisolated static let transcriptPlaceholder = "__WILDEDGE_CURRENT_TRANSCRIPT__"
    private nonisolated static let jsonObjectPrefill = "{"

    private struct PromptEnvelope {
        let prefix: String?
        let suffix: String?

        init(renderedPrompt: String, placeholder: String) {
            guard let range = renderedPrompt.range(of: placeholder) else {
                prefix = nil
                suffix = nil
                return
            }
            prefix = String(renderedPrompt[..<range.lowerBound])
            suffix = String(renderedPrompt[range.upperBound...])
        }

        func prompt(transcript: String) -> String {
            guard let prefix, let suffix else {
                return ToolCallPromptBuilder.localTextToToolPrompt(transcript: transcript)
            }
            return prefix + transcript + suffix
        }
    }

    private nonisolated func tokenize(
        _ text: String,
        vocab: OpaquePointer
    ) throws -> [llama_token] {
        let byteCount = text.lengthOfBytes(using: .utf8)
        var tokens = [llama_token](repeating: 0, count: max(32, byteCount + 16))

        let tokenCount = text.withCString { cString in
            llama_tokenize(
                vocab,
                cString,
                Int32(byteCount),
                &tokens,
                Int32(tokens.count),
                true,
                true
            )
        }

        if tokenCount == Int32.min {
            throw SpeechTranscriptionError.transcriptionFailed("llama.cpp tokenization overflowed.")
        }

        let resolvedCount: Int32
        if tokenCount < 0 {
            tokens = [llama_token](repeating: 0, count: Int(-tokenCount))
            resolvedCount = text.withCString { cString in
                llama_tokenize(
                    vocab,
                    cString,
                    Int32(byteCount),
                    &tokens,
                    Int32(tokens.count),
                    true,
                    true
                )
            }
        } else {
            resolvedCount = tokenCount
        }

        guard resolvedCount > 0 else {
            throw SpeechTranscriptionError.transcriptionFailed("llama.cpp produced no prompt tokens.")
        }
        return Array(tokens.prefix(Int(resolvedCount)))
    }

    private nonisolated func decode(
        _ tokens: [llama_token],
        context: OpaquePointer
    ) throws {
        var mutableTokens = tokens
        let status = mutableTokens.withUnsafeMutableBufferPointer { tokenBuffer in
            let batch = llama_batch_get_one(tokenBuffer.baseAddress, Int32(tokenBuffer.count))
            return llama_decode(context, batch)
        }
        guard status == 0 else {
            throw SpeechTranscriptionError.transcriptionFailed("llama.cpp decode failed with status \(status).")
        }
    }

    private nonisolated func piece(
        for token: llama_token,
        vocab: OpaquePointer
    ) -> String {
        var buffer = [CChar](repeating: 0, count: 64)
        var count = llama_token_to_piece(vocab, token, &buffer, Int32(buffer.count), 0, false)
        if count < 0 {
            buffer = [CChar](repeating: 0, count: Int(-count))
            count = llama_token_to_piece(vocab, token, &buffer, Int32(buffer.count), 0, false)
        }
        guard count > 0 else { return "" }
        let data = buffer.withUnsafeBufferPointer { pointer in
            Data(bytes: pointer.baseAddress!, count: Int(count))
        }
        return String(data: data, encoding: .utf8) ?? ""
    }
    #endif
}

actor OnnxBenchmarkTextToToolModel {
    static let shared = OnnxBenchmarkTextToToolModel()

    private init() {
    }

    func toolCall(fromTranscript transcript: String, model: BenchmarkTextToToolModel) async throws -> String {
        #if canImport(OnnxRuntimeBindings)
        _ = transcript
        _ = model
        throw SpeechTranscriptionError.transcriptionFailed(
            "ONNX Runtime is linked, but no autoregressive ONNX text-to-tool decoder and tokenizer are configured in this build."
        )
        #else
        _ = transcript
        _ = model
        throw SpeechTranscriptionError.transcriptionFailed("ONNX Runtime is not linked in this build.")
        #endif
    }
}
