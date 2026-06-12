import Foundation

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
