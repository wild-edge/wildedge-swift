import UIKit
import TensorFlowLite
import WildEdge

@main
class AppDelegate: UIResponder, UIApplicationDelegate {

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        // WildEdge auto-inits via +load using WILDEDGE_DSN from the environment or Info.plist.
        // TFLite has no ObjC runtime layer to hook, so model handles are registered manually.
        runInference()
        return true
    }

    private func runInference() {
        guard let modelPath = Bundle.main.path(forResource: "model", ofType: "tflite") else {
            print("[TFLiteExample] model.tflite not found in bundle")
            return
        }

        let info = ModelInfo(
            modelName: "MobileNet V3",
            modelVersion: "3.0",
            modelSource: "local",
            modelFormat: "tflite",
            quantization: "int8"
        )

        let handle = WildEdge.shared.registerModel(modelId: "mobilenet_v3_int8_cpu", info: info)

        do {
            var options = Interpreter.Options()
            options.threadCount = 4

            let loadStart = Date()
            let interpreter = try Interpreter(modelPath: modelPath, options: options)
            try interpreter.allocateTensors()
            handle.trackLoad(
                durationMs: Int(Date().timeIntervalSince(loadStart) * 1000),
                accelerator: .cpu
            )

            let inputTensor = try interpreter.input(at: 0)
            let inputSize = inputTensor.shape.dimensions.reduce(1, *)
            let dummyInput = Data(repeating: 0, count: inputSize)

            let inferStart = Date()
            try interpreter.copy(dummyInput, toInputAt: 0)
            try interpreter.invoke()
            let outputTensor = try interpreter.output(at: 0)

            _ = handle.trackInference(
                durationMs: Int(Date().timeIntervalSince(inferStart) * 1000),
                inputModality: .image,
                outputModality: .classification,
                outputMeta: DetectionOutputMeta(numPredictions: outputTensor.shape.dimensions.last ?? 0).toMap()
            )

            print("[TFLiteExample] inference ok — output shape: \(outputTensor.shape.dimensions)")
            print("[TFLiteExample] pending WildEdge events: \(WildEdge.shared.pendingCount)")
        } catch {
            handle.trackInference(
                durationMs: 0,
                inputModality: .image,
                outputModality: .classification,
                success: false,
                errorCode: "tflite_invoke_error"
            )
            print("[TFLiteExample] error: \(error)")
        }
    }
}
