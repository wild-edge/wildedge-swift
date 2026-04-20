import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = DemoViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("WildEdge iOS Sample")
                .font(.title2)
                .bold()

            Text(viewModel.statusText)
                .font(.footnote)
                .foregroundColor(.secondary)

            Button(viewModel.isRunning ? "Running..." : "Run Inference") {
                viewModel.runDemo()
            }
            .disabled(viewModel.isRunning)

            ScrollView {
                Text(viewModel.logText)
                    .font(.system(.footnote, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .background(Color(UIColor.secondarySystemBackground))
            .cornerRadius(8)
        }
        .padding(16)
        .onAppear {
            viewModel.initializeIfNeeded()
        }
    }
}
