import SwiftUI
import UIKit

struct ScanSettingsView: View {
    @Binding var imageSize: Int
    @Binding var compression: Double
    @Binding var detectorPrecision: DetectorPrecision
    @Binding var detectorInterval: Double
    @Binding var brandHintEnabled: Bool
    var sourceImage: UIImage?

    @Environment(\.dismiss) private var dismiss
    @State private var cachedSource: UIImage? = nil
    @State private var estimatedBytes: Int? = nil
    @State private var isEstimating = false

    private let imageSizes = [256, 512, 1024, 2048]

    /// Held at a stable string so the row keeps its width while an estimate
    /// is in flight.
    private var estimateText: String {
        guard sourceImage != nil else { return "No image yet" }
        guard let bytes = estimatedBytes else { return "—" }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    /// Shows the gap the slider sets, with the rate it works out to, so that
    /// neither reading of "detection rate" is left to guesswork.
    private var intervalLabel: String {
        String(format: "%.2f s · %.1f fps", detectorInterval, 1 / detectorInterval)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Max width", selection: $imageSize) {
                        ForEach(imageSizes, id: \.self) { size in
                            Text("\(size) px").tag(size)
                        }
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("Upload Width Limit")
                } footer: {
                    Text("Caps the width of the image sent to the provider. A scan uploads the cropped vehicle, so this is the width across the car rather than across the whole scene — the same number buys far more detail than it used to. It only ever shrinks: a crop narrower than this is sent at its own size. When no vehicle is found, the full frame is sent instead.")
                }

                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Compression")
                            Spacer()
                            Text(String(format: "%.2f", compression))
                                .foregroundColor(.secondary)
                                .monospacedDigit()
                        }
                        Slider(value: $compression, in: 0.1...1.0, step: 0.05)
                    }
                } header: {
                    Text("JPEG Compression Quality")
                } footer: {
                    Text("Lower values reduce file size; higher values preserve quality.")
                }

                Section {
                    Picker("Precision", selection: $detectorPrecision) {
                        ForEach(DetectorPrecision.allCases) { precision in
                            Text(precision.title).tag(precision)
                        }
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("On-Device Detector")
                } footer: {
                    Text(detectorPrecision.summary)
                }

                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Interval")
                            Spacer()
                            Text(intervalLabel)
                                .foregroundColor(.secondary)
                                .monospacedDigit()
                        }
                        Slider(
                            value: $detectorInterval,
                            in: CameraViewModel.detectorIntervalRange,
                            step: 0.05
                        )
                    }
                } header: {
                    Text("Detection Interval")
                } footer: {
                    Text("How long the app waits between checking the live camera frame for a vehicle. Drag right to wait longer, which updates the overlay less often and uses less battery. It does not affect scanning: a shutter press always runs the detector on the captured photo.")
                }

                Section {
                    Toggle("Brand Hint", isOn: $brandHintEnabled)
                } header: {
                    Text("On-Device Brand Classifier")
                } footer: {
                    Text("Names the car's brand on device and adds that guess to the prompt sent to the provider. Turning this off skips the classifier entirely, so the provider sees the photo with no local opinion attached.")
                }

                Section {
                    HStack {
                        Label("File size", systemImage: "doc")
                        Spacer()
                        // The spinner sits in an overlay rather than replacing
                        // the value: swapping a narrow ProgressView for a wide
                        // string re-sizes the row every time an estimate runs.
                        Text(estimateText)
                            .foregroundColor(.secondary)
                            .monospacedDigit()
                            .opacity(isEstimating ? 0 : 1)
                            .overlay {
                                if isEstimating {
                                    ProgressView().progressViewStyle(.circular)
                                }
                            }
                    }
                } header: {
                    Text("Estimated Upload Size")
                } footer: {
                    Text("Based on the most recent scan, which is the cropped vehicle when one was found. How tightly the car is framed therefore moves this as much as the settings above do.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear { warmUp() }
            .onChange(of: imageSize)   { _ in reestimate() }
            .onChange(of: compression) { _ in reestimate() }
        }
    }

    private func warmUp() {
        guard let source = sourceImage else { return }
        isEstimating = true
        Task.detached(priority: .userInitiated) {
            let maxWidth: CGFloat = 2048
            let prepared = downsample(source: source, targetWidth: maxWidth)
            let bytes = estimateBytes(source: prepared, targetWidth: CGFloat(imageSize), compression: compression)
            await MainActor.run {
                cachedSource = prepared
                estimatedBytes = bytes
                isEstimating = false
            }
        }
    }

    private func reestimate() {
        guard let source = cachedSource ?? sourceImage else { return }
        isEstimating = true
        let targetWidth = CGFloat(imageSize)
        let quality = compression
        Task.detached(priority: .userInitiated) {
            let bytes = estimateBytes(source: source, targetWidth: targetWidth, compression: quality)
            await MainActor.run {
                estimatedBytes = bytes
                isEstimating = false
            }
        }
    }

    private func downsample(source: UIImage, targetWidth: CGFloat) -> UIImage {
        let pixelW = source.size.width * source.scale
        guard pixelW > targetWidth else { return source }
        let pixelH = source.size.height * source.scale
        let newH = (pixelH * targetWidth / pixelW).rounded()
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: targetWidth, height: newH), format: format)
        return renderer.image { _ in
            source.draw(in: CGRect(origin: .zero, size: CGSize(width: targetWidth, height: newH)))
        }
    }

    private func estimateBytes(source: UIImage, targetWidth: CGFloat, compression: Double) -> Int {
        let pixelW = source.size.width * source.scale
        let pixelH = source.size.height * source.scale
        let (newW, newH): (CGFloat, CGFloat) = pixelW > targetWidth
            ? (targetWidth, (pixelH * targetWidth / pixelW).rounded())
            : (pixelW, pixelH)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: newW, height: newH), format: format)
        let resized = renderer.image { _ in
            source.draw(in: CGRect(origin: .zero, size: CGSize(width: newW, height: newH)))
        }
        return resized.jpegData(compressionQuality: compression)?.count ?? 0
    }
}
