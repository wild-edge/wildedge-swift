import CoreML
import QuartzCore
import Vision
import WildEdge

/// What the on-device classifier thinks a cropped car is.
struct BrandGuess {
    struct Candidate {
        let brand: String
        /// Softmax probability over the classifier's closed set of brands.
        let probability: Double
    }

    let candidates: [Candidate]
    let durationMs: Int

    var top: Candidate? { candidates.first }

    /// A line for the vision model's prompt, or nil if there is nothing useful
    /// to say. Deliberately hedged: the classifier knows a closed set of
    /// European brands, has no "not a car" class, and its published accuracy
    /// comes from catalogue photos rather than street ones.
    var promptHint: String? {
        guard let top, top.probability >= BrandClassifier.hintThreshold else { return nil }
        let ranked = candidates.prefix(3)
            .map { "\($0.brand) \(Int(($0.probability * 100).rounded()))%" }
            .joined(separator: ", ")
        return """
        An on-device classifier examined a crop of this car and ranked it: \(ranked).
        It only knows \(BrandClassifier.brandCount) mostly-European brands, cannot say "not a car", and was measured on \
        catalogue photos rather than street photos. Treat it as a prior, not as evidence: \
        if what you see disagrees, or the real brand is outside its list, ignore it.
        """
    }
}

/// Why a scan has no on-device brand guess, so the UI can say which it was
/// instead of leaving every cause looking alike.
enum BrandGuessOutcome {
    case guessed(BrandGuess)
    /// Weights absent from the bundle — see the README, they are not committed.
    case modelUnavailable
    /// The detector found no vehicle in the captured photo.
    case noVehicle
    /// Switched off in settings, so the classifier never ran.
    case disabled
    case failed

    var guess: BrandGuess? {
        if case .guessed(let guess) = self { return guess }
        return nil
    }

    var explanation: String {
        switch self {
        case .guessed:         return ""
        case .modelUnavailable: return "Classifier not bundled"
        case .noVehicle:        return "No vehicle found in the photo"
        case .disabled:         return "Turned off in settings"
        case .failed:           return "Classifier failed"
        }
    }
}

/// EfficientNetV2-S fine-tuned to name a car's manufacturer, running on-device.
///
/// Optional in the same way the detector is: the weights are not redistributable
/// so they may be absent from a checkout, and the app runs without the hint.
final class BrandClassifier {
    static let modelName = "BrandClassifierModel"
    /// Below this the ranking is too flat to be worth putting in a prompt. A
    /// non-car crop lands around here, since there is no class to reject it.
    static let hintThreshold = 0.35
    static let brandCount = 43

    /// Padding added to each side of the detector's box before cropping. The
    /// model was trained on padded crops; a tight crop costs accuracy.
    private static let cropPadding: CGFloat = 0.12

    private let request: VNCoreMLRequest
    private let handle: ModelHandle

    init?() {
        guard let url = Bundle.main.url(forResource: Self.modelName, withExtension: "mlmodelc") else {
            print("[BrandClassifier] \(Self.modelName).mlmodelc not in bundle — brand hint disabled")
            return nil
        }

        let info = ModelInfo(
            modelName: "effv2s-v11-brand-s0",
            modelSource: "WildEdgeDev/we-scan-brand-classifier",
            modelFormat: "coreml",
            modelFamily: "efficientnetv2",
            quantization: "fp16"
        )
        handle = WildEdge.shared.registerModel(modelId: "effv2s_v11_brand_s0_fp16", info: info)

        let config = MLModelConfiguration()
        config.computeUnits = .all
        let loadStart = CACurrentMediaTime()
        do {
            let model = try VNCoreMLModel(for: MLModel(contentsOf: url, configuration: config))
            request = VNCoreMLRequest(model: model)
            // Squash the crop into the square input. A centre crop would cut off
            // the ends of the car, where much of the brand identity sits.
            request.imageCropAndScaleOption = .scaleFill
        } catch {
            print("[BrandClassifier] load failed: \(error)")
            handle.trackLoad(durationMs: Self.millis(since: loadStart), accelerator: .npu,
                             success: false, errorCode: "coreml_load_error")
            return nil
        }
        handle.trackLoad(durationMs: Self.millis(since: loadStart), accelerator: .npu)
    }

    deinit {
        handle.trackUnload()
    }

    /// Classifies the vehicle at `box` within `image`.
    ///
    /// `box` is normalized with a top-left origin, as the detector reports it,
    /// and `orientation` must match the one the box was found with.
    /// Call from a serial background queue.
    func classify(
        _ image: CGImage,
        orientation: CGImagePropertyOrientation,
        box: CGRect,
        runId: String
    ) -> BrandGuess? {
        request.regionOfInterest = Self.regionOfInterest(for: box)

        let start = CACurrentMediaTime()
        do {
            try VNImageRequestHandler(cgImage: image, orientation: orientation, options: [:]).perform([request])
        } catch {
            handle.trackInference(durationMs: Self.millis(since: start),
                                  inputModality: .image, outputModality: .classification,
                                  success: false, errorCode: "coreml_invoke_error", runId: runId)
            return nil
        }
        let duration = Self.millis(since: start)

        let observations = (request.results ?? []).compactMap { $0 as? VNClassificationObservation }
        guard !observations.isEmpty else { return nil }

        let candidates = Self.softmax(observations)
        handle.trackInference(
            durationMs: duration,
            inputModality: .image,
            outputModality: .classification,
            outputMeta: ClassificationOutputMeta(
                numPredictions: candidates.count,
                topK: candidates.prefix(3).map { TopPrediction(label: $0.brand, confidence: $0.probability) },
                avgConfidence: candidates.first?.probability
            ).toMap(),
            runId: runId
        )
        return BrandGuess(candidates: candidates, durationMs: duration)
    }

    // MARK: - Helpers

    /// Vision's region of interest is normalized with a bottom-left origin,
    /// and the model wants the box padded before it is cropped.
    private static func regionOfInterest(for box: CGRect) -> CGRect {
        let padded = box.insetBy(dx: -box.width * cropPadding, dy: -box.height * cropPadding)
        let clamped = padded.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !clamped.isNull, clamped.width > 0, clamped.height > 0 else {
            return CGRect(x: 0, y: 0, width: 1, height: 1)
        }
        return CGRect(x: clamped.minX, y: 1 - clamped.maxY, width: clamped.width, height: clamped.height)
    }

    /// The Core ML model is a classifier, but it was exported without a softmax:
    /// what Vision reports as a confidence is a raw logit, and they neither sit
    /// in 0...1 nor sum to one. Normalizing here is what makes the number in the
    /// prompt mean what it says.
    private static func softmax(_ observations: [VNClassificationObservation]) -> [BrandGuess.Candidate] {
        let logits = observations.map { Double($0.confidence) }
        guard let maxLogit = logits.max() else { return [] }
        let exponentials = logits.map { exp($0 - maxLogit) }
        let total = exponentials.reduce(0, +)
        guard total > 0 else { return [] }

        return zip(observations, exponentials)
            .map { BrandGuess.Candidate(brand: $0.identifier, probability: $1 / total) }
            .sorted { $0.probability > $1.probability }
    }

    private static func millis(since start: CFTimeInterval) -> Int {
        Int(((CACurrentMediaTime() - start) * 1000).rounded())
    }
}
