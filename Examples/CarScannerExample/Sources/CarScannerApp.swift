import SwiftUI
import WildEdge

@main
struct CarScannerApp: App {
    init() {
        WildEdge.initialize() { builder in
            builder.enableAttachments = true
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
