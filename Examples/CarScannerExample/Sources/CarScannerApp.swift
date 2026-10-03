import SwiftUI
import WildEdge

@main
struct CarScannerApp: App {
    init() {
        WildEdge.initialize() { builder in
            builder.enableAttachments = true
            builder.enableCompression = true
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
