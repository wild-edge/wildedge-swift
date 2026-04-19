import Foundation
import WildEdge

#if canImport(onnxruntime_objc)
import onnxruntime_objc
#elseif canImport(ONNXRuntime)
import ONNXRuntime
#endif

print("WildEdge iOS Examples")
print("Set WILDEDGE_DSN to enable real ingestion")
print("Optional: set WILDEDGE_TFLITE_MODEL_PATH and WILDEDGE_ONNX_MODEL_PATH")

let semaphore = DispatchSemaphore(value: 0)
let env = ProcessInfo.processInfo.environment

func runTFLiteIfConfigured(env: [String: String]) {
    guard let modelPath = env["WILDEDGE_TFLITE_MODEL_PATH"], !modelPath.isEmpty else {
        print("[examples] Skip TFLiteExample (WILDEDGE_TFLITE_MODEL_PATH not set)")
        return
    }

    do {
        let tflite = try TFLiteExample(modelPath: modelPath)
        let dummyInput = Data(repeating: 0, count: 224 * 224 * 3)
        _ = try tflite.classify(
            inputData: dummyInput,
            useGPU: false,
            inputMeta: WildEdge.analyzeText("demo-image").toMap()
        )
        tflite.close()
        print("[examples] TFLiteExample executed")
    } catch {
        print("[examples] TFLiteExample error: \(error)")
    }
}

func runOnnxIfConfigured(env: [String: String]) {
    guard let modelPath = env["WILDEDGE_ONNX_MODEL_PATH"], !modelPath.isEmpty else {
        print("[examples] Skip OnnxExample (WILDEDGE_ONNX_MODEL_PATH not set)")
        return
    }

    #if canImport(onnxruntime_objc) || canImport(ONNXRuntime)
    do {
        let onnx = try OnnxExample(modelPath: modelPath)
        let tensorData = Data(repeating: 0, count: 16)
        let shape: [NSNumber] = [1, 4]
        let value = try ORTValue(tensorData: NSMutableData(data: tensorData), elementType: .float, shape: shape)

        _ = try onnx.run(
            inputs: ["input": value],
            outputNames: ["output"],
            inputMeta: WildEdge.analyzeText("demo-image").toMap()
        )

        onnx.close()
        print("[examples] OnnxExample executed")
    } catch {
        print("[examples] OnnxExample error: \(error)")
    }
    #else
    let onnx = OnnxExample()
    onnx.run(inputMeta: WildEdge.analyzeText("demo-image").toMap())
    onnx.close()
    print("[examples] OnnxExample fallback executed (ONNX Runtime not linked)")
    #endif
}

Task {
    let tracing = TracingExample()
    tracing.runPipeline(input: Data("hello".utf8))
    tracing.close()

    let coroutines = CoroutinesExample()
    _ = try? await coroutines.classify(input: Data([0x00, 0x01]))
    coroutines.close()

    runTFLiteIfConfigured(env: env)
    runOnnxIfConfigured(env: env)

    print("Examples finished")
    semaphore.signal()
}

semaphore.wait()
