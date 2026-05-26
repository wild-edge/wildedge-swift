import SwiftUI
import WildEdge

@main
struct LlamaExampleApp: App {
    init() {
        WildEdge.initialize()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
