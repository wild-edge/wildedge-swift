import SwiftUI

@main
struct VoiceRecorderApp: App {
    @StateObject private var settingsStore = SettingsStore()

    var body: some Scene {
        WindowGroup {
            RecordingView()
                .environmentObject(settingsStore)
        }
    }
}
