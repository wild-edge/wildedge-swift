import SwiftUI
import UniformTypeIdentifiers

struct ModelLibraryView: View {
    @ObservedObject var downloader: ModelDownloader
    /// Called when the user selects a ready model. Provides both the .pte and tokenizer URLs.
    var onLoad: (URL, URL) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var isShowingModelPicker = false
    @State private var isShowingTokenizerPicker = false
    @State private var pickedModelURL: URL?
    @State private var pickedTokenizerURL: URL?
    @State private var errorMessage: String?
    @State private var showError = false

    private static let documentsURL =
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(modelCatalog) { model in
                        ModelRow(model: model, downloader: downloader) {
                            onLoad(
                                downloader.modelLocalURL(for: model),
                                downloader.tokenizerLocalURL(for: model)
                            )
                            dismiss()
                        }
                    }
                } header: {
                    Text("Download")
                } footer: {
                    Text("These models require accepting the Llama 3.2 Community License on HuggingFace before the download will succeed.")
                        .font(.caption)
                }

                Section {
                    customFilesRow
                } header: {
                    Text("Or pick from Files")
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
            isPresented: $isShowingModelPicker,
            allowedContentTypes: [UTType(filenameExtension: "pte") ?? .data],
            allowsMultipleSelection: false
        ) { handleFilePick($0, kind: .model) }
        .fileImporter(
            isPresented: $isShowingTokenizerPicker,
            allowedContentTypes: [.data],
            allowsMultipleSelection: false
        ) { handleFilePick($0, kind: .tokenizer) }
        .alert("Error", isPresented: $showError, presenting: errorMessage) { _ in
            Button("OK") {}
        } message: { msg in Text(msg) }
    }

    // MARK: - Custom files section

    @ViewBuilder
    private var customFilesRow: some View {
        VStack(alignment: .leading, spacing: 12) {
            pickerRow(
                label: "Model (.pte)",
                filename: pickedModelURL?.lastPathComponent,
                action: { isShowingModelPicker = true }
            )
            pickerRow(
                label: "Tokenizer (.json / .model / .bin)",
                filename: pickedTokenizerURL?.lastPathComponent,
                action: { isShowingTokenizerPicker = true }
            )
            Button {
                guard let mURL = pickedModelURL, let tURL = pickedTokenizerURL else { return }
                onLoad(mURL, tURL)
                dismiss()
            } label: {
                Label("Load Custom Model", systemImage: "folder")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(pickedModelURL == nil || pickedTokenizerURL == nil)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func pickerRow(label: String, filename: String?, action: @escaping () -> Void) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(filename ?? "Not selected")
                    .font(.subheadline)
                    .foregroundStyle(filename != nil ? .primary : .tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button("Browse", action: action)
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
    }

    // MARK: - File picking

    private enum FileKind { case model, tokenizer }

    private func handleFilePick(_ result: Result<[URL], Error>, kind: FileKind) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            let accessing = url.startAccessingSecurityScopedResource()
            let dest = Self.documentsURL.appendingPathComponent(url.lastPathComponent)
            do {
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.copyItem(at: url, to: dest)
                if accessing { url.stopAccessingSecurityScopedResource() }
                switch kind {
                case .model:     pickedModelURL = dest
                case .tokenizer: pickedTokenizerURL = dest
                }
            } catch {
                if accessing { url.stopAccessingSecurityScopedResource() }
                errorMessage = "Could not copy file: \(error.localizedDescription)"
                showError = true
            }
        case .failure(let error):
            errorMessage = error.localizedDescription
            showError = true
        }
    }
}

// MARK: - ModelRow

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
                    Text("\(formatBytes(received)) / \(total > 0 ? formatBytes(total) : model.modelSizeLabel)")
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
            Button { downloader.cancel(model) } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.red)
            }
            .buttonStyle(.borderless)

        } else if downloaded {
            HStack(spacing: 10) {
                Button(role: .destructive) { downloader.delete(model) } label: {
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
                Text(model.modelSizeLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("↓ Download") { downloader.download(model) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let gb = Double(bytes) / 1_073_741_824
        let mb = Double(bytes) / 1_048_576
        if gb >= 1 { return String(format: "%.1f GB", gb) }
        return String(format: "%.0f MB", mb)
    }
}
