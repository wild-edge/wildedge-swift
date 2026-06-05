import SwiftUI
import PhotosUI

struct ContentView: View {
    @StateObject private var viewModel = CameraViewModel()
    @State private var baseZoom: CGFloat = 1.0
    @State private var isPinching: Bool = false
    @State private var selectedJobID: UUID?
    @State private var selectedPickerItem: PhotosPickerItem?
    @State private var showSettings = false
    @State private var triviaText = ""
    @State private var triviaReady = false
    @State private var delayElapsed = false
    private var marqueeActive: Bool { triviaReady && delayElapsed }

    private let columns = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]

    private var selectedJob: ScanJob? {
        guard let id = selectedJobID else { return nil }
        return viewModel.jobs.first { $0.id == id }
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            CameraPreviewView(session: viewModel.session)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                HStack(spacing: 2) {
                    ForEach(RecognitionProvider.allCases, id: \.self) { option in
                        Button { viewModel.provider = option } label: {
                            Label(option.rawValue, systemImage: option.icon)
                                .font(.system(size: 13, weight: viewModel.provider == option ? .semibold : .regular))
                                .foregroundColor(viewModel.provider == option
                                    ? Color(red: 0.008, green: 0.251, blue: 0.475)
                                    : .white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 7)
                                .background {
                                    if viewModel.provider == option {
                                        RoundedRectangle(cornerRadius: 7).fill(Color.white)
                                    }
                                }
                        }
                    }
                }
                .padding(3)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(LinearGradient(
                            colors: [Color(red: 0.008, green: 0.251, blue: 0.475, opacity: 0.65),
                                     Color(red: 0.000, green: 0.718, blue: 0.545, opacity: 0.65)],
                            startPoint: .leading,
                            endPoint: .trailing
                        ))
                )
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 12)

                ScrollView(showsIndicators: false) {
                    LazyVGrid(columns: columns, spacing: 8) {
                        ForEach(viewModel.jobs) { job in
                            ScanJobCell(
                                job: job,
                                onTap:     { withAnimation(.spring(duration: 0.35, bounce: 0.25)) { selectedJobID = job.id } },
                                onDismiss: { withAnimation { viewModel.removeJob(id: job.id) } }
                            )
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .scrollDisabled(isPinching)

                if let error = viewModel.errorMessage {
                    Text(error)
                        .font(.caption)
                        .multilineTextAlignment(.center)
                        .foregroundColor(.white)
                        .padding(10)
                        .background(Color.red.opacity(0.85))
                        .cornerRadius(10)
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                }

                ZStack {
                    ScanButton(action: viewModel.scan)
                    HStack {
                        Button { showSettings = true } label: {
                            ZStack {
                                Circle().fill(Color.white.opacity(0.2)).frame(width: 50, height: 50)
                                Image(systemName: "gearshape").font(.system(size: 18)).foregroundColor(.white)
                            }
                        }
                        Spacer()
                        PhotosPicker(selection: $selectedPickerItem, matching: .images) {
                            ZStack {
                                Circle().fill(Color.white.opacity(0.2)).frame(width: 50, height: 50)
                                Image(systemName: "photo").font(.system(size: 18)).foregroundColor(.white)
                            }
                        }
                    }
                    .padding(.horizontal, 36)
                }
                .padding(.top, 16)
                .padding(.bottom, 8)
                .onChange(of: selectedPickerItem) { item in
                    guard let item else { return }
                    Task {
                        if let data = try? await item.loadTransferable(type: Data.self) {
                            viewModel.analyzeSelectedPhoto(data)
                        }
                        selectedPickerItem = nil
                    }
                }

                HStack(spacing: 0) {
                    Link(destination: URL(string: "https://wildedge.dev")!) {
                        Image("WildEdgeLogo")
                            .renderingMode(.template)
                            .resizable()
                            .scaledToFit()
                            .frame(height: 14)
                            .foregroundColor(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                    }
                    Rectangle()
                        .fill(Color.white.opacity(0.3))
                        .frame(width: 1, height: 18)
                    Group {
                        if marqueeActive {
                            MarqueeText(text: triviaText, speed: 50)
                                .id(triviaText)
                        } else {
                            Text("WE Scan")
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .font(.system(size: 10, weight: .regular, design: .monospaced))
                    .foregroundColor(.white.opacity(0.85))
                    .frame(maxWidth: .infinity, maxHeight: 28)
                    .padding(.horizontal, 10)
                }
                .padding(3)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(LinearGradient(
                            colors: [Color(red: 0.008, green: 0.251, blue: 0.475, opacity: 0.65),
                                     Color(red: 0.000, green: 0.718, blue: 0.545, opacity: 0.65)],
                            startPoint: .leading,
                            endPoint: .trailing
                        ))
                )
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 8)
            }

            if let job = selectedJob {
                ScanJobDetailView(job: job) {
                    selectedJobID = nil
                }
                .transition(
                    .asymmetric(
                        insertion: .scale(scale: 0.88, anchor: .center).combined(with: .opacity),
                        removal: .identity
                    )
                )
            }
        }
        .sheet(isPresented: $showSettings) {
            ScanSettingsView(
                imageSize: $viewModel.uploadImageSize,
                compression: $viewModel.compressionQuality,
                sourceImage: viewModel.lastCapturedImage
            )
        }
        .simultaneousGesture(
            MagnificationGesture()
                .onChanged { scale in
                    isPinching = true
                    viewModel.zoom(to: baseZoom * scale)
                }
                .onEnded { scale in
                    isPinching = false
                    baseZoom = max(viewModel.minZoom, min(baseZoom * scale, viewModel.maxZoom))
                }
        )
        .onAppear {
            viewModel.setupCamera()
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                withAnimation { delayElapsed = true }
            }
        }
        .task { await fetchTrivia() }
    }

    private func fetchTrivia() async {
        let url = URL(string: "https://opentdb.com/api.php?amount=15&category=28&type=multiple&encode=url3986")!
        guard let (data, _) = try? await URLSession.shared.data(from: url) else { return }

        struct Response: Decodable {
            struct Item: Decodable { let question: String; let correct_answer: String }
            let results: [Item]
        }
        guard let decoded = try? JSONDecoder().decode(Response.self, from: data),
              !decoded.results.isEmpty else { return }

        let facts = decoded.results.compactMap { item -> String? in
            guard let q = item.question.removingPercentEncoding,
                  let a = item.correct_answer.removingPercentEncoding else { return nil }
            return "\(q)  →  \(a)"
        }
        triviaText = facts.joined(separator: "     ·     ")
        triviaReady = true
    }
}
