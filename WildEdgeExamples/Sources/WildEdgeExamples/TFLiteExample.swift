import Foundation
import WildEdge

#if canImport(TensorFlowLite)
import TensorFlowLite
#endif

#if canImport(TensorFlowLite)
final class TFLiteExample {
    private let wildEdge: WildEdgeClient
    private let trackedCpu: ModelHandle
    private let trackedGpu: ModelHandle
    private let cpuInterpreter: Interpreter
    private let gpuInterpreter: Interpreter?

    init(modelPath: String) throws {
        let dsn = ProcessInfo.processInfo.environment["WILDEDGE_DSN"] ?? ""
        self.wildEdge = WildEdge.initialize { builder in
            builder.dsn = dsn
            builder.debug = true
        }

        var cpuOptions = Interpreter.Options()
        cpuOptions.threadCount = 4
        self.cpuInterpreter = try Interpreter(modelPath: modelPath, options: cpuOptions)
        try self.cpuInterpreter.allocateTensors()

        var gpuOptions = Interpreter.Options()
        gpuOptions.threadCount = 1
        self.gpuInterpreter = try? Interpreter(modelPath: modelPath, options: gpuOptions)
        try? self.gpuInterpreter?.allocateTensors()

        let info = ModelInfo(
            modelName: "MobileNet V3",
            modelVersion: "3.0",
            modelSource: "local",
            modelFormat: "tflite",
            quantization: "int8"
        )

        self.trackedCpu = wildEdge.registerModel(modelId: "mobilenet_v3_int8_cpu", info: info)
        self.trackedGpu = wildEdge.registerModel(modelId: "mobilenet_v3_int8_gpu", info: info)

        trackedCpu.trackLoad(durationMs: 60, accelerator: .cpu)
        if gpuInterpreter != nil {
            trackedGpu.trackLoad(durationMs: 72, accelerator: .gpu)
        }
    }

    // Runs TensorFlow Lite inference and records success/failure metrics.
    @discardableResult
    func classify(inputData: Data, useGPU: Bool, inputMeta: [String: Any] = [:]) throws -> Data {
        let interpreter = (useGPU ? gpuInterpreter : nil) ?? cpuInterpreter
        let handle = (useGPU && gpuInterpreter != nil) ? trackedGpu : trackedCpu
        let start = Date()

        do {
            try interpreter.copy(inputData, toInputAt: 0)
            try interpreter.invoke()
            let outputTensor = try interpreter.output(at: 0)

            _ = handle.trackInference(
                durationMs: Int(Date().timeIntervalSince(start) * 1000),
                inputModality: .image,
                outputModality: .classification,
                inputMeta: inputMeta,
                outputMeta: DetectionOutputMeta(numPredictions: 1).toMap()
            )

            return outputTensor.data
        } catch {
            _ = handle.trackInference(
                durationMs: Int(Date().timeIntervalSince(start) * 1000),
                inputModality: .image,
                outputModality: .classification,
                success: false,
                errorCode: "tflite_invoke_error",
                inputMeta: inputMeta
            )
            throw error
        }
    }

    func close() {
        trackedCpu.close()
        trackedGpu.close()
        wildEdge.close()
    }
}
#else
final class TFLiteExample {
    private let wildEdge: WildEdgeClient
    private let trackedCpu: ModelHandle
    private let trackedGpu: ModelHandle

    init(modelPath: String) throws {
        _ = modelPath
        let dsn = ProcessInfo.processInfo.environment["WILDEDGE_DSN"] ?? ""
        self.wildEdge = WildEdge.initialize { builder in
            builder.dsn = dsn
            builder.debug = true
        }

        let info = ModelInfo(
            modelName: "MobileNet V3",
            modelVersion: "3.0",
            modelSource: "local",
            modelFormat: "tflite",
            quantization: "int8"
        )

        self.trackedCpu = wildEdge.registerModel(modelId: "mobilenet_v3_int8_cpu", info: info)
        self.trackedGpu = wildEdge.registerModel(modelId: "mobilenet_v3_int8_gpu", info: info)

        trackedCpu.trackLoad(durationMs: 60, accelerator: .cpu)
        trackedGpu.trackLoad(durationMs: 72, accelerator: .gpu)
    }

    // Compile-time fallback for environments without TensorFlow Lite.
    @discardableResult
    func classify(inputData: Data, useGPU: Bool, inputMeta: [String: Any] = [:]) throws -> Data {
        _ = inputData
        let handle = useGPU ? trackedGpu : trackedCpu
        _ = handle.trackInference(
            durationMs: 0,
            inputModality: .image,
            outputModality: .classification,
            inputMeta: inputMeta,
            outputMeta: DetectionOutputMeta(numPredictions: 1).toMap()
        )
        return Data()
    }

    func close() {
        trackedCpu.close()
        trackedGpu.close()
        wildEdge.close()
    }
}
#endif
