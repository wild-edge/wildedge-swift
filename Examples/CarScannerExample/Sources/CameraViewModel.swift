import AVFoundation
import WildEdge
import Combine
import UIKit

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
    var status: ScanJobStatus = .scanning
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
    @Published var jobs: [ScanJob] = []
    @Published var errorMessage: String?
    @Published var provider: RecognitionProvider = .openRouter

    let session = AVCaptureSession()
    private let photoOutput = AVCapturePhotoOutput()
    private let sessionQueue = DispatchQueue(label: "dev.wildedge.carscanner.session")
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
            guard let self else { return }
            let thumbnail = UIImage(data: imageData)?.preparingThumbnail(of: CGSize(width: 400, height: 400))
            let (uploadData, meta) = self.makeUploadDataAndMeta(imageData)
            await MainActor.run {
                self.updateThumbnail(id: jobID, image: thumbnail)
                self.updatePhotoMetadata(id: jobID, meta: meta)
            }
            do {
                let results = try await self.analyzeImage(uploadData, meta: meta, provider: captureProvider)
                await MainActor.run { self.updateJob(id: jobID, status: .completed(results)) }
            } catch {
                await MainActor.run { self.updateJob(id: jobID, status: .failed(error.localizedDescription)) }
            }
        }
    }

    func removeJob(id: UUID) {
        jobs.removeAll { $0.id == id }
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
        session.commitConfiguration()
        session.startRunning()
    }

    private func makeUploadDataAndMeta(_ imageData: Data) -> (Data, PhotoMetadata) {
        let uploadData = resizedImageData(imageData)
        let dims: CGSize? = UIImage(data: imageData).map { img in
            let w = img.size.width * img.scale
            let h = img.size.height * img.scale
            guard w > 512 else { return CGSize(width: w, height: h) }
            return CGSize(width: 512, height: (h * 512 / w).rounded())
        }
        return (uploadData, PhotoMetadata(fileSize: uploadData.count, dimensions: dims))
    }

    private func analyzeImage(_ uploadData: Data, meta: PhotoMetadata, provider: RecognitionProvider) async throws -> [ScanResult] {
        switch provider {
        case .openRouter:
            let (info, raw, stats, inferenceId, inferenceDate) = try await OpenRouterClient().analyze(uploadData, prompt: carPrompt, imageSize: meta.dimensions)
            return [ScanResult(provider: "OpenRouter", info: info, photo: meta, rawJSON: raw, httpStats: stats,
                               inferenceId: inferenceId, inferenceDate: inferenceDate,
                               sendFeedback: makeFeedback(OpenRouterClient.handle, inferenceId: inferenceId, inferenceDate: inferenceDate))]
        case .gemini:
            let (info, raw, stats, inferenceId, inferenceDate) = try await GeminiClient().analyze(uploadData, prompt: carPrompt, imageSize: meta.dimensions)
            return [ScanResult(provider: "Gemini", info: info, photo: meta, rawJSON: raw, httpStats: stats,
                               inferenceId: inferenceId, inferenceDate: inferenceDate,
                               sendFeedback: makeFeedback(GeminiClient.handle, inferenceId: inferenceId, inferenceDate: inferenceDate))]
        case .both:
            return try await analyzeWithBoth(uploadData, photo: meta)
        }
    }

    private func makeFeedback(_ handle: ModelHandle, inferenceId: String, inferenceDate: Date) -> (FeedbackType) -> Void {
        { feedbackType in
            let delayMs = Int(Date().timeIntervalSince(inferenceDate) * 1000)
            handle.trackFeedback(feedbackType, relatedInferenceId: inferenceId, delayMs: delayMs)
        }
    }

    private func resizedImageData(_ data: Data, targetWidth: CGFloat = 512) -> Data {
        guard let image = UIImage(data: data) else { return data }
        let pixelW = image.size.width * image.scale
        let pixelH = image.size.height * image.scale
        guard pixelW > targetWidth else { return data }
        let ratio = targetWidth / pixelW
        let newSize = CGSize(width: targetWidth, height: (pixelH * ratio).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        let renderer = UIGraphicsImageRenderer(size: newSize, format: format)
        let resized = renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: newSize)) }
        return resized.jpegData(compressionQuality: 0.7) ?? data
    }

    private func analyzeWithBoth(_ imageData: Data, photo: PhotoMetadata) async throws -> [ScanResult] {
        let sharedRunId = "both-\(UUID().uuidString)"
        async let orTask = OpenRouterClient().analyze(imageData, prompt: carPrompt, imageSize: photo.dimensions, runId: sharedRunId)
        async let gTask  = GeminiClient().analyze(imageData, prompt: carPrompt, imageSize: photo.dimensions, runId: sharedRunId)

        var out: [ScanResult] = []
        var firstError: Error?

        do {
            let (info, raw, stats, inferenceId, inferenceDate) = try await orTask
            out.append(ScanResult(provider: "OpenRouter", info: info, photo: photo, rawJSON: raw, httpStats: stats,
                                  inferenceId: inferenceId, inferenceDate: inferenceDate,
                                  sendFeedback: makeFeedback(OpenRouterClient.handle, inferenceId: inferenceId, inferenceDate: inferenceDate)))
        } catch { firstError = error }

        do {
            let (info, raw, stats, inferenceId, inferenceDate) = try await gTask
            out.append(ScanResult(provider: "Gemini", info: info, photo: photo, rawJSON: raw, httpStats: stats,
                                  inferenceId: inferenceId, inferenceDate: inferenceDate,
                                  sendFeedback: makeFeedback(GeminiClient.handle, inferenceId: inferenceId, inferenceDate: inferenceDate)))
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
            guard let self else { return }
            let thumbnail = UIImage(data: data)?.preparingThumbnail(of: CGSize(width: 400, height: 400))
            let (uploadData, meta) = self.makeUploadDataAndMeta(data)
            await MainActor.run {
                self.updateThumbnail(id: jobID, image: thumbnail)
                self.updatePhotoMetadata(id: jobID, meta: meta)
            }
            do {
                let results = try await self.analyzeImage(uploadData, meta: meta, provider: captureProvider)
                await MainActor.run { self.updateJob(id: jobID, status: .completed(results)) }
            } catch {
                await MainActor.run { self.updateJob(id: jobID, status: .failed(error.localizedDescription)) }
            }
        }
    }
}
