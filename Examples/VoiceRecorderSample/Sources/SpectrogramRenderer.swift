import Accelerate
import AVFoundation
import UIKit

enum SpectrogramRendererError: LocalizedError {
    case emptyAudio
    case unsupportedAudioFormat
    case imageEncodingFailed

    var errorDescription: String? {
        switch self {
        case .emptyAudio:
            return "The recording does not contain audio samples."
        case .unsupportedAudioFormat:
            return "Could not read the recording as mono floating-point audio."
        case .imageEncodingFailed:
            return "Could not encode the audio spectrogram image."
        }
    }
}

struct AudioSpectrogramRenderer {
    private let frameSize = 1024
    private let hopSize = 256
    private let minDecibels: Float = -80
    private let maxColumns = 768

    func renderPNG(from url: URL) throws -> URL {
        let samples = try loadMonoSamples(from: url)
        let columns = try makeSpectrogramColumns(from: samples)
        let image = makeImage(from: columns)

        guard let pngData = image.pngData() else {
            throw SpectrogramRendererError.imageEncodingFailed
        }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("spectrogram-\(UUID().uuidString).png")
        try pngData.write(to: outputURL, options: .atomic)
        return outputURL
    }

    private func loadMonoSamples(from url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let frameCount = AVAudioFrameCount(file.length)

        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)
        else {
            throw SpectrogramRendererError.emptyAudio
        }

        try file.read(into: buffer)

        guard let channels = buffer.floatChannelData else {
            throw SpectrogramRendererError.unsupportedAudioFormat
        }

        let channelCount = Int(format.channelCount)
        let frames = Int(buffer.frameLength)
        guard channelCount > 0, frames > 0 else {
            throw SpectrogramRendererError.emptyAudio
        }

        var mono = [Float](repeating: 0, count: frames)
        for frame in 0..<frames {
            var sample: Float = 0
            for channel in 0..<channelCount {
                sample += channels[channel][frame]
            }
            mono[frame] = sample / Float(channelCount)
        }

        return mono
    }

    private func makeSpectrogramColumns(from sourceSamples: [Float]) throws -> [[Float]] {
        guard !sourceSamples.isEmpty else {
            throw SpectrogramRendererError.emptyAudio
        }

        var samples = sourceSamples
        if samples.count < frameSize {
            samples += [Float](repeating: 0, count: frameSize - samples.count)
        }

        let frameCount = max(1, (samples.count - frameSize) / hopSize + 1)
        let frameStride = max(1, frameCount / maxColumns)
        var window = [Float](repeating: 0, count: frameSize)
        for index in 0..<frameSize {
            window[index] = 0.5 - 0.5 * cos(2 * .pi * Float(index) / Float(frameSize - 1))
        }

        let log2n = vDSP_Length(log2(Float(frameSize)))
        guard let fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            throw SpectrogramRendererError.unsupportedAudioFormat
        }
        defer { vDSP_destroy_fftsetup(fftSetup) }

        var columns: [[Float]] = []
        columns.reserveCapacity(min(frameCount, maxColumns))

        for frameIndex in stride(from: 0, to: frameCount, by: frameStride) {
            let start = frameIndex * hopSize
            let frame = Array(samples[start..<(start + frameSize)])
            var windowedFrame = [Float](repeating: 0, count: frameSize)
            vDSP_vmul(frame, 1, window, 1, &windowedFrame, 1, vDSP_Length(frameSize))

            var real = [Float](repeating: 0, count: frameSize / 2)
            var imaginary = [Float](repeating: 0, count: frameSize / 2)
            var magnitudes = [Float](repeating: 0, count: frameSize / 2)

            real.withUnsafeMutableBufferPointer { realPointer in
                imaginary.withUnsafeMutableBufferPointer { imaginaryPointer in
                    var splitComplex = DSPSplitComplex(
                        realp: realPointer.baseAddress!,
                        imagp: imaginaryPointer.baseAddress!
                    )

                    windowedFrame.withUnsafeBufferPointer { framePointer in
                        framePointer.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: frameSize / 2) { complexPointer in
                            vDSP_ctoz(complexPointer, 2, &splitComplex, 1, vDSP_Length(frameSize / 2))
                        }
                    }

                    vDSP_fft_zrip(fftSetup, &splitComplex, 1, log2n, FFTDirection(FFT_FORWARD))
                    vDSP_zvabs(&splitComplex, 1, &magnitudes, 1, vDSP_Length(frameSize / 2))
                }
            }

            var normalized = [Float](repeating: 0, count: magnitudes.count)
            var scale = Float(1.0 / Float(frameSize))
            vDSP_vsmul(magnitudes, 1, &scale, &normalized, 1, vDSP_Length(magnitudes.count))

            let decibels = normalized.map { magnitude -> Float in
                let db = 20 * log10(max(magnitude, 1e-7))
                return min(1, max(0, (db - minDecibels) / abs(minDecibels)))
            }
            columns.append(decibels)
        }

        return columns
    }

    private func makeImage(from columns: [[Float]]) -> UIImage {
        let width = max(1, columns.count)
        let height = max(1, columns.first?.count ?? 1)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)

        for x in 0..<width {
            let column = columns[x]
            for y in 0..<height {
                let value = column[height - 1 - y]
                let color = colorRamp(value)
                let offset = (y * width + x) * 4
                pixels[offset] = color.red
                pixels[offset + 1] = color.green
                pixels[offset + 2] = color.blue
                pixels[offset + 3] = 255
            }
        }

        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height))
        return renderer.image { context in
            let cgContext = context.cgContext
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            let imageData = Data(pixels)
            guard let provider = CGDataProvider(data: imageData as CFData) else {
                return
            }

            let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
            guard let image = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: bitmapInfo,
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
            ) else {
                    return
            }

            cgContext.interpolationQuality = .none
            cgContext.draw(image, in: CGRect(origin: .zero, size: CGSize(width: width, height: height)))
        }
    }

    private func colorRamp(_ value: Float) -> (red: UInt8, green: UInt8, blue: UInt8) {
        let clamped = min(1, max(0, value))
        let red = UInt8(min(255, max(0, (clamped * 2 - 0.5) * 255)))
        let green = UInt8(min(255, max(0, (1 - abs(clamped - 0.5) * 2) * 255)))
        let blue = UInt8(min(255, max(0, (1.1 - clamped * 1.8) * 255)))
        return (red, green, blue)
    }
}
