@preconcurrency import AVFoundation
import Foundation

#if canImport(LlamaSwift)
import LlamaSwift
#endif

struct LlamaMultimodalToolCallResult {
    let toolJSON: String
    let rawText: String
}

actor LlamaMultimodalSpeechToToolModel {
    static let shared = LlamaMultimodalSpeechToToolModel()

    private let modelManager = VoiceRecorderModelManager.shared
    private var loadedConfiguration: BenchmarkTextToToolModel?

    #if canImport(LlamaSwift)
    private var didInitializeBackend = false
    private var loadedModel: OpaquePointer?
    private var loadedMultimodalContext: OpaquePointer?
    private var loadedVocab: OpaquePointer?
    private var loadedPromptEnvelope: MultimodalPromptEnvelope?

    private enum MultimodalPromptMode: String {
        case toolJSON = "tool_json"
        case transcribe
    }
    #endif

    private init() {
    }

    deinit {
        #if canImport(LlamaSwift)
        if let loadedMultimodalContext {
            mtmd_free(loadedMultimodalContext)
        }
        if let loadedModel {
            llama_model_free(loadedModel)
        }
        #endif
    }

    func toolCall(
        fromAudio url: URL,
        model: BenchmarkTextToToolModel,
        progressHandler: (@Sendable (_ progress: Double, _ speed: Int64) -> Void)? = nil
    ) async throws -> String {
        let result = try await toolCallResult(
            fromAudio: url,
            model: model,
            progressHandler: progressHandler
        )
        return result.toolJSON
    }

    func toolCallResult(
        fromAudio url: URL,
        model: BenchmarkTextToToolModel,
        progressHandler: (@Sendable (_ progress: Double, _ speed: Int64) -> Void)? = nil
    ) async throws -> LlamaMultimodalToolCallResult {
        guard model.provider == "llama_cpp_mtmd",
              model.modelFormat == "gguf"
        else {
            throw SpeechTranscriptionError.transcriptionFailed(
                "\(model.displayName) is not configured for local llama.cpp multimodal inference."
            )
        }

        #if canImport(LlamaSwift)
        print("LlamaMultimodal speech_to_tool preparing model: \(model.modelId), provider=\(model.provider), format=\(model.modelFormat), quantization=\(model.quantization)")
        let modelURL = try await prepareModelAsset(model, progressHandler: progressHandler)
        print("LlamaMultimodal speech_to_tool model ready: \(modelURL.lastPathComponent)")
        let projectorURL = try await prepareProjectorAsset(model, progressHandler: progressHandler)
        print("LlamaMultimodal speech_to_tool projector ready: \(projectorURL.lastPathComponent)")
        try loadModelIfNeeded(model, modelURL: modelURL, projectorURL: projectorURL)
        print("LlamaMultimodal speech_to_tool loaded: \(model.modelId)")
        return try generateToolCallResult(fromAudio: url, model: model)
        #else
        throw SpeechTranscriptionError.transcriptionFailed(
            "llama.cpp multimodal runtime is not linked in this build. Cannot run \(model.displayName)."
        )
        #endif
    }

    private func prepareModelAsset(
        _ model: BenchmarkTextToToolModel,
        progressHandler: (@Sendable (_ progress: Double, _ speed: Int64) -> Void)?
    ) async throws -> URL {
        guard let url = try await modelManager.prepare(
            .gguf(model),
            progressHandler: { progress in
                guard progress.phase == .downloading,
                      let fraction = progress.progress
                else {
                    return
                }
                progressHandler?(fraction * 0.5, progress.speedBytesPerSecond)
            }
        ) else {
            throw SpeechTranscriptionError.transcriptionFailed("\(model.displayName) did not resolve to a local GGUF file.")
        }
        return url
    }

    private func prepareProjectorAsset(
        _ model: BenchmarkTextToToolModel,
        progressHandler: (@Sendable (_ progress: Double, _ speed: Int64) -> Void)?
    ) async throws -> URL {
        guard let url = try await modelManager.prepare(
            .ggufProjector(model),
            progressHandler: { progress in
                guard progress.phase == .downloading,
                      let fraction = progress.progress
                else {
                    return
                }
                progressHandler?(0.5 + fraction * 0.5, progress.speedBytesPerSecond)
            }
        ) else {
            throw SpeechTranscriptionError.transcriptionFailed("\(model.displayName) did not resolve to a local mmproj file.")
        }
        return url
    }

    #if canImport(LlamaSwift)
    private func loadModelIfNeeded(
        _ model: BenchmarkTextToToolModel,
        modelURL: URL,
        projectorURL: URL
    ) throws {
        if loadedConfiguration == model,
           loadedModel != nil,
           loadedMultimodalContext != nil,
           loadedVocab != nil {
            print("LlamaMultimodal speech_to_tool reusing loaded model: \(model.modelId)")
            return
        }

        if didInitializeBackend == false {
            ggml_backend_load_all()
            llama_backend_init()
            didInitializeBackend = true
        }

        if let loadedMultimodalContext {
            mtmd_free(loadedMultimodalContext)
        }
        if let loadedModel {
            llama_model_free(loadedModel)
        }
        loadedModel = nil
        loadedMultimodalContext = nil
        loadedVocab = nil
        loadedPromptEnvelope = nil
        loadedConfiguration = nil

        var modelParams = llama_model_default_params()
        modelParams.n_gpu_layers = 99
        modelParams.use_mmap = true
        modelParams.use_mlock = true
        modelParams.check_tensors = true
        print("LlamaMultimodal GPU support: llama_supports_gpu_offload=\(llama_supports_gpu_offload()), requested_n_gpu_layers=\(modelParams.n_gpu_layers), use_mmap=\(modelParams.use_mmap), use_mlock=\(modelParams.use_mlock)")

        print("LlamaMultimodal loading llama model: \(modelURL.lastPathComponent)")
        let llamaModel = modelURL.path.withCString { path in
            llama_model_load_from_file(path, modelParams)
        }
        guard let llamaModel else {
            throw SpeechTranscriptionError.transcriptionFailed(
                "llama.cpp could not load \(model.displayName) from \(modelURL.lastPathComponent)."
            )
        }

        guard let vocab = llama_model_get_vocab(llamaModel) else {
            llama_model_free(llamaModel)
            throw SpeechTranscriptionError.transcriptionFailed(
                "llama.cpp loaded \(model.displayName), but the model vocabulary is unavailable."
            )
        }

        var mtmdParams = mtmd_context_params_default()
        mtmdParams.use_gpu = true
        mtmdParams.print_timings = true
        mtmdParams.n_threads = Int32(max(1, min(4, ProcessInfo.processInfo.activeProcessorCount)))
        mtmdParams.flash_attn_type = LLAMA_FLASH_ATTN_TYPE_AUTO
        mtmdParams.warmup = false
        print("LlamaMultimodal projector offload params: use_gpu=\(mtmdParams.use_gpu), flash_attn=\(String(cString: llama_flash_attn_type_name(mtmdParams.flash_attn_type))), threads=\(mtmdParams.n_threads), warmup=\(mtmdParams.warmup)")

        print("LlamaMultimodal loading projector: \(projectorURL.lastPathComponent)")
        let multimodalContext = projectorURL.path.withCString { path in
            mtmd_init_from_file(path, llamaModel, mtmdParams)
        }
        guard let multimodalContext else {
            llama_model_free(llamaModel)
            throw SpeechTranscriptionError.transcriptionFailed(
                "libmtmd could not load \(model.displayName) projector from \(projectorURL.lastPathComponent)."
            )
        }

        guard mtmd_support_audio(multimodalContext) else {
            mtmd_free(multimodalContext)
            llama_model_free(llamaModel)
            throw SpeechTranscriptionError.transcriptionFailed(
                "\(model.displayName) multimodal projector does not report audio support."
            )
        }

        loadedModel = llamaModel
        loadedVocab = vocab
        loadedMultimodalContext = multimodalContext
        loadedConfiguration = model
        print("LlamaMultimodal projector reports audio support for \(model.modelId)")
    }

    private func generateToolCallResult(
        fromAudio audioURL: URL,
        model: BenchmarkTextToToolModel
    ) throws -> LlamaMultimodalToolCallResult {
        guard let loadedModel,
              let loadedVocab,
              let loadedMultimodalContext
        else {
            throw SpeechTranscriptionError.transcriptionFailed("\(model.displayName) is not loaded.")
        }

        let totalStart = Date()
        var contextParams = llama_context_default_params()
        contextParams.n_ctx = UInt32(max(512, model.contextSize))
        contextParams.n_batch = min(contextParams.n_ctx, 2048)
        contextParams.n_ubatch = min(contextParams.n_batch, 512)
        let threads = Int32(max(1, min(4, ProcessInfo.processInfo.activeProcessorCount)))
        contextParams.n_threads = threads
        contextParams.n_threads_batch = threads
        contextParams.flash_attn_type = LLAMA_FLASH_ATTN_TYPE_AUTO
        contextParams.offload_kqv = true
        contextParams.op_offload = true
        print("LlamaMultimodal runtime params: n_ctx=\(contextParams.n_ctx), n_batch=\(contextParams.n_batch), n_ubatch=\(contextParams.n_ubatch), threads=\(threads), max_output_tokens=\(model.maxGenerationTokens), offload_kqv=\(contextParams.offload_kqv), op_offload=\(contextParams.op_offload), flash_attn=\(String(cString: llama_flash_attn_type_name(contextParams.flash_attn_type)))")

        let contextStart = Date()
        guard let context = llama_init_from_model(loadedModel, contextParams) else {
            throw SpeechTranscriptionError.transcriptionFailed(
                "llama.cpp could not create a context for \(model.displayName)."
            )
        }
        let contextInitMs = Self.elapsedMilliseconds(since: contextStart)
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

        let audioSampleRate = mtmd_get_audio_sample_rate(loadedMultimodalContext)
        guard audioSampleRate > 0 else {
            throw SpeechTranscriptionError.transcriptionFailed(
                "\(model.displayName) did not provide an audio sample rate."
            )
        }

        let decodeAudioStart = Date()
        let samples = try Self.decodeAudioSamples(from: audioURL, targetSampleRate: Double(audioSampleRate))
        let decodeAudioMs = Self.elapsedMilliseconds(since: decodeAudioStart)
        guard samples.isEmpty == false else {
            throw SpeechTranscriptionError.transcriptionFailed("\(model.displayName) audio input is empty.")
        }
        print("LlamaMultimodal decoded audio: file=\(audioURL.lastPathComponent), sample_rate=\(audioSampleRate), samples=\(samples.count), duration_seconds=\(String(format: "%.3f", Double(samples.count) / Double(audioSampleRate)))")

        let bitmapStart = Date()
        guard let bitmap = samples.withUnsafeBufferPointer({ buffer in
            mtmd_bitmap_init_from_audio(buffer.count, buffer.baseAddress)
        }) else {
            throw SpeechTranscriptionError.transcriptionFailed(
                "libmtmd could not create an audio bitmap for \(audioURL.lastPathComponent)."
            )
        }
        let bitmapMs = Self.elapsedMilliseconds(since: bitmapStart)
        defer {
            mtmd_bitmap_free(bitmap)
        }

        guard let chunks = mtmd_input_chunks_init() else {
            throw SpeechTranscriptionError.transcriptionFailed("libmtmd could not create input chunks.")
        }
        defer {
            mtmd_input_chunks_free(chunks)
        }

        let promptMode = Self.promptMode(for: model)
        let generationPrefill = Self.generationPrefill(for: promptMode, model: model)
        let prompt = prompt(loadedModel: loadedModel, model: model, mode: promptMode) + generationPrefill
        print("LlamaMultimodal prompt mode: \(promptMode.rawValue), prompt_chars=\(prompt.count), context_tokens=\(contextParams.n_ctx), max_output_tokens=\(model.maxGenerationTokens), prefill_chars=\(generationPrefill.count)")
        Self.logText("LlamaMultimodal rendered prompt", prompt)
        var bitmapPointers: [OpaquePointer?] = [bitmap]
        let tokenizeStart = Date()
        let tokenizeStatus = prompt.withCString { promptPointer in
            var inputText = mtmd_input_text(
                text: promptPointer,
                add_special: false,
                parse_special: true
            )
            return bitmapPointers.withUnsafeMutableBufferPointer { bitmapBuffer in
                mtmd_tokenize(
                    loadedMultimodalContext,
                    chunks,
                    &inputText,
                    bitmapBuffer.baseAddress,
                    bitmapBuffer.count
                )
            }
        }
        let tokenizeMs = Self.elapsedMilliseconds(since: tokenizeStart)
        guard tokenizeStatus == 0 else {
            throw SpeechTranscriptionError.transcriptionFailed(
                "libmtmd tokenization failed with status \(tokenizeStatus)."
            )
        }
        print("LlamaMultimodal tokenized multimodal prompt")

        var nPast: llama_pos = 0
        let evalStart = Date()
        let evalStatus = mtmd_helper_eval_chunks(
            loadedMultimodalContext,
            context,
            chunks,
            0,
            0,
            Int32(contextParams.n_batch),
            true,
            &nPast
        )
        let evalChunksMs = Self.elapsedMilliseconds(since: evalStart)
        guard evalStatus == 0 else {
            throw SpeechTranscriptionError.transcriptionFailed(
                "libmtmd prompt evaluation failed with status \(evalStatus)."
            )
        }
        print("LlamaMultimodal evaluated audio prompt: input_positions=\(nPast)")

        var generated = generationPrefill
        var firstJSONObject: String?
        var generatedTokenCount = 0
        var stopReason = "max_tokens"
        let generationStart = Date()
        var firstTokenMs: Int?
        for _ in 0..<max(1, model.maxGenerationTokens) {
            let token = llama_sampler_sample(sampler, context, -1)
            if firstTokenMs == nil {
                firstTokenMs = Self.elapsedMilliseconds(since: generationStart)
            }
            if llama_vocab_is_eog(loadedVocab, token) {
                stopReason = "eog"
                break
            }
            llama_sampler_accept(sampler, token)

            generated += piece(for: token, vocab: loadedVocab)
            generatedTokenCount += 1
            if promptMode == .toolJSON,
               let jsonObject = ToolCallJSON.rootJSONObjectString(from: generated) {
                firstJSONObject = jsonObject
                stopReason = "root_json_complete"
                break
            }

            try decode([token], context: context)
        }
        let generationMs = Self.elapsedMilliseconds(since: generationStart)

        let trimmed = (firstJSONObject ?? generated).trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            throw SpeechTranscriptionError.transcriptionFailed("\(model.displayName) returned no text output.")
        }
        let rawGenerated = generated.trimmingCharacters(in: .whitespacesAndNewlines)
        print("LlamaMultimodal generated stream complete: stop_reason=\(stopReason), input_positions=\(nPast), output_tokens=\(generatedTokenCount), raw_chars=\(rawGenerated.count)")
        print("LlamaMultimodal timings: context_init_ms=\(contextInitMs), decode_audio_ms=\(decodeAudioMs), bitmap_ms=\(bitmapMs), tokenize_ms=\(tokenizeMs), eval_chunks_ms=\(evalChunksMs), generation_ms=\(generationMs), first_token_ms=\(firstTokenMs ?? -1), total_ms=\(Self.elapsedMilliseconds(since: totalStart)), n_batch=\(contextParams.n_batch), n_ubatch=\(contextParams.n_ubatch)")
        Self.logText("LlamaMultimodal generated raw stream", rawGenerated)

        if promptMode == .transcribe {
            let transcript = ToolCallJSON.textWithoutThinkBlocks(from: trimmed)
            return LlamaMultimodalToolCallResult(toolJSON: transcript, rawText: rawGenerated)
        }

        let rawParse = ToolCallJSON.parseAndValidate(from: trimmed)
        print("LlamaMultimodal raw JSON parse: success=\(rawParse.parsedSuccessfully), error=\(rawParse.error ?? "none"), canonical=\(rawParse.canonicalJSON ?? "")")
        let toolJSONOutput = ToolCallJSON.completedValidRootToolCallJSONString(from: trimmed)
            ?? ToolCallJSON.firstValidToolCallJSONString(from: trimmed)
            ?? ToolCallJSON.rootJSONObjectString(from: trimmed)
            ?? ToolCallJSON.textWithoutThinkBlocks(from: trimmed)
        let extractedParse = ToolCallJSON.parseAndValidate(from: toolJSONOutput)
        print("LlamaMultimodal extracted JSON parse: success=\(extractedParse.parsedSuccessfully), error=\(extractedParse.error ?? "none"), canonical=\(extractedParse.canonicalJSON ?? "")")
        Self.logText("LlamaMultimodal extracted tool JSON output", toolJSONOutput)
        return LlamaMultimodalToolCallResult(toolJSON: toolJSONOutput, rawText: rawGenerated)
    }

    private func prompt(
        loadedModel: OpaquePointer,
        model: BenchmarkTextToToolModel,
        mode: MultimodalPromptMode
    ) -> String {
        let promptKey = "\(model.signature):\(mode.rawValue)"
        if let loadedPromptEnvelope,
           loadedPromptEnvelope.key == promptKey {
            return loadedPromptEnvelope.renderedPrompt
        }
        let marker = String(cString: mtmd_default_marker())
        let systemPrompt = Self.systemPrompt(for: mode, model: model)
        let userPrompt = Self.userPrompt(for: mode, model: model, marker: marker)
        let renderedPrompt = Self.chatPrompt(
            systemPrompt: systemPrompt,
            userPrompt: userPrompt,
            loadedModel: loadedModel
        ) ?? "\(systemPrompt)\n\n\(userPrompt)"
        let envelope = MultimodalPromptEnvelope(key: promptKey, renderedPrompt: renderedPrompt)
        loadedPromptEnvelope = envelope
        return renderedPrompt
    }

    private nonisolated static func promptMode(for model: BenchmarkTextToToolModel) -> MultimodalPromptMode {
        .toolJSON
    }

    private nonisolated static func generationPrefill(
        for mode: MultimodalPromptMode,
        model: BenchmarkTextToToolModel
    ) -> String {
        switch mode {
        case .toolJSON:
            return jsonObjectPrefill
        case .transcribe:
            return ""
        }
    }

    private nonisolated static func systemPrompt(
        for mode: MultimodalPromptMode,
        model: BenchmarkTextToToolModel
    ) -> String {
        switch mode {
        case .toolJSON:
            if model.kind == .qwen3ASRZeroPointSixB {
                return ToolCallPromptBuilder.qwenASRSpeechToToolSystemPrompt
            }
            return ToolCallPromptBuilder.speechToToolSystemPrompt
        case .transcribe:
            return ""
        }
    }

    private nonisolated static func userPrompt(
        for mode: MultimodalPromptMode,
        model: BenchmarkTextToToolModel,
        marker: String
    ) -> String {
        switch mode {
        case .toolJSON:
            if model.kind == .qwen3ASRZeroPointSixB {
                return "\(ToolCallPromptBuilder.qwenASRSpeechToToolUserPrompt())\n\(marker)\nJSON:"
            }
            return "\(ToolCallPromptBuilder.speechToToolUserPrompt())\n\(marker)"
        case .transcribe:
            return "transcribe\n\(marker)"
        }
    }

    private nonisolated static func chatPrompt(
        systemPrompt: String,
        userPrompt: String,
        loadedModel: OpaquePointer
    ) -> String? {
        guard let template = llama_model_chat_template(loadedModel, nil) else {
            return nil
        }

        return "system".withCString { systemRolePointer in
            "user".withCString { userRolePointer in
                systemPrompt.withCString { systemPromptPointer in
                    userPrompt.withCString { userPromptPointer in
                        var messages = [
                            llama_chat_message(role: systemRolePointer, content: systemPromptPointer),
                            llama_chat_message(role: userRolePointer, content: userPromptPointer)
                        ]
                        let requiredLength = llama_chat_apply_template(
                            template,
                            &messages,
                            messages.count,
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
                            &messages,
                            messages.count,
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
        }
    }

    private func decode(
        _ tokens: [llama_token],
        context: OpaquePointer
    ) throws {
        var mutableTokens = tokens
        let status = mutableTokens.withUnsafeMutableBufferPointer { tokenBuffer -> Int32 in
            let batch = llama_batch_get_one(tokenBuffer.baseAddress, Int32(tokenBuffer.count))
            return llama_decode(context, batch)
        }
        guard status == 0 else {
            throw SpeechTranscriptionError.transcriptionFailed("llama.cpp decode failed with status \(status).")
        }
    }

    private func piece(
        for token: llama_token,
        vocab: OpaquePointer
    ) -> String {
        var buffer = [CChar](repeating: 0, count: 32)
        var count = llama_token_to_piece(vocab, token, &buffer, Int32(buffer.count), 0, false)
        if count < 0 {
            buffer = [CChar](repeating: 0, count: Int(-count))
            count = llama_token_to_piece(vocab, token, &buffer, Int32(buffer.count), 0, false)
        }
        guard count > 0 else { return "" }
        return String(decoding: buffer.prefix(Int(count)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private nonisolated static func logText(_ label: String, _ text: String, limit: Int = 8_000) {
        let suffix: String
        let body: String
        if text.count > limit {
            body = String(text.prefix(limit))
            suffix = "\n... truncated \(text.count - limit) chars"
        } else {
            body = text
            suffix = ""
        }
        print("\(label) BEGIN\n\(body)\(suffix)\n\(label) END")
    }

    private nonisolated static func elapsedMilliseconds(since start: Date) -> Int {
        Int((Date().timeIntervalSince(start) * 1000).rounded())
    }

    private nonisolated static func decodeAudioSamples(
        from url: URL,
        targetSampleRate: Double
    ) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let inputFormat = file.processingFormat
        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw SpeechTranscriptionError.transcriptionFailed("Could not create PCM output format.")
        }

        let inputFrameCapacity = AVAudioFrameCount(file.length)
        guard let inputBuffer = AVAudioPCMBuffer(
            pcmFormat: inputFormat,
            frameCapacity: inputFrameCapacity
        ) else {
            throw SpeechTranscriptionError.transcriptionFailed("Could not allocate audio input buffer.")
        }
        try file.read(into: inputBuffer)

        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw SpeechTranscriptionError.transcriptionFailed("Could not create audio converter.")
        }

        let sampleRateRatio = targetSampleRate / inputFormat.sampleRate
        let outputFrameCapacity = AVAudioFrameCount(Double(inputBuffer.frameLength) * sampleRateRatio) + 1024
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: outputFrameCapacity
        ) else {
            throw SpeechTranscriptionError.transcriptionFailed("Could not allocate audio output buffer.")
        }

        var didProvideInput = false
        var conversionError: NSError?
        converter.convert(to: outputBuffer, error: &conversionError) { _, status in
            if didProvideInput {
                status.pointee = .noDataNow
                return nil
            }
            didProvideInput = true
            status.pointee = .haveData
            return inputBuffer
        }
        if let conversionError {
            throw conversionError
        }

        guard let channel = outputBuffer.floatChannelData?[0] else {
            throw SpeechTranscriptionError.transcriptionFailed("Converted audio has no float channel data.")
        }

        return Array(UnsafeBufferPointer(start: channel, count: Int(outputBuffer.frameLength)))
    }

    private static let jsonObjectPrefill = "{"
    #endif
}

private struct MultimodalPromptEnvelope {
    let key: String
    let renderedPrompt: String
}
