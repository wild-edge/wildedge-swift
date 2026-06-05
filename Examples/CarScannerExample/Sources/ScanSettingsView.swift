import SwiftUI
import UIKit

struct ScanSettingsView: View {
    @Binding var imageSize: Int
    @Binding var compression: Double
    var sourceImage: UIImage?

    @Environment(\.dismiss) private var dismiss
    @State private var cachedSource: UIImage? = nil
    @State private var estimatedBytes: Int? = nil
    @State private var isEstimating = false

    private let imageSizes = [256, 512, 1024, 2048]

    var body: some View {
        NavigationView {
            Form {
                Section("Upload Image Size") {
                    Picker("Size", selection: $imageSize) {
                        ForEach(imageSizes, id: \.self) { size in
                            Text("\(size) px").tag(size)
                        }
                    }
                    .pickerStyle(.segmented)
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

                Section("Estimated Upload Size") {
                    HStack {
                        Label("File size", systemImage: "doc")
                        Spacer()
                        if sourceImage == nil {
                            Text("No image yet")
                                .foregroundColor(.secondary)
                        } else if isEstimating {
                            ProgressView().progressViewStyle(.circular)
                        } else if let bytes = estimatedBytes {
                            Text(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))
                                .foregroundColor(.secondary)
                                .monospacedDigit()
                        }
                    }
                }
                .id("\(imageSize)-\(String(format: "%.2f", compression))")
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
