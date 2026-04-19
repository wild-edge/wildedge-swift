import Foundation
import WildEdge

#if canImport(UIKit) && canImport(MLKitFaceDetection) && canImport(MLKitVision)
import UIKit
import MLKitFaceDetection
import MLKitVision
#endif

#if canImport(UIKit) && canImport(MLKitFaceDetection) && canImport(MLKitVision)
final class MLKitExample {
    private let wildEdge: WildEdgeClient
    private let handle: ModelHandle
    private let detector: FaceDetector

    init() {
        let dsn = ProcessInfo.processInfo.environment["WILDEDGE_DSN"] ?? ""
        self.wildEdge = WildEdge.initialize { builder in
            builder.dsn = dsn
            builder.debug = true
        }

        self.handle = wildEdge.registerModel(
            modelId: "face-detector",
            info: ModelInfo(
                modelName: "Face Detector",
                modelVersion: "16.1",
                modelSource: "local",
                modelFormat: "mlkit"
            )
        )

        let options = FaceDetectorOptions()
        options.performanceMode = .accurate
        self.detector = FaceDetector.faceDetector(options: options)
    }

    // Runs face detection and records success/failure metrics.
    func detect(image: UIImage, completion: ((Result<[Face], Error>) -> Void)? = nil) {
        let start = Date()
        let visionImage = VisionImage(image: image)

        detector.process(visionImage) { [handle] faces, error in
            let durationMs = Int(Date().timeIntervalSince(start) * 1000)

            if let error {
                _ = handle.trackInference(
                    durationMs: durationMs,
                    inputModality: .image,
                    outputModality: .detection,
                    success: false,
                    errorCode: "mlkit_face_detection_error"
                )
                completion?(.failure(error))
                return
            }

            let detectedFaces = faces ?? []
            _ = handle.trackInference(
                durationMs: durationMs,
                inputModality: .image,
                outputModality: .detection,
                outputMeta: DetectionOutputMeta(numPredictions: detectedFaces.count).toMap()
            )
            completion?(.success(detectedFaces))
        }
    }

    func close() {
        detector.close()
        wildEdge.close()
    }
}
#else
final class MLKitExample {
    private let wildEdge: WildEdgeClient
    private let handle: ModelHandle

    init() {
        let dsn = ProcessInfo.processInfo.environment["WILDEDGE_DSN"] ?? ""
        self.wildEdge = WildEdge.initialize { builder in
            builder.dsn = dsn
            builder.debug = true
        }

        self.handle = wildEdge.registerModel(
            modelId: "face-detector",
            info: ModelInfo(
                modelName: "Face Detector",
                modelVersion: "16.1",
                modelSource: "local",
                modelFormat: "mlkit"
            )
        )
    }

    // Compile-time fallback for environments without Google ML Kit.
    func detect(imageData: Data, numFaces: Int) {
        _ = imageData
        _ = handle.trackInference(
            durationMs: 0,
            inputModality: .image,
            outputModality: .detection,
            outputMeta: DetectionOutputMeta(numPredictions: numFaces).toMap()
        )
    }

    func close() {
        wildEdge.close()
    }
}
#endif
