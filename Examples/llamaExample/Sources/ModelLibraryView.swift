import SwiftUI
import UniformTypeIdentifiers

struct ModelLibraryView: View {
    @ObservedObject var downloader: ModelDownloader
    var onLoad: (URL) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var isShowingFilePicker = false
    @State private var errorMessage: String?
    @State private var showError = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(modelCatalog) { model in
                        ModelRow(model: model, downloader: downloader) {
                            onLoad(downloader.localURL(for: model))
                            dismiss()
                        }
                    }
                } header: {
                    Text("Download")
                }

                Section {
                    Button {
                        isShowingFilePicker = true
                    } label: {
                        Label("Pick from Files", systemImage: "folder")
                    }
                } header: {
                    Text("Or")
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Pick Model")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
        .fileImporter(
            isPresented: $isShowingFilePicker,
            allowedContentTypes: [UTType(filenameExtension: "gguf") ?? .data],
            allowsMultipleSelection: false
        ) { result in
            handleFileSelection(result)
        }
        .alert("Error", isPresented: $showError, presenting: errorMessage) { _ in
            Button("OK") {}
        } message: { msg in
            Text(msg)
        }
    }

    private func handleFileSelection(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            let accessing = url.startAccessingSecurityScopedResource()
            Task {
                let tempURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent(url.lastPathComponent)
                do {
                    try? FileManager.default.removeItem(at: tempURL)
                    try FileManager.default.copyItem(at: url, to: tempURL)
                } catch {
                    if accessing { url.stopAccessingSecurityScopedResource() }
                    errorMessage = "Could not copy model file: \(error.localizedDescription)"
                    showError = true
                    return
                }
                if accessing { url.stopAccessingSecurityScopedResource() }
                onLoad(tempURL)
                dismiss()
            }
        case .failure(let error):
            errorMessage = error.localizedDescription
            showError = true
        }
    }
}

// MARK: -

private struct ModelRow: View {
    let model: CatalogModel
    @ObservedObject var downloader: ModelDownloader
    var onLoad: () -> Void

    private var state: ModelDownloader.DownloadState? { downloader.currentState(for: model) }
    private var downloaded: Bool { downloader.isDownloaded(model) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.name)
                        .font(.headline)
                    Text(model.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                actionControl
            }

            progressRow
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var progressRow: some View {
        if case .downloading(let progress, let received, let total) = state {
            VStack(alignment: .leading, spacing: 3) {
                ProgressView(value: progress)
                HStack {
                    Text("\(formatBytes(received)) / \(total > 0 ? formatBytes(total) : model.sizeLabel)")
                    Spacer()
                    Text(String(format: "%.0f%%", progress * 100))
                }
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            }
        } else if case .failed(let msg) = state {
            Text("Error: \(msg)")
                .font(.caption)
                .foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private var actionControl: some View {
        if case .downloading = state {
            Button {
                downloader.cancel(model)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.red)
            }
            .buttonStyle(.borderless)

        } else if downloaded {
            HStack(spacing: 10) {
                Button(role: .destructive) {
                    downloader.delete(model)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)

                Button("Load", action: onLoad)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }

        } else if case .failed = state {
            Button("Retry") { downloader.download(model) }
                .buttonStyle(.bordered)
                .controlSize(.small)

        } else {
            HStack(spacing: 6) {
                Text(model.sizeLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("↓ Download") { downloader.download(model) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let mb = Double(bytes) / 1_048_576
        return mb >= 1000
            ? String(format: "%.1f GB", mb / 1024)
            : String(format: "%.0f MB", mb)
    }
}
