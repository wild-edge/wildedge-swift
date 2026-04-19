import Foundation
import WildEdge

#if canImport(onnxruntime_objc)
import onnxruntime_objc
#elseif canImport(ONNXRuntime)
import ONNXRuntime
#endif

#if canImport(onnxruntime_objc) || canImport(ONNXRuntime)
final class OnnxExample {
    private let wildEdge: WildEdgeClient
    private let handle: ModelHandle
    private let env: ORTEnv
    private let session: ORTSession

    init(modelPath: String) throws {
        let dsn = ProcessInfo.processInfo.environment["WILDEDGE_DSN"] ?? ""
        self.wildEdge = WildEdge.initialize { builder in
            builder.dsn = dsn
            builder.debug = true
        }

        self.env = try ORTEnv(loggingLevel: .warning)
        let sessionOptions = try ORTSessionOptions()
        self.session = try ORTSession(env: env, modelPath: modelPath, sessionOptions: sessionOptions)

        self.handle = wildEdge.registerModel(
            modelId: "face_detector_int8",
            info: ModelInfo(
                modelName: "Face Detector",
                modelVersion: "1.0",
                modelSource: "local",
                modelFormat: "onnx",
                quantization: "int8"
            )
        )

        handle.trackLoad(durationMs: 85, accelerator: .npu)
    }

    // Runs ONNX inference and records success/failure metrics.
    @discardableResult
    func run(inputs: [String: ORTValue], outputNames: Set<String>, inputMeta: [String: Any]) throws -> [String: ORTValue] {
        let start = Date()

        do {
            let outputs = try session.run(withInputs: inputs, outputNames: outputNames, runOptions: nil)
            let durationMs = Int(Date().timeIntervalSince(start) * 1000)

            _ = handle.trackInference(
                durationMs: durationMs,
                inputModality: .image,
                outputModality: .detection,
                inputMeta: inputMeta,
                outputMeta: DetectionOutputMeta(numPredictions: outputs.count).toMap()
            )

            return outputs
        } catch {
            let durationMs = Int(Date().timeIntervalSince(start) * 1000)
            _ = handle.trackInference(
                durationMs: durationMs,
                inputModality: .image,
                outputModality: .detection,
                success: false,
                errorCode: "onnxruntime_run_error",
                inputMeta: inputMeta
            )
            throw error
        }
    }

    func close() {
        handle.close()
        wildEdge.close()
    }
}
#else
final class OnnxExample {
    private let wildEdge: WildEdgeClient
    private let handle: ModelHandle

    init() {
        let dsn = ProcessInfo.processInfo.environment["WILDEDGE_DSN"] ?? ""
        self.wildEdge = WildEdge.initialize { builder in
            builder.dsn = dsn
            builder.debug = true
        }

        self.handle = wildEdge.registerModel(
            modelId: "face_detector_int8",
            info: ModelInfo(
                modelName: "Face Detector",
                modelVersion: "1.0",
                modelSource: "local",
                modelFormat: "onnx",
                quantization: "int8"
            )
        )

        handle.trackLoad(durationMs: 85, accelerator: .npu)
    }

    // Compile-time fallback for environments without ONNX Runtime.
    func run(inputMeta: [String: Any]) {
        _ = handle.trackInference(
            durationMs: 0,
            inputModality: .image,
            outputModality: .detection,
            inputMeta: inputMeta,
            outputMeta: DetectionOutputMeta(numPredictions: 1, avgConfidence: 0.95).toMap()
        )
    }

    func close() {
        handle.close()
        wildEdge.close()
    }
}
#endif
