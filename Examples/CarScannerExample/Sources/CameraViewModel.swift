import AVFoundation
import ImageIO
import QuartzCore
import WildEdge
import Combine
import UIKit

private extension Int {
    var nonZero: Int? { self == 0 ? nil : self }
}

struct BoundingBox: Decodable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double
}

struct CarCandidate: Decodable {
    var brand: String?
    var model: String?
    var color: String?
    var year: String?
    var confidence: Int?
    var bbox: BoundingBox?
}

struct CarInfo: Decodable {
    var found: Bool
    var candidates: [CarCandidate]?
}

struct PhotoMetadata {
    let fileSize: Int
    let dimensions: CGSize?

    var fileSizeFormatted: String {
        ByteCountFormatter.string(fromByteCount: Int64(fileSize), countStyle: .file)
    }
    var dimensionsFormatted: String? {
        guard let d = dimensions else { return nil }
        return "\(Int(d.width)) × \(Int(d.height))"
    }
}

struct HTTPStats {
    let statusCode: Int
    let durationMs: Int
    let responseSize: Int

    var responseSizeFormatted: String {
        ByteCountFormatter.string(fromByteCount: Int64(responseSize), countStyle: .file)
    }
}

struct ScanResult: Identifiable {
    let id = UUID()
    let provider: String
    let info: CarInfo
    let photo: PhotoMetadata
    let rawJSON: String
    let httpStats: HTTPStats
    let inferenceId: String
    let inferenceDate: Date
    let sendFeedback: (FeedbackType) -> Void
}

enum ScanJobStatus {
    case scanning
    case completed([ScanResult])
    case failed(String)
}

struct ScanJob: Identifiable {
    let id: UUID
    let date: Date
    let provider: RecognitionProvider
    var thumbnail: UIImage?
    var photoMetadata: PhotoMetadata?
    /// What the on-device classifier made of the car, before any provider saw
    /// it — or why there is nothing to show.
    var brandGuess: BrandGuessOutcome?
    /// Exactly the prompt the providers were given, hint included.
    var prompt: String?
    var status: ScanJobStatus = .scanning
}

/// What the on-device models made of a captured still.
struct StillAnalysis {
    /// The largest vehicle found, used to crop the upload.
    let vehicle: VehicleDetection?
    let brand: BrandGuessOutcome
}

enum RecognitionProvider: String, CaseIterable {
    case openRouter = "OpenRouter"
    case gemini = "Gemini"
    case both = "Both"

    var icon: String {
        switch self {
        case .openRouter: return "network"
        case .gemini:     return "sparkles"
        case .both:       return "arrow.triangle.2.circlepath"
        }
    }
}

final class CameraViewModel: NSObject, ObservableObject {
    /// Seconds between detector runs, and the default. Expressed as a gap
    /// rather than a rate so that turning the setting up asks for less work.
    /// Margin added around the vehicle box before the upload is cut from it.
    /// Wider than the classifier's 12%: the provider is also judging model and
    /// year, and the bodywork ends give that away.
    private static let scanCropPadding: CGFloat = 0.15
    static let detectorIntervalRange: ClosedRange<Double> = 0.1...1.0
    /// Absent means on: this defaults to true rather than to Bool's false.
    private static var storedBrandHintEnabled: Bool {
        UserDefaults.standard.object(forKey: "brandHintEnabled") as? Bool ?? true
    }
    private static var storedDetectorInterval: Double {
        let stored = UserDefaults.standard.double(forKey: "detectorIntervalSeconds")
        return detectorIntervalRange.contains(stored) ? stored : 0.25
    }

