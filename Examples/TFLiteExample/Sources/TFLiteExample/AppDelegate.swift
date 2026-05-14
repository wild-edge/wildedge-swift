import UIKit
import TensorFlowLite
import WildEdge

@main
class AppDelegate: UIResponder, UIApplicationDelegate {

    private static let modelURL = URL(string: "https://storage.googleapis.com/download.tensorflow.org/models/tflite/task_library/image_classification/ios/lite-model_efficientnet_lite0_uint8_2.tflite")!
    private static let modelFilename = "wildedge_sample_model.tflite"

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        // WildEdge auto-inits via +load using WILDEDGE_DSN from the environment or Info.plist.
        // TFLite has no ObjC runtime layer to hook, so model handles are registered manually.
        modelPath { path in
            guard let path else { return }
            DispatchQueue.main.async { self.runInference(modelPath: path) }
        }
        return true
    }

    // MARK: - Model resolution

    private func modelPath(completion: @escaping (String?) -> Void) {
        // 1. Bundled model takes priority.
        if let bundled = Bundle.main.path(forResource: "model", ofType: "tflite") {
            print("[TFLiteExample] Using bundled model")
            completion(bundled); return
        }

        // 2. Previously downloaded model in Caches.
        let cached = Self.cachedModelPath
        if FileManager.default.fileExists(atPath: cached) {
            print("[TFLiteExample] Using cached model at \(cached)")
            completion(cached); return
        }

        // 3. Download sample model.
        print("[TFLiteExample] Downloading sample model from \(Self.modelURL)")
        URLSession.shared.downloadTask(with: Self.modelURL) { tmpURL, response, error in
            if let error {
                print("[TFLiteExample] Download failed: \(error.localizedDescription)")
                completion(nil); return
            }
            guard let tmpURL,
                  let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                print("[TFLiteExample] Download HTTP error")
                completion(nil); return
            }
            do {
                try FileManager.default.moveItem(atPath: tmpURL.path, toPath: cached)
                print("[TFLiteExample] Model saved to \(cached)")
                completion(cached)
            } catch {
                print("[TFLiteExample] Save failed: \(error.localizedDescription)")
                completion(nil)
            }
        }.resume()
    }

    private static var cachedModelPath: String {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appendingPathComponent(modelFilename).path
    }

    // MARK: - Inference

    private func runInference(modelPath: String) {
        let info = ModelInfo(
            modelName: "EfficientNet-Lite0",
            modelSource: "remote",
            modelFormat: "tflite",
            quantization: "uint8"
        )
        let handle = WildEdge.shared.registerModel(modelId: "efficientnet_lite0_uint8", info: info)

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
