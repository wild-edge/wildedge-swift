import Foundation
import llama
import WildEdge

enum LlamaError: LocalizedError {
    case modelLoadFailed
    case contextInitFailed

    var errorDescription: String? {
        switch self {
        case .modelLoadFailed: return "Failed to load model file. Make sure it is a valid GGUF file."
        case .contextInitFailed: return "Failed to create inference context. The model may be too large."
        }
    }
}

@MainActor
final class LlamaRunner: ObservableObject {
    @Published var output = ""
    @Published var isLoading = false
    @Published var isGenerating = false
    @Published var modelInfo = ""

    private var model: OpaquePointer?
    private var context: OpaquePointer?
    private var sampler: UnsafeMutablePointer<llama_sampler>?
    private var generationTask: Task<Void, Never>?
    private var modelHandle: ModelHandle?

    var isModelLoaded: Bool { model != nil }

    init() {
        llama_backend_init()
    }

    deinit {
        generationTask?.cancel()
        if let smpl = sampler { llama_sampler_free(smpl) }
        if let ctx = context { llama_free(ctx) }
        if let mdl = model { llama_model_free(mdl) }
        llama_backend_free()
    }

    // MARK: - Model lifecycle

    func loadModel(url: URL) async throws {
        isLoading = true
        defer { isLoading = false }

        freeAll()

        let loadStart = Date()

        var params = llama_model_default_params()
        params.n_gpu_layers = 99  // offload as many layers as Metal allows

        guard let m = url.path.withCString({ llama_model_load_from_file($0, params) }) else {
            modelHandle?.trackError(errorCode: "model_load_failed", errorMessage: LlamaError.modelLoadFailed.errorDescription)
            throw LlamaError.modelLoadFailed
        }
        model = m

        var ctxParams = llama_context_default_params()
        ctxParams.n_ctx = 2048
        ctxParams.n_batch = 512
        ctxParams.no_perf = false

        guard let ctx = llama_init_from_model(m, ctxParams) else {
            llama_model_free(m)
            model = nil
            modelHandle?.trackError(errorCode: "context_init_failed", errorMessage: LlamaError.contextInitFailed.errorDescription)
            throw LlamaError.contextInitFailed
        }
        context = ctx

        let sparams = llama_sampler_chain_default_params()
        let smpl = llama_sampler_chain_init(sparams)
        llama_sampler_chain_add(smpl, llama_sampler_init_top_k(40))
        llama_sampler_chain_add(smpl, llama_sampler_init_top_p(0.9, 1))
        llama_sampler_chain_add(smpl, llama_sampler_init_temp(0.7))
        llama_sampler_chain_add(smpl, llama_sampler_init_dist(UInt32.random(in: 0 ... .max)))
        sampler = smpl

        // Warmup: force all Metal tensors to be loaded and compiled now, during the
        // loading phase where blocking is expected. Without this, the first llama_decode
        // lazily loads GPU weights and can silently fail on iOS.
        let vocab0 = llama_model_get_vocab(m)
        llama_set_warmup(ctx, true)
        var warmupBatch = llama_batch_init(1, 0, 1)
        warmupBatch.n_tokens = 1
        warmupBatch.token?[0] = llama_vocab_bos(vocab0)
        warmupBatch.pos?[0] = 0
        warmupBatch.n_seq_id?[0] = 1
        warmupBatch.seq_id?[0]?[0] = 0
        warmupBatch.logits?[0] = 0
        llama_decode(ctx, warmupBatch)
        llama_batch_free(warmupBatch)
        llama_set_warmup(ctx, false)
        llama_memory_seq_rm(llama_get_memory(ctx), 0, -1, -1)

        var descBuf = [CChar](repeating: 0, count: 256)
        llama_model_desc(m, &descBuf, descBuf.count)
        let desc = String(cString: descBuf)
        let nParams = llama_model_n_params(m)
        modelInfo = "\(desc) · \(formatParamCount(nParams))"

        let loadDurationMs = Int(Date().timeIntervalSince(loadStart) * 1000)
        let modelId = url.deletingPathExtension().lastPathComponent
        let handle = WildEdge.shared.registerModel(
            modelId: modelId,
            info: ModelInfo(
                modelName: desc,
                modelSource: url.lastPathComponent,
                modelFormat: "gguf"
            )
        )
        handle.trackLoad(durationMs: loadDurationMs, accelerator: .gpu, success: true)
        handle.acceleratorActual = .gpu
        modelHandle = handle
    }

    func unloadModel() {
        freeAll()
    }

    // MARK: - Generation