    @Published var jobs: [ScanJob] = []
    @Published var errorMessage: String?
    @Published var provider: RecognitionProvider = .openRouter
    @Published var uploadImageSize: Int = UserDefaults.standard.integer(forKey: "uploadImageSize").nonZero ?? 512 {
        didSet { UserDefaults.standard.set(uploadImageSize, forKey: "uploadImageSize") }
    }
    @Published var compressionQuality: Double = UserDefaults.standard.object(forKey: "compressionQuality") as? Double ?? 0.7 {
        didSet { UserDefaults.standard.set(compressionQuality, forKey: "compressionQuality") }
    }
    @Published var lastCapturedImage: UIImage?
    /// The most recent detector frame, for the live overlay.
    @Published var detectionFrame = VehicleDetectionFrame()
    /// Drives the live overlay label: loading, then timings.
    @Published var detectorStatus: LiveDetectorStatus = .idle
    /// Whether the on-device classifier runs at all, and so whether its brand
    /// hint is added to the prompt. On by default.
    @Published var brandHintEnabled: Bool = CameraViewModel.storedBrandHintEnabled {
        didSet {
            guard brandHintEnabled != oldValue else { return }
            UserDefaults.standard.set(brandHintEnabled, forKey: "brandHintEnabled")
            let enabled = brandHintEnabled
            detectorQueue.async { self.activeBrandHintEnabled = enabled }
        }
    }
    /// Minimum gap between detector runs, in seconds. Larger means the overlay
    /// updates less often; the diagram's 3-5 fps while aiming is 0.2-0.35 s.
    @Published var detectorInterval: Double = CameraViewModel.storedDetectorInterval {
        didSet {
            guard detectorInterval != oldValue else { return }
            UserDefaults.standard.set(detectorInterval, forKey: "detectorIntervalSeconds")
            let interval = detectorInterval
            detectorQueue.async { self.activeDetectorInterval = interval }
        }
    }
    @Published var detectorPrecision: DetectorPrecision =
        UserDefaults.standard.string(forKey: "detectorPrecision")
            .flatMap(DetectorPrecision.init(rawValue:)) ?? .fp16 {
        didSet {
            guard detectorPrecision != oldValue else { return }
            UserDefaults.standard.set(detectorPrecision.rawValue, forKey: "detectorPrecision")
            reloadDetector(with: detectorPrecision)
        }
    }

    let session = AVCaptureSession()
    private let photoOutput = AVCapturePhotoOutput()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let sessionQueue = DispatchQueue(label: "dev.wildedge.carscanner.session")
    private let detectorQueue = DispatchQueue(label: "dev.wildedge.carscanner.detector")
    /// Owned by `detectorQueue` once frames start; see `reloadDetector`.
    private var detector: VehicleDetector?
    /// Also `detectorQueue`-owned. Absent unless the weights are in the bundle.
    private lazy var brandClassifier = BrandClassifier()
    private var activePrecision: DetectorPrecision =
        UserDefaults.standard.string(forKey: "detectorPrecision")
            .flatMap(DetectorPrecision.init(rawValue:)) ?? .fp16
    /// Read only on `detectorQueue`; `detectorInterval` pushes changes across.
    private var activeDetectorInterval = CameraViewModel.storedDetectorInterval
    /// Read only on `detectorQueue`; `brandHintEnabled` pushes changes across.
    private var activeBrandHintEnabled = CameraViewModel.storedBrandHintEnabled
    private var lastDetectionAt: CFTimeInterval = 0
    private var detectionInFlight = false
    private var loggedFrameGeometry = false
    /// Durations behind `detectorAverageMs`, newest last.
    private var recentDetectorMs: [Int] = []
    private let detectorAverageWindow = 5
    private var captureDevice: AVCaptureDevice?
    private var pendingCaptures: [Int64: (jobID: UUID, provider: RecognitionProvider)] = [:]

    private let carPrompt = """
    Analyze this image. If a car is visible, return the top 3 most likely candidates as ONLY valid JSON — no other text:
    {"found": true, "candidates": [
      {"brand": "Toyota", "model": "Camry", "color": "Silver", "year": "2019", "confidence": 92, "bbox": {"x": 0.1, "y": 0.15, "width": 0.8, "height": 0.65}},
      {"brand": "Honda", "model": "Accord", "color": "Gray", "year": "2018", "confidence": 75, "bbox": {"x": 0.1, "y": 0.15, "width": 0.8, "height": 0.65}},
      {"brand": "Nissan", "model": "Altima", "color": "Silver", "year": "2017", "confidence": 55, "bbox": {"x": 0.1, "y": 0.15, "width": 0.8, "height": 0.65}}
    ]}
    confidence is an integer 0–100. Order by confidence descending.
    bbox contains normalized coordinates (0.0–1.0): x and y are the top-left corner, width and height are the span of the bounding box around the car.
    If no car is found, return exactly: {"found": false, "candidates": []}
    """

    var minZoom: CGFloat {
        captureDevice?.minAvailableVideoZoomFactor ?? 1.0
    }

