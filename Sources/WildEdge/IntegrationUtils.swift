import Foundation

private let classificationTopK = 5
private let confidenceScale = 10_000.0

/// Builds top-K classification metadata from a raw model output.
///
/// `output` is expected to be an array whose first element is either `[Float]` (raw logits,
/// normalized via `softmax`) or `[UInt8]` (already-quantized scores, normalized by 255).
/// Returns `nil` if `numClasses <= 0`, the output shape is unrecognized, the array is empty,
/// or the probability vector size doesn't match `numClasses`.
internal func classificationOutputMeta(
    output: Any,
    numClasses: Int,
    labels: [String]? = nil
) -> ClassificationOutputMeta? {
    guard numClasses > 0 else { return nil }
    guard let array = output as? [Any], let first = array.first else { return nil }

    let probs: [Float]
    if let logits = first as? [Float] {
        probs = softmax(logits)
    } else if let bytes = first as? [UInt8] {
        probs = bytes.map { Float($0) / 255.0 }
    } else {
        return nil
    }
    guard probs.count == numClasses else { return nil }

    let topIndices = probs.indices
        .sorted { probs[$0] > probs[$1] }
        .prefix(min(classificationTopK, numClasses))

    let topK: [TopPrediction] = topIndices.map { index in
        let label = labels?.indices.contains(index) == true ? labels![index] : String(index)
        let confidence = (Double(probs[index]) * confidenceScale).rounded() / confidenceScale
        return TopPrediction(label: label, confidence: confidence)
    }

    return ClassificationOutputMeta(
        numPredictions: numClasses,
        topK: topK,
        avgConfidence: topK.first?.confidence
    )
}

private func softmax(_ logits: [Float]) -> [Float] {
    let maxLogit = logits.max() ?? 0
    let exps = logits.map { Foundation.exp($0 - maxLogit) }
    let sum = exps.reduce(0, +)
    return exps.map { $0 / sum }
}

/// Maps an error to a stable error code string for `trackInference`/`trackError`.
internal func errorCode(for error: Error) -> String {
    String(describing: type(of: error))
}

/// Times `block`, then reports the result via `handle.trackInference`.
/// On success, `outputMetaProvider` (if provided) is used to build `outputMeta` from the result.
/// On failure, the inference is reported with `success: false` and an error code derived from
/// the thrown error, then the error is rethrown.
public func trackInferenceExecution<T>(
    handle: ModelHandle,
    inputModality: InputModality? = nil,
    outputModality: OutputModality? = nil,
    inputMeta: [String: Any]? = nil,
    outputMetaProvider: ((T) -> [String: Any]?)? = nil,
    block: () throws -> T
) rethrows -> T {
    let start = Date()
    do {
        let result = try block()
        _ = handle.trackInference(
            durationMs: Int(Date().timeIntervalSince(start) * 1000),
            inputModality: inputModality,
            outputModality: outputModality,
            inputMeta: inputMeta,
            outputMeta: outputMetaProvider?(result)
        )
        return result
    } catch {
        _ = handle.trackInference(
            durationMs: Int(Date().timeIntervalSince(start) * 1000),
            inputModality: inputModality,
            outputModality: outputModality,
            success: false,
            errorCode: errorCode(for: error),
            inputMeta: inputMeta
        )
        throw error
    }
}
