import SwiftUI
import AVFoundation

struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession
    var detectionFrame = VehicleDetectionFrame()

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.videoLayer.session = session
        view.videoLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        uiView.detectionFrame = detectionFrame
    }

    class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var videoLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }

        var detectionFrame = VehicleDetectionFrame() {
            didSet { redrawBoxes() }
        }

        private let boxLayer = CALayer()

        override init(frame: CGRect) {
            super.init(frame: frame)
            layer.addSublayer(boxLayer)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func layoutSubviews() {
            super.layoutSubviews()
            boxLayer.frame = bounds
            redrawBoxes()
        }

        /// Where the video actually lands on screen under `.resizeAspectFill`.
        ///
        /// The layer's own `layerRectConverted(fromMetadataOutputRect:)` is not
        /// usable here: metadata-output space is the capture device's, which
        /// stays landscape-referenced while the frames are rotated to portrait,
        /// so rects come out with their axes transposed. Aspect-fill is a scale
        /// and a centre, so doing it directly is both shorter and unambiguous.
        private var videoRect: CGRect? {
            let source = detectionFrame.sourceSize
            guard source.width > 0, source.height > 0, bounds.width > 0, bounds.height > 0 else { return nil }
            let scale = max(bounds.width / source.width, bounds.height / source.height)
            let shown = CGSize(width: source.width * scale, height: source.height * scale)
            return CGRect(
                x: (bounds.width - shown.width) / 2,
                y: (bounds.height - shown.height) / 2,
                width: shown.width,
                height: shown.height
            )
        }

        private func redrawBoxes() {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            boxLayer.sublayers?.forEach { $0.removeFromSuperlayer() }
            defer { CATransaction.commit() }

            guard let video = videoRect else { return }

            for detection in detectionFrame.detections {
                let rect = CGRect(
                    x: video.minX + detection.rect.minX * video.width,
                    y: video.minY + detection.rect.minY * video.height,
                    width: detection.rect.width * video.width,
                    height: detection.rect.height * video.height
                ).intersection(bounds)
                guard rect.width > 1, rect.height > 1 else { continue }

                let box = CAShapeLayer()
                box.frame = rect
                box.path = UIBezierPath(roundedRect: CGRect(origin: .zero, size: rect.size), cornerRadius: 6).cgPath
                box.strokeColor = UIColor(red: 0.0, green: 0.718, blue: 0.545, alpha: 1).cgColor
                box.fillColor = UIColor.clear.cgColor
                box.lineWidth = 2
                boxLayer.addSublayer(box)

                let caption = CATextLayer()
                caption.string = "\(detection.label) \(Int(detection.confidence * 100))%"
                caption.fontSize = 11
                caption.alignmentMode = .center
                caption.foregroundColor = UIColor.white.cgColor
                caption.backgroundColor = UIColor(red: 0.0, green: 0.718, blue: 0.545, alpha: 0.85).cgColor
                caption.cornerRadius = 3
                caption.contentsScale = UIScreen.main.scale
                caption.frame = CGRect(x: rect.minX, y: max(0, rect.minY - 16), width: 96, height: 15)
                boxLayer.addSublayer(caption)
            }
        }
    }
}
