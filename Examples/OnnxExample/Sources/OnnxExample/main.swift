import Foundation
import OnnxRuntimeBindings
import WildEdge

guard let modelPath = ProcessInfo.processInfo.environment["WILDEDGE_ONNX_MODEL_PATH"],
      !modelPath.isEmpty else {
    print("[OnnxExample] Set WILDEDGE_ONNX_MODEL_PATH to a .onnx file and re-run")
    exit(0)
}

let dsn = ProcessInfo.processInfo.environment["WILDEDGE_DSN"] ?? ""
let wildEdge = WildEdge.initialize { builder in
    builder.dsn = dsn
    builder.debug = true
}

do {
    try autoreleasepool {
        let env = try ORTEnv(loggingLevel: .warning)
        let sessionOptions = try ORTSessionOptions()
        // Load timing, run interception, and unload on dealloc are all handled automatically.
        let session = try ORTSession(env: env, modelPath: modelPath, sessionOptions: sessionOptions)

        let tensorData = Data(repeating: 0, count: 4)
        let shape: [NSNumber] = [1]
        let a = try ORTValue(tensorData: NSMutableData(data: tensorData), elementType: .float, shape: shape)
        let b = try ORTValue(tensorData: NSMutableData(data: tensorData), elementType: .float, shape: shape)

        let outputs = try session.run(withInputs: ["A": a, "B": b], outputNames: ["C"], runOptions: nil)
        print("[OnnxExample] run ok — outputs: \(outputs.keys.sorted().joined(separator: ", "))")
    }
} catch {
    print("[OnnxExample] error: \(error)")
    exit(1)
}

wildEdge.close()