    var maxZoom: CGFloat {
        min(captureDevice?.activeFormat.videoMaxZoomFactor ?? 5.0, 10.0)
    }

    func zoom(to factor: CGFloat) {
        guard let device = captureDevice else { return }
        let clamped = max(minZoom, min(factor, maxZoom))
        try? device.lockForConfiguration()
        device.videoZoomFactor = clamped
        device.unlockForConfiguration()
    }

    func setupCamera() {
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            guard granted else {
                DispatchQueue.main.async { self?.errorMessage = "Camera access denied" }
                return
            }
            self?.sessionQueue.async { self?.configureSession() }
        }
    }

    func scan() {
        let jobID = UUID()
        let captureProvider = provider
        jobs.insert(ScanJob(id: jobID, date: Date(), provider: captureProvider), at: 0)

        let settings: AVCapturePhotoSettings = photoOutput.availablePhotoCodecTypes.contains(.jpeg)
            ? AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
            : AVCapturePhotoSettings()
        pendingCaptures[settings.uniqueID] = (jobID: jobID, provider: captureProvider)

        sessionQueue.async {
            self.photoOutput.capturePhoto(with: settings, delegate: self)
        }
    }

    func analyzeSelectedPhoto(_ imageData: Data) {
        let jobID = UUID()
        let captureProvider = provider
        jobs.insert(ScanJob(id: jobID, date: Date(), provider: captureProvider), at: 0)
        Task.detached(priority: .userInitiated) { [weak self] in
            await self?.processCapture(imageData: imageData, jobID: jobID, provider: captureProvider)
        }
    }

    /// Everything between having a photo and having an answer, shared by the
    /// shutter and the photo picker.
    ///
    /// One scan is one WildEdge run and one trace: a root `scan` span with a
    /// child span per step, so the detector, the classifier and the provider
    /// calls (with their errors and later feedback) reassemble into one view.
    private func processCapture(imageData: Data, jobID: UUID, provider captureProvider: RecognitionProvider) async {
        await WildEdge.shared.trace("scan", kind: .agentStep, runId: "scan-\(jobID.uuidString)") { scan in
            await runScan(imageData: imageData, jobID: jobID, provider: captureProvider, in: scan)
        }
    }

    private func runScan(imageData: Data, jobID: UUID, provider captureProvider: RecognitionProvider,
                         in scan: SpanContext) async {
        let fullImage = UIImage(data: imageData)
        let analysis = analyzeStill(for: imageData, in: scan)

        // Upload the crop when there is one. The provider then spends its
        // attention on the car rather than the street, and because the
        // thumbnail is cut from the same crop, the boxes it returns still line
        // up with what is shown.
        let cropped = analysis.vehicle.flatMap { vehicle in
            fullImage.flatMap { croppedToVehicle($0, box: vehicle.rect) }
        }
        let scanImage = cropped ?? fullImage

        let (uploadData, meta) = scanImage.map(makeUploadDataAndMeta) ?? makeUploadDataAndMeta(imageData)
        let thumbnail = scanImage?.preparingThumbnail(of: CGSize(width: 400, height: 400))
        let scanPrompt = prompt(with: analysis.brand)

        await MainActor.run {
            self.lastCapturedImage = scanImage
            self.updateThumbnail(id: jobID, image: thumbnail)
            self.updatePhotoMetadata(id: jobID, meta: meta)
            self.updateBrandGuess(id: jobID, guess: analysis.brand, prompt: scanPrompt)
        }

        do {
            let results = try await scan.span("recognize") { _ in
                try await analyzeImage(uploadData, meta: meta, provider: captureProvider,
                                       prompt: scanPrompt, scan: scan)
            }
            await MainActor.run { self.updateJob(id: jobID, status: .completed(results)) }
        } catch {
            scan.status = .error
            await MainActor.run { self.updateJob(id: jobID, status: .failed(error.localizedDescription)) }
        }
    }

    func removeJob(id: UUID) {
        jobs.removeAll { $0.id == id }
    }

    /// Swaps the detector build. The detector is only ever touched on
    /// `detectorQueue`, so the swap has to happen there too.
    private func reloadDetector(with precision: DetectorPrecision) {
        detectorStatus = .loading
        detectionFrame = VehicleDetectionFrame()
        detectorQueue.async {
            // Cleared here rather than on the caller's thread: the window is
            // detectorQueue-owned and a preview frame may be appending to it.
            self.recentDetectorMs.removeAll()
            self.activePrecision = precision
            self.detector = nil          // release the old model before loading the new one
            self.detector = VehicleDetector(precision: precision)
        }
    }

    /// Finds the car in a still and asks the classifier what brand it is.
    ///
    /// Takes the full-resolution capture rather than the resized upload: the
    /// classifier sees a crop of the car, and at the smaller upload sizes that
    /// crop would be upscaled into its 224px input.
    ///
    /// Runs on `detectorQueue`, which owns both models, so this hops there and
    /// waits — it costs at most one preview frame. Every failure along the way
    /// is a nil, and a nil simply means the prompt goes out without a hint.
    ///
    /// The queue hop leaves the scan's task, so the task-local active span does
    /// not come along; `scan.span` re-establishes it on the queue.
    private func analyzeStill(for imageData: Data, in scan: SpanContext) -> StillAnalysis {
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return StillAnalysis(vehicle: nil, brand: .failed) }

        // A decoded capture is the sensor's landscape buffer; the EXIF tag is
        // what says which way up it should be read.
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let orientation = (properties?[kCGImagePropertyOrientation] as? UInt32)
            .flatMap(CGImagePropertyOrientation.init(rawValue:)) ?? .up

        return detectorQueue.sync {
            let detection: (ran: Bool, vehicle: VehicleDetection?) = scan.span("detect") { _ in
                if detector == nil { detector = VehicleDetector(precision: activePrecision) }
                guard let detector else { return (false, nil) }

                // The largest box, not the most confident one: the subject of the
                // photo is the car filling the frame, and that is what to crop to.
                let vehicle = detector.detect(image, orientation: orientation)
                    .max { $0.frameFraction < $1.frameFraction }
                return (true, vehicle)
            }
            guard detection.ran else { return StillAnalysis(vehicle: nil, brand: .failed) }
            let vehicle = detection.vehicle

            guard activeBrandHintEnabled else { return StillAnalysis(vehicle: vehicle, brand: .disabled) }
            return scan.span("classify") { _ in
                // The classifier loads on first use, so its load lands in this span.
                guard let classifier = brandClassifier else {
                    return StillAnalysis(vehicle: vehicle, brand: .modelUnavailable)
                }
                guard let vehicle else { return StillAnalysis(vehicle: nil, brand: .noVehicle) }
                guard let guess = classifier.classify(image, orientation: orientation,
                                                      box: vehicle.rect) else {
                    return StillAnalysis(vehicle: vehicle, brand: .failed)
                }
                return StillAnalysis(vehicle: vehicle, brand: .guessed(guess))
            }
        }
    }

    /// Cuts the vehicle out of a capture, with a margin so the provider still
    /// sees the whole car and a little of its surroundings.
    ///
    /// `box` is normalized against the upright image, so the orientation has to
    /// be baked into the pixels before the box means anything.
    private func croppedToVehicle(_ image: UIImage, box: CGRect) -> UIImage? {
        let padded = box
            .insetBy(dx: -box.width * Self.scanCropPadding, dy: -box.height * Self.scanCropPadding)
            .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !padded.isNull, padded.width > 0, padded.height > 0 else { return nil }

        let size = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        let upright = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        guard let cgImage = upright.cgImage else { return nil }

        let rect = CGRect(
            x: padded.minX * size.width,
            y: padded.minY * size.height,
            width: padded.width * size.width,
            height: padded.height * size.height
        ).integral
        return cgImage.cropping(to: rect).map(UIImage.init(cgImage:))
    }

    private func updateJob(id: UUID, status: ScanJobStatus) {
        guard let idx = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[idx].status = status
    }

    private func updateThumbnail(id: UUID, image: UIImage?) {
        guard let idx = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[idx].thumbnail = image
    }

    private func updatePhotoMetadata(id: UUID, meta: PhotoMetadata) {
        guard let idx = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[idx].photoMetadata = meta
    }

    private func updateBrandGuess(id: UUID, guess: BrandGuessOutcome, prompt: String) {
        guard let idx = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[idx].brandGuess = guess
        jobs[idx].prompt = prompt
    }

    private func configureSession() {
        let deviceTypes: [AVCaptureDevice.DeviceType] = [
            .builtInTripleCamera, .builtInDualWideCamera, .builtInWideAngleCamera
        ]
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: deviceTypes, mediaType: .video, position: .back
        )
        guard
            let device = discovery.devices.first,
            let input = try? AVCaptureDeviceInput(device: device)
        else {
            DispatchQueue.main.async { self.errorMessage = "Cannot access camera" }
            return
        }
        captureDevice = device
        session.beginConfiguration()
        session.sessionPreset = .photo
        if session.canAddInput(input) { session.addInput(input) }
        if session.canAddOutput(photoOutput) { session.addOutput(photoOutput) }

        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        videoOutput.setSampleBufferDelegate(self, queue: detectorQueue)
        if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }
        // Hand the detector an upright frame: the app is portrait-only, and a
        // sideways image would cost accuracy as well as complicating the
        // mapping from detection rects back to the preview.
        videoOutput.connection(with: .video)?.videoOrientation = .portrait

        session.commitConfiguration()
        session.startRunning()
    }

    private func makeUploadDataAndMeta(_ imageData: Data) -> (Data, PhotoMetadata) {
        guard let image = UIImage(data: imageData) else {
            return (imageData, PhotoMetadata(fileSize: imageData.count, dimensions: nil))
        }
        return makeUploadDataAndMeta(image)
    }

    private func makeUploadDataAndMeta(_ image: UIImage) -> (Data, PhotoMetadata) {
        // The size comes back from the render rather than being recomputed, so
        // the dimensions reported to WildEdge always describe the exact bytes
        // that were uploaded. Detection boxes are scaled by this, and a box
        // scaled against a size the attachment does not have is a wrong box.
        let upload = resizedImage(image, targetWidth: CGFloat(uploadImageSize))
        return (upload.data, PhotoMetadata(fileSize: upload.data.count, dimensions: upload.size))
    }

    private func analyzeImage(
        _ uploadData: Data,
        meta: PhotoMetadata,
        provider: RecognitionProvider,
        prompt carPrompt: String,
        scan: SpanContext
    ) async throws -> [ScanResult] {
        switch provider {
        case .openRouter:
            let (info, raw, stats, inferenceId, inferenceDate, handle) = try await OpenRouterClient().analyze(uploadData, prompt: carPrompt, imageSize: meta.dimensions)
            return [ScanResult(provider: "OpenRouter", info: info, photo: meta, rawJSON: raw, httpStats: stats,
                               inferenceId: inferenceId, inferenceDate: inferenceDate,
                               sendFeedback: makeFeedback(handle, inferenceId: inferenceId, inferenceDate: inferenceDate, scan: scan))]
        case .gemini:
            let (info, raw, stats, inferenceId, inferenceDate, handle) = try await GeminiClient().analyze(uploadData, prompt: carPrompt, imageSize: meta.dimensions)
            return [ScanResult(provider: "Gemini", info: info, photo: meta, rawJSON: raw, httpStats: stats,
                               inferenceId: inferenceId, inferenceDate: inferenceDate,
                               sendFeedback: makeFeedback(handle, inferenceId: inferenceId, inferenceDate: inferenceDate, scan: scan))]
        case .both:
            return try await analyzeWithBoth(uploadData, photo: meta, prompt: carPrompt, scan: scan)
        }
    }

    /// The car prompt, with the on-device classifier's opinion prepended when
    /// it has one worth stating.
    private func prompt(with brand: BrandGuessOutcome) -> String {
        guard let hint = brand.guess?.promptHint else { return carPrompt }
        return hint + "\n\n" + carPrompt
    }

    /// Feedback arrives from the detail view after the scan's trace has ended,
    /// so it carries the scan's ids explicitly.
    private func makeFeedback(_ handle: ModelHandle, inferenceId: String, inferenceDate: Date,
                              scan: SpanContext) -> (FeedbackType) -> Void {
        let (traceId, spanId, runId) = (scan.traceId, scan.spanId, scan.runId)
        return { feedbackType in
            let delayMs = Int(Date().timeIntervalSince(inferenceDate) * 1000)
            handle.trackFeedback(feedbackType, relatedInferenceId: inferenceId, delayMs: delayMs,
                                 traceId: traceId, parentSpanId: spanId, runId: runId)
        }
    }

    /// Shrinks to `targetWidth` if wider, and reports the pixel size it wrote.
    private func resizedImage(_ image: UIImage, targetWidth: CGFloat) -> (data: Data, size: CGSize) {
        let pixelW = image.size.width * image.scale
        let pixelH = image.size.height * image.scale
        let drawSize: CGSize = pixelW > targetWidth
            ? CGSize(width: targetWidth, height: (pixelH * targetWidth / pixelW).rounded())
            : CGSize(width: pixelW, height: pixelH)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        let renderer = UIGraphicsImageRenderer(size: drawSize, format: format)
        let rendered = renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: drawSize)) }
        return (rendered.jpegData(compressionQuality: compressionQuality) ?? Data(), drawSize)
    }

    private func analyzeWithBoth(_ imageData: Data, photo: PhotoMetadata, prompt carPrompt: String,
                                 scan: SpanContext) async throws -> [ScanResult] {
        async let orTask = OpenRouterClient().analyze(imageData, prompt: carPrompt, imageSize: photo.dimensions)
        async let gTask  = GeminiClient().analyze(imageData, prompt: carPrompt, imageSize: photo.dimensions)

        var out: [ScanResult] = []
        var firstError: Error?

        do {
            let (info, raw, stats, inferenceId, inferenceDate, handle) = try await orTask
            out.append(ScanResult(provider: "OpenRouter", info: info, photo: photo, rawJSON: raw, httpStats: stats,
                                  inferenceId: inferenceId, inferenceDate: inferenceDate,
                                  sendFeedback: makeFeedback(handle, inferenceId: inferenceId, inferenceDate: inferenceDate, scan: scan)))
        } catch { firstError = error }

        do {
            let (info, raw, stats, inferenceId, inferenceDate, handle) = try await gTask
            out.append(ScanResult(provider: "Gemini", info: info, photo: photo, rawJSON: raw, httpStats: stats,
                                  inferenceId: inferenceId, inferenceDate: inferenceDate,
                                  sendFeedback: makeFeedback(handle, inferenceId: inferenceId, inferenceDate: inferenceDate, scan: scan)))
        } catch { if firstError == nil { firstError = error } }

        if out.isEmpty, let err = firstError { throw err }
        return out
    }
}

