import Foundation
#if canImport(LlamaSwift)
import LlamaSwift
#endif
#if canImport(OnnxRuntimeBindings)
import OnnxRuntimeBindings
#endif

actor LlamaCppBenchmarkTextToToolModel {
    static let shared = LlamaCppBenchmarkTextToToolModel()

    private let fileStore = BenchmarkTextToToolModelFileStore.shared
    private var loadedConfiguration: BenchmarkTextToToolModel?

    #if canImport(LlamaSwift)
    private var didInitializeBackend = false
    private var loadedModel: OpaquePointer?
    private var loadedVocab: OpaquePointer?
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
        guard model.provider == "llama_cpp", model.modelFormat == "gguf" else {
            throw SpeechTranscriptionError.transcriptionFailed("\(model.displayName) is not a llama.cpp GGUF model.")
        }
        return try await fileStore.downloadIfNeeded(model: model, progressHandler: progressHandler)
    }

    func toolCall(
        fromTranscript transcript: String,
        model: BenchmarkTextToToolModel,
        progressHandler: (@Sendable (_ progress: Double, _ speed: Int64) -> Void)? = nil
    ) async throws -> String {
        #if canImport(LlamaSwift)
        let modelURL = try await downloadModel(model, progressHandler: progressHandler)
        try loadModelIfNeeded(model, modelURL: modelURL)
        return try generateToolCall(fromTranscript: transcript, model: model)
        #else
        throw SpeechTranscriptionError.transcriptionFailed(
            "llama.cpp is not linked in this build. Cannot run \(model.displayName)."
        )
        #endif
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
        contextParams.n_batch = min(contextParams.n_ctx, 512)
        contextParams.n_ubatch = min(contextParams.n_batch, 512)
        let threads = Int32(max(1, min(4, ProcessInfo.processInfo.activeProcessorCount)))
        contextParams.n_threads = threads
        contextParams.n_threads_batch = threads

        guard let context = llama_init_from_model(loadedModel, contextParams) else {
            throw SpeechTranscriptionError.transcriptionFailed(
                "llama.cpp could not create a context for \(model.displayName)."
            )
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

        let prompt = Self.prompt(transcript: transcript)
        let promptTokens = try tokenize(prompt, vocab: loadedVocab)
        guard promptTokens.count < Int(contextParams.n_ctx) else {
            throw SpeechTranscriptionError.transcriptionFailed(
                "\(model.displayName) prompt is \(promptTokens.count) tokens, which exceeds context \(contextParams.n_ctx)."
            )
        }

        try decode(promptTokens, context: context)

        var generated = ""
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
        return trimmed
    }

    private nonisolated static func prompt(transcript: String) -> String {
        ToolCallPromptBuilder.localTextToToolPrompt(transcript: transcript)
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

actor BenchmarkTextToToolModelFileStore {
    static let shared = BenchmarkTextToToolModelFileStore()

    private let fileManager = FileManager.default

    private init() {
    }

    func downloadIfNeeded(
        model: BenchmarkTextToToolModel,
        progressHandler: (@Sendable (_ progress: Double, _ speed: Int64) -> Void)? = nil
    ) async throws -> URL {
        let destinationURL = try localFileURL(for: model)
        if try existingFileIsPresent(at: destinationURL) {
            progressHandler?(1, 0)
            return destinationURL
        }

        guard let downloadURLString = model.downloadURLString,
              let downloadURL = URL(string: downloadURLString)
        else {
            throw SpeechTranscriptionError.transcriptionFailed(
                "\(model.displayName) does not define a download URL."
            )
        }

        try fileManager.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let tempURL = destinationURL.appendingPathExtension("download")
        if fileManager.fileExists(atPath: tempURL.path) {
            try fileManager.removeItem(at: tempURL)
        }
        fileManager.createFile(atPath: tempURL.path, contents: nil)

        let (bytes, response) = try await URLSession.shared.bytes(from: downloadURL)
        if let httpResponse = response as? HTTPURLResponse,
           (200..<300).contains(httpResponse.statusCode) == false {
            throw SpeechTranscriptionError.transcriptionFailed(
                "\(model.displayName) download failed with HTTP \(httpResponse.statusCode)."
            )
        }

        let expectedLength = max(response.expectedContentLength, 0)
        let startedAt = Date()
        var receivedLength: Int64 = 0
        var chunk: [UInt8] = []
        chunk.reserveCapacity(64 * 1024)

        let handle = try FileHandle(forWritingTo: tempURL)
        do {
            for try await byte in bytes {
                chunk.append(byte)
                if chunk.count >= 64 * 1024 {
                    try handle.write(contentsOf: chunk)
                    receivedLength += Int64(chunk.count)
                    chunk.removeAll(keepingCapacity: true)
                    reportProgress(
                        receivedLength: receivedLength,
                        expectedLength: expectedLength,
                        startedAt: startedAt,
                        progressHandler: progressHandler
                    )
                }
            }

            if chunk.isEmpty == false {
                try handle.write(contentsOf: chunk)
                receivedLength += Int64(chunk.count)
                reportProgress(
                    receivedLength: receivedLength,
                    expectedLength: expectedLength,
                    startedAt: startedAt,
                    progressHandler: progressHandler
                )
            }
            try handle.close()
        } catch {
            try? handle.close()
            try? fileManager.removeItem(at: tempURL)
            throw error
        }

        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }
        try fileManager.moveItem(at: tempURL, to: destinationURL)
        progressHandler?(1, 0)
        return destinationURL
    }

    private func localFileURL(for model: BenchmarkTextToToolModel) throws -> URL {
        let baseDirectory = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let fileName = model.downloadFilename
            ?? model.modelName
            .replacingOccurrences(of: "/", with: "__")
            .appending(".gguf")
        return baseDirectory
            .appendingPathComponent("BenchmarkTextToToolModels", isDirectory: true)
            .appendingPathComponent(fileName, isDirectory: false)
    }

    private func existingFileIsPresent(at url: URL) throws -> Bool {
        guard fileManager.fileExists(atPath: url.path) else { return false }
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        return (values.fileSize ?? 0) > 0
    }

    private nonisolated func reportProgress(
        receivedLength: Int64,
        expectedLength: Int64,
        startedAt: Date,
        progressHandler: (@Sendable (_ progress: Double, _ speed: Int64) -> Void)?
    ) {
        let elapsed = max(Date().timeIntervalSince(startedAt), 0.1)
        let speed = Int64(Double(receivedLength) / elapsed)
        let progress = expectedLength > 0
            ? min(max(Double(receivedLength) / Double(expectedLength), 0), 1)
            : 0
        progressHandler?(progress, speed)
    }
}
