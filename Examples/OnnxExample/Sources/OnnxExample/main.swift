import Foundation
import OnnxRuntimeBindings
import WildEdge

// WildEdge auto-inits via +load before main() using WILDEDGE_DSN from the environment.
// Set WILDEDGE_DEBUG=true to see the auto-init and event log.

let modelPath = ProcessInfo.processInfo.environment["WILDEDGE_ONNX_MODEL_PATH"]
    ?? Bundle.module.path(forResource: "add_mul_add", ofType: "onnx")

guard let modelPath else {
    print("[OnnxExample] Model not found")
    exit(1)
}

do {
    try autoreleasepool {
        let env = try ORTEnv(loggingLevel: .warning)
        let sessionOptions = try ORTSessionOptions()
        // Load timing, run interception, and unload on dealloc are all handled automatically.
        let session = try ORTSession(env: env, modelPath: modelPath, sessionOptions: sessionOptions)

        // add_mul_add: C = (A + B) * A + B, inputs A=2 B=3 → C = (2+3)*2+3 = 13
        var inputValue: Float = 2.0
        var inputValueB: Float = 3.0
        let tensorData = Data(bytes: &inputValue, count: MemoryLayout<Float>.size)
        let tensorDataB = Data(bytes: &inputValueB, count: MemoryLayout<Float>.size)
        let shape: [NSNumber] = [1]
        let a = try ORTValue(tensorData: NSMutableData(data: tensorData), elementType: .float, shape: shape)
        let b = try ORTValue(tensorData: NSMutableData(data: tensorDataB), elementType: .float, shape: shape)

        let outputs = try session.run(withInputs: ["A": a, "B": b], outputNames: ["C"], runOptions: nil)
        print("[OnnxExample] run ok — outputs: \(outputs.keys.sorted().joined(separator: ", "))")
        print("[OnnxExample] pending WildEdge events: \(WildEdge.shared.pendingCount)")
    }
} catch {
    print("[OnnxExample] error: \(error)")
    exit(1)
}

WildEdge.shared.flush()
WildEdge.shared.close()
