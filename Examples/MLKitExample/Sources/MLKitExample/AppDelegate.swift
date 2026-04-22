import UIKit
import MLKitFaceDetection
import MLKitVision
import WildEdge

@main
class AppDelegate: UIResponder, UIApplicationDelegate {

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        // WildEdge auto-inits via +load using WILDEDGE_DSN from the environment.
        // MLKitFaceDetectorInterceptor automatically swizzles FaceDetector —
        // no manual registerModel / trackInference calls are needed.
        runInference()
        return true
    }

    private func runInference() {
        let options = FaceDetectorOptions()
        options.performanceMode = .accurate
        // Creating via FaceDetector.faceDetector(options:) is intercepted → trackLoad fires.
        let detector = FaceDetector.faceDetector(options: options)

        guard let image = makeSampleImage() else {
            print("[MLKitExample] failed to create sample image")
            return
        }

        // process(_:completion:) is intercepted → trackInference fires automatically.
        detector.process(VisionImage(image: image)) { faces, error in
            if let error {
                print("[MLKitExample] detection error: \(error)")
                return
            }
            let count = faces?.count ?? 0
            print("[MLKitExample] detected \(count) face(s)")
            print("[MLKitExample] pending WildEdge events: \(WildEdge.shared.pendingCount)")
        }
    }

    private func makeSampleImage() -> UIImage? {
        let size = CGSize(width: 128, height: 128)
        UIGraphicsBeginImageContext(size)
        defer { UIGraphicsEndImageContext() }
        UIColor.gray.setFill()
        UIRectFill(CGRect(origin: .zero, size: size))
        return UIGraphicsGetImageFromCurrentImageContext()
    }
}