    func generate(prompt: String, maxNewTokens: Int = 512) {
        guard let ctx = context, let mdl = model, let smpl = sampler else { return }

        generationTask?.cancel()
        output = ""
        isGenerating = true

        generationTask = Task.detached(priority: .userInitiated) { [weak self] in
            defer {
                Task { @MainActor [weak self] in self?.isGenerating = false }
            }

            var stopReason = "max_tokens"

            let vocab = llama_model_get_vocab(mdl)

            // Remove previous sequence from KV cache (safe no-op on a fresh context)
            // and reset sampler state. Snapshot perf counters for per-generation delta.
            let mem = llama_get_memory(ctx)
            llama_memory_seq_rm(mem, 0, -1, -1)
            llama_sampler_reset(smpl)
            let perfBefore = llama_perf_context(ctx)

            // Tokenize the prompt
            var tokens = [llama_token](repeating: 0, count: prompt.count + 64)
            let nTokens = prompt.withCString { cstr in
                llama_tokenize(vocab, cstr, Int32(prompt.utf8.count), &tokens, Int32(tokens.count), true, true)
            }
            guard nTokens > 0 else {
                await MainActor.run { [weak self] in self?.output = "[Error: tokenization returned 0 tokens]" }
                return
            }
            tokens = Array(tokens.prefix(Int(nTokens)))

            // Prefill: decode all prompt tokens in one batch
            var batch = llama_batch_init(512, 0, 1)
            defer { llama_batch_free(batch) }

            for (i, tok) in tokens.enumerated() {
                batch.token?[i] = tok
                batch.pos?[i] = llama_pos(i)
                batch.n_seq_id?[i] = 1
                batch.seq_id?[i]?[0] = 0
                // request logits only for the last token
                batch.logits?[i] = (i == tokens.count - 1) ? 1 : 0
            }
            batch.n_tokens = Int32(tokens.count)

            let prefillResult = llama_decode(ctx, batch)
            guard prefillResult == 0 else {
                await MainActor.run { [weak self] in self?.output = "[Error: prefill decode failed (\(prefillResult))]" }
                return
            }

            var nPos = Int32(tokens.count)

            for _ in 0 ..< maxNewTokens {
                if Task.isCancelled {
                    stopReason = "cancelled"
                    break
                }

                // Sample next token from the last decoded position
                let token = llama_sampler_sample(smpl, ctx, -1)

                // Stop at end-of-generation token
                if llama_vocab_is_eog(vocab, token) {
                    stopReason = "eos"
                    break
                }

                // Decode token to text
                var buf = [CChar](repeating: 0, count: 64)
                let len = llama_detokenize(vocab, [token], 1, &buf, Int32(buf.count), false, false)
                if len > 0 {
                    let bytes = buf.prefix(Int(len)).map { UInt8(bitPattern: $0) }
                    if let piece = String(bytes: bytes, encoding: .utf8) {
                        await MainActor.run { [weak self] in self?.output += piece }
                    }
                }

                llama_sampler_accept(smpl, token)

                // Decode the sampled token to advance the KV cache
                batch.n_tokens = 1
                batch.token?[0] = token
                batch.pos?[0] = nPos
                batch.n_seq_id?[0] = 1
                batch.seq_id?[0]?[0] = 0
                batch.logits?[0] = 1

                guard llama_decode(ctx, batch) == 0 else { break }
                nPos += 1
            }

            let perfAfter = llama_perf_context(ctx)
            let dtPrefill = perfAfter.t_p_eval_ms - perfBefore.t_p_eval_ms
            let dtEval    = perfAfter.t_eval_ms   - perfBefore.t_eval_ms
            let dTokensIn  = Int(perfAfter.n_p_eval - perfBefore.n_p_eval)
            let dTokensOut = Int(perfAfter.n_eval   - perfBefore.n_eval)
            let durationMs = Int(dtPrefill + dtEval)
            let tps = dtEval > 0 ? Double(dTokensOut) / (dtEval / 1000.0) : 0

            let inputMeta = TextInputMeta(
                charCount: prompt.count,
                tokenCount: dTokensIn
            ).toMap()
            let outputMeta = GenerationOutputMeta(
                tokensIn: dTokensIn,
                tokensOut: dTokensOut,
                timeToFirstTokenMs: Int(dtPrefill),
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
                        temperature: 0.7,
                        topP: 0.9,
                        topK: 40,
                        maxTokens: maxNewTokens
                    ).toMap()
                )
            }
        }
    }

    func stop() {
        generationTask?.cancel()
        isGenerating = false
    }

    // MARK: - Private

    private func freeAll() {
        generationTask?.cancel()
        isGenerating = false
        modelHandle?.trackUnload(reason: "explicit")
        modelHandle = nil
        if let smpl = sampler { llama_sampler_free(smpl) }
        if let ctx = context { llama_free(ctx) }
        if let mdl = model { llama_model_free(mdl) }
        sampler = nil
        context = nil
        model = nil
        modelInfo = ""
        output = ""
    }

    private func formatParamCount(_ n: UInt64) -> String {
        switch n {
        case 1_000_000_000...: return String(format: "%.1fB params", Double(n) / 1e9)
        case 1_000_000...:     return String(format: "%.1fM params", Double(n) / 1e6)
        default:               return "\(n) params"
        }
    }
}
