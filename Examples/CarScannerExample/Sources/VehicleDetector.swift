import CoreML
import QuartzCore
import Vision
import WildEdge

/// One vehicle found in a preview frame.
struct VehicleDetection: Identifiable {
    let id = UUID()
    let label: String
    let confidence: Float
    /// Normalized within the frame the detector saw, origin top-left.
    let rect: CGRect

    /// Share of the frame the box covers, which the "move closer" gate will read.
    var frameFraction: CGFloat { rect.width * rect.height }
}

/// Rolling latency for the detector build that actually produced it.
///
/// The precision travels with the number so the overlay can never caption a
/// timing with the name of a model that did not produce it, which is possible
/// for a frame or two while a switch is in flight.
struct DetectorStat {
    let precision: DetectorPrecision
    let averageMs: Int

    /// Says "live" because this times the preview loop, not the scan: the
    /// detector runs again on the captured still, and that run is slower.
    var title: String { "live · \(precision.title) · \(averageMs) ms" }
}

/// What the live detector is doing, for the overlay label.
enum LiveDetectorStatus {
    /// No preview frame has arrived yet, so nothing has been asked of it.
    case idle
    /// The model is being read off disk and compiled. First use after launch or
    /// after a precision switch, and slow enough to be worth saying out loud.
    case loading
    case running(DetectorStat)

    /// nil hides the label entirely.
    var title: String? {
        switch self {
        case .idle:              return nil
        case .loading:           return "live · loading model…"
        case .running(let stat): return stat.title
        }
    }
}

/// A detector result together with the frame it describes.
///
/// The two travel as one value because drawing needs both, and a box paired
/// with the wrong frame size lands in the wrong place.
struct VehicleDetectionFrame {
    /// Pixel size of the frame as the detector saw it, already oriented.
    var sourceSize: CGSize = .zero
    var detections: [VehicleDetection] = []
}

extension CGImagePropertyOrientation {
    /// The image's size once this orientation is applied. A quarter-turn swaps
    /// the axes, and detection boxes are normalized against the upright frame.
    func orientedSize(of image: CGImage) -> CGSize {
        switch self {
        case .left, .leftMirrored, .right, .rightMirrored:
            return CGSize(width: image.height, height: image.width)
        default:
            return CGSize(width: image.width, height: image.height)
        }
    }
}

/// Which build of the detector to run.
///
/// Both are given every compute unit. int8 aborts in MPSGraph on an Apple
/// silicon Mac's GPU, but not on iPhone, so the restriction does not belong
/// here. What still separates them is accuracy: the model card measures int8
/// boxes drifting far enough to invert a "move closer" decision even where
/// presence detection agrees.
enum DetectorPrecision: String, CaseIterable, Identifiable {
    case fp16
    case int8

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fp16: return "fp16"
        case .int8: return "int8"
        }
    }

    var resourceName: String {
        switch self {
        case .fp16: return "VehicleDetectorModel"
        case .int8: return "VehicleDetectorModelInt8"
        }
    }

    var summary: String {
        switch self {
        case .fp16: return "39 MB. The build the model card recommends."
        case .int8: return "20 MB, half the size. Boxes can drift far enough to move or resize the crop, so prefer fp16 unless you are measuring the difference."
        }
    }
}

/// Road-vehicle classes, as indices into the model's 80-class contiguous COCO
/// output. Note these are not the 91-class ids: there, car is 3 rather than 2.
private let vehicleClasses: [Int: String] = [
    2: "car", 3: "motorcycle", 5: "bus", 7: "truck"
]

/// RT-DETR r18vd running on-device, one frame at a time.
///
/// The model is optional: if `VehicleDetectorModel.mlmodelc` is not in the
/// bundle the initializer returns nil and the camera keeps working without the
/// local loop.
final class VehicleDetector {
    /// Detections below this score are dropped. The model card puts the highest
    /// threshold that still rejected every non-vehicle frame at 0.5.
    var confidenceThreshold: Float = 0.5

    let precision: DetectorPrecision
    private let request: VNCoreMLRequest
    private let handle: ModelHandle
    /// RT-DETR emits a fixed set of object queries, one candidate each.
    private let queryCount = 300
    private let classCount = 80

    init?(precision: DetectorPrecision) {
        self.precision = precision
        guard let url = Bundle.main.url(forResource: precision.resourceName, withExtension: "mlmodelc") else {
            print("[VehicleDetector] \(precision.resourceName).mlmodelc not in bundle — local detection disabled")
            return nil
        }

        let info = ModelInfo(
            modelName: "rtdetr_r18vd",
            modelSource: "WildEdgeDev/we-scan-detector-coreml",
            modelFormat: "coreml",
            modelFamily: "rt-detr",
            quantization: precision.rawValue
        )
        handle = WildEdge.shared.registerModel(modelId: "rtdetr_r18vd_\(precision.rawValue)", info: info)

        let config = MLModelConfiguration()
        // Core ML assigns each operation itself; on this model it lands mostly
        // on the GPU with a large share on the Neural Engine.
        config.computeUnits = .all

        let loadStart = Date()
        do {
            let model = try VNCoreMLModel(for: MLModel(contentsOf: url, configuration: config))
            request = VNCoreMLRequest(model: model)
            // The model wants the whole frame squashed into its square input,
            // which also makes its normalized boxes valid for the full frame.
            request.imageCropAndScaleOption = .scaleFill
        } catch {
            print("[VehicleDetector] load failed: \(error)")
            handle.trackLoad(durationMs: Int(Date().timeIntervalSince(loadStart) * 1000),
                             accelerator: .npu, success: false, errorCode: "coreml_load_error")
            return nil
        }
        handle.trackLoad(durationMs: Int(Date().timeIntervalSince(loadStart) * 1000), accelerator: .npu)
    }

