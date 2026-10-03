import SwiftUI
import WildEdge

@main
struct CarScannerApp: App {
    private let runSession: WildEdgeRunSession

    init() {
        WildEdge.initialize() { builder in
            builder.enableAttachments = true
            builder.enableCompression = true
        }
        runSession = WildEdgeRunSession()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