extension CameraViewModel: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let settingsID = photo.resolvedSettings.uniqueID
        guard let capture = pendingCaptures.removeValue(forKey: settingsID) else { return }
        let (jobID, captureProvider) = (capture.jobID, capture.provider)

        if let error {
            updateJob(id: jobID, status: .failed(error.localizedDescription))
            return
        }
        guard let data = photo.fileDataRepresentation() else {
            updateJob(id: jobID, status: .failed("No image data"))
            return
        }

        Task.detached(priority: .userInitiated) { [weak self] in
            await self?.processCapture(imageData: data, jobID: jobID, provider: captureProvider)
        }
    }
}

// MARK: - Live vehicle detection

extension CameraViewModel: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        // Throttle to the detector's frame budget and never queue a second frame.
        let now = CACurrentMediaTime()
        guard !detectionInFlight, now - lastDetectionAt >= activeDetectorInterval else { return }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lastDetectionAt = now
        detectionInFlight = true
        defer { detectionInFlight = false }

        if detector == nil {
            DispatchQueue.main.async { self.detectorStatus = .loading }
            detector = VehicleDetector(precision: activePrecision)
        }
        guard let detector else { return }

        let (found, durationMs) = detector.detect(pixelBuffer, orientation: .up)
        let size = CGSize(width: CVPixelBufferGetWidth(pixelBuffer),
                          height: CVPixelBufferGetHeight(pixelBuffer))
        if !loggedFrameGeometry {
            loggedFrameGeometry = true
            // Should be portrait. If it prints landscape, the connection's
            // videoOrientation did not take and the detector is seeing a
            // sideways frame, which misplaces every box.
            print("[VehicleDetector] detector frame \(Int(size.width))x\(Int(size.height))")
        }
        recentDetectorMs.append(durationMs)
        if recentDetectorMs.count > detectorAverageWindow { recentDetectorMs.removeFirst() }
        let stat = DetectorStat(
            precision: detector.precision,
            averageMs: recentDetectorMs.reduce(0, +) / recentDetectorMs.count
        )

        DispatchQueue.main.async {
            self.detectionFrame = VehicleDetectionFrame(sourceSize: size, detections: found)
            self.detectorStatus = .running(stat)
        }
    }
}