    deinit {
        handle.trackUnload()
    }

    /// Runs the detector over a live preview frame, for the aiming overlay.
    /// Call from a serial background queue.
    ///
    /// **Deliberately not reported to WildEdge.** This runs several times a
    /// second for as long as the camera is pointed at anything, which would
    /// bury the handful of events that describe an actual scan under two orders
    /// of magnitude of throwaway frames. The scan path — `detect(_:orientation:runId:)`
    /// and the brand classifier — is what carries the telemetry.
    ///
    /// `durationMs` covers only the Vision call: building the request handler
    /// and performing it, which is the rescale to the model's input plus the
    /// Core ML forward pass. Decoding the 300 queries afterwards is this
    /// class's own work, not the model's, so the overlay leaves it out.
    func detect(
        _ pixelBuffer: CVPixelBuffer,
        orientation: CGImagePropertyOrientation
    ) -> (detections: [VehicleDetection], durationMs: Int) {
        let start = CACurrentMediaTime()
        do {
            let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation, options: [:])
            try handler.perform([request])
        } catch {
            return ([], millis(since: start))
        }
        let duration = millis(since: start)
        return (decode(request.results ?? []), duration)
    }

    /// Runs the detector over a still image rather than a preview frame.
    ///
    /// Used once per scan, so the brand hint describes the photo actually being
    /// uploaded rather than whichever preview frame happened to be last.
    ///
    /// `orientation` must come from the file's EXIF: a CGImage decoded from a
    /// capture holds the sensor's own landscape buffer, and a car lying on its
    /// side is not one this model recognises.
    func detect(
        _ image: CGImage,
        orientation: CGImagePropertyOrientation,
        runId: String
    ) -> [VehicleDetection] {
        let start = CACurrentMediaTime()
        do {
            try VNImageRequestHandler(cgImage: image, orientation: orientation, options: [:]).perform([request])
        } catch {
            handle.trackInference(durationMs: millis(since: start),
                                  inputModality: .image, outputModality: .detection,
                                  success: false, errorCode: "coreml_invoke_error", runId: runId)
            return []
        }
        let duration = millis(since: start)

        let detections = decode(request.results ?? [])
        handle.trackInference(
            durationMs: duration,
            inputModality: .image,
            outputModality: .detection,
            outputMeta: detectionMeta(from: detections, imageSize: orientation.orientedSize(of: image)),
            runId: runId
        )
        return detections
    }

    /// Rounded rather than truncated: the span being timed is tens of
    /// milliseconds, so dropping the fraction would bias every reading down.
    private func millis(since start: CFTimeInterval) -> Int {
        Int(((CACurrentMediaTime() - start) * 1000).rounded())
    }

    // MARK: - Output decoding

    /// Turns the model's two multi-arrays into detections.
    ///
    /// `logits` is [1, queries, classes] and pre-sigmoid; `boxes` is
    /// [1, queries, 4] as normalized cx, cy, w, h. No NMS: the queries are
    /// already distinct, so every one above the threshold is its own detection.
    private func decode(_ results: [VNObservation]) -> [VehicleDetection] {
        let features = results.compactMap { $0 as? VNCoreMLFeatureValueObservation }
        func array(_ name: String) -> MLMultiArray? {
            features.first { $0.featureName == name }?.featureValue.multiArrayValue
        }
        guard let logits = array("logits"), let boxes = array("boxes"),
              logits.count >= queryCount * classCount, boxes.count >= queryCount * 4
        else { return [] }

        var out: [VehicleDetection] = []
        for query in 0..<queryCount {
            // Only the vehicle classes are scored; the other 76 never matter.
            var best: (label: String, score: Float)?
            for (classId, label) in vehicleClasses {
                let score = sigmoid(Float(truncating: logits[query * classCount + classId]))
                if score >= confidenceThreshold, score > (best?.score ?? 0) {
                    best = (label, score)
                }
            }
            guard let best else { continue }

            let cx = CGFloat(truncating: boxes[query * 4 + 0])
            let cy = CGFloat(truncating: boxes[query * 4 + 1])
            let w = CGFloat(truncating: boxes[query * 4 + 2])
            let h = CGFloat(truncating: boxes[query * 4 + 3])
            guard w > 0, h > 0 else { continue }

            out.append(VehicleDetection(
                label: best.label,
                confidence: best.score,
                rect: CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h)
            ))
        }
        return out.sorted { $0.confidence > $1.confidence }
    }

    private func sigmoid(_ x: Float) -> Float { 1 / (1 + exp(-x)) }

    /// `imageSize` is the frame the boxes were found in, so they can be
    /// reported as [x_min, y_min, x_max, y_max] pixels. Without it the boxes
    /// are left out rather than reported against a 1x1 image, which would round
    /// every one of them to zero.
    private func detectionMeta(from detections: [VehicleDetection], imageSize: CGSize?) -> [String: Any] {
        guard !detections.isEmpty else { return DetectionOutputMeta(numPredictions: 0).toMap() }
        let topK = detections.prefix(3).map { detection in
            TopPrediction(
                label: detection.label,
                confidence: Double(detection.confidence),
                bbox: imageSize.map { size in
                    [Int((detection.rect.minX * size.width).rounded()),
                     Int((detection.rect.minY * size.height).rounded()),
                     Int((detection.rect.maxX * size.width).rounded()),
                     Int((detection.rect.maxY * size.height).rounded())]
                }
            )
        }
        let avg = detections.reduce(0.0) { $0 + Double($1.confidence) } / Double(detections.count)
        return DetectionOutputMeta(numPredictions: detections.count, topK: Array(topK), avgConfidence: avg).toMap()
    }
}
