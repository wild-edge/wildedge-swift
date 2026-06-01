import SwiftUI
import WildEdge

@main
struct ExecuTorchExampleApp: App {
    init() {
        WildEdge.initialize()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
