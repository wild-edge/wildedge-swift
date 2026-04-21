import Foundation
import WildEdge

print("WildEdge iOS Examples")
print("Set WILDEDGE_DSN to enable real ingestion")
print("Optional: set WILDEDGE_TFLITE_MODEL_PATH")

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

Task {
    let tracing = TracingExample()
    tracing.runPipeline(input: Data("hello".utf8))
    tracing.close()

    let coroutines = CoroutinesExample()
    _ = try? await coroutines.classify(input: Data([0x00, 0x01]))
    coroutines.close()

    runTFLiteIfConfigured(env: env)

    print("Examples finished")
    semaphore.signal()
}

semaphore.wait()
