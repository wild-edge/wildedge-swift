import Foundation
import WildEdge

struct CatalogModel: Identifiable {
    let id: String
    let name: String
    let subtitle: String
    let modelSizeLabel: String
    let modelURL: URL
    let modelFilename: String
    let tokenizerURL: URL
    let tokenizerFilename: String
}

// Both models use the same Llama 3.2 tokenizer — stored once as "llama32-tokenizer.model".
let modelCatalog: [CatalogModel] = [
    CatalogModel(
        id: "llama32-1b-qlora-int4",
        name: "Llama 3.2 1B Instruct Q4",
        subtitle: "executorch-community · QLORA INT4 EO8",
        modelSizeLabel: "~1.1 GB",
        modelURL: URL(string: "https://huggingface.co/executorch-community/Llama-3.2-1B-Instruct-QLORA_INT4_EO8-ET/resolve/main/Llama-3.2-1B-Instruct-QLORA_INT4_EO8.pte")!,
        modelFilename: "Llama-3.2-1B-Instruct-QLORA_INT4_EO8.pte",
        tokenizerURL: URL(string: "https://huggingface.co/unsloth/Llama-3.2-1B-Instruct/resolve/main/tokenizer.json")!,
        tokenizerFilename: "llama32-tokenizer.json"
    ),
    CatalogModel(
        id: "llama32-1b-instruct",
        name: "Llama 3.2 1B Instruct",
        subtitle: "executorch-community · BF16",
        modelSizeLabel: "~2.5 GB",
        modelURL: URL(string: "https://huggingface.co/executorch-community/Llama-3.2-1B-Instruct-ET/resolve/main/Llama-3.2-1B-Instruct.pte")!,
        modelFilename: "Llama-3.2-1B-Instruct.pte",
        tokenizerURL: URL(string: "https://huggingface.co/unsloth/Llama-3.2-1B-Instruct/resolve/main/tokenizer.json")!,
        tokenizerFilename: "llama32-tokenizer.json"
    ),
]

// MARK: -

@MainActor
final class ModelDownloader: NSObject, ObservableObject {

    enum DownloadState {
        case downloading(progress: Double, received: Int64, total: Int64)
        case done
        case failed(String)
    }

    @Published private(set) var states: [String: DownloadState] = [:]

    // "modelId|model" or "modelId|tokenizer" → task
    private var tasks: [String: URLSessionDownloadTask] = [:]
    private var startTimes: [String: Date] = [:]

    // Per-file byte tracking, keyed by modelId
    private var mRecv:  [String: Int64] = [:]
    private var mTotal: [String: Int64] = [:]
    private var tRecv:  [String: Int64] = [:]
    private var tTotal: [String: Int64] = [:]

    // Which files have finished for each modelId
    private var mDone: Set<String> = []
    private var tDone: Set<String> = []

    private lazy var session: URLSession = {
        URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    }()

    static let documentsURL: URL =
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]

    func modelLocalURL(for model: CatalogModel) -> URL {
        Self.documentsURL.appendingPathComponent(model.modelFilename)
    }

    func tokenizerLocalURL(for model: CatalogModel) -> URL {
        Self.documentsURL.appendingPathComponent(model.tokenizerFilename)
    }

    func isDownloaded(_ model: CatalogModel) -> Bool {
        FileManager.default.fileExists(atPath: modelLocalURL(for: model).path) &&
        FileManager.default.fileExists(atPath: tokenizerLocalURL(for: model).path)
    }

    func currentState(for model: CatalogModel) -> DownloadState? {
        states[model.id]
    }

    func download(_ model: CatalogModel) {
        guard tasks["\(model.id)|model"] == nil else { return }

        startTimes[model.id] = Date()
        states[model.id] = .downloading(progress: 0, received: 0, total: 0)
        mDone.remove(model.id)
        tDone.remove(model.id)

        let modelTask = session.downloadTask(with: model.modelURL)
        modelTask.taskDescription = "\(model.id)|model"
        tasks["\(model.id)|model"] = modelTask
        modelTask.resume()

        // Skip tokenizer download if the file is already on disk
        if FileManager.default.fileExists(atPath: tokenizerLocalURL(for: model).path) {
            tDone.insert(model.id)
        } else {
            let tokTask = session.downloadTask(with: model.tokenizerURL)
            tokTask.taskDescription = "\(model.id)|tokenizer"
            tasks["\(model.id)|tokenizer"] = tokTask
            tokTask.resume()
        }
    }

    func cancel(_ model: CatalogModel) {
        tasks["\(model.id)|model"]?.cancel()
        tasks["\(model.id)|tokenizer"]?.cancel()
        tasks.removeValue(forKey: "\(model.id)|model")
        tasks.removeValue(forKey: "\(model.id)|tokenizer")
        startTimes.removeValue(forKey: model.id)
        mRecv.removeValue(forKey: model.id)
        mTotal.removeValue(forKey: model.id)
        tRecv.removeValue(forKey: model.id)
        tTotal.removeValue(forKey: model.id)
        mDone.remove(model.id)
        tDone.remove(model.id)
        states.removeValue(forKey: model.id)
    }

    func delete(_ model: CatalogModel) {
        try? FileManager.default.removeItem(at: modelLocalURL(for: model))
        // Only delete tokenizer if no other downloaded model references the same file
        let sharedByOthers = modelCatalog.contains {
            $0.id != model.id &&
            $0.tokenizerFilename == model.tokenizerFilename &&
            isDownloaded($0)
        }
        if !sharedByOthers {
            try? FileManager.default.removeItem(at: tokenizerLocalURL(for: model))
        }
        states.removeValue(forKey: model.id)
    }

    // MARK: - Private

    private func updateState(for modelId: String) {
        let received = (mRecv[modelId] ?? 0) + (tRecv[modelId] ?? 0)
        let total    = (mTotal[modelId] ?? 0) + (tTotal[modelId] ?? 0)
        let progress = total > 0 ? Double(received) / Double(total) : 0
        states[modelId] = .downloading(progress: progress, received: received, total: total)
    }

    private func finishFile(_ modelId: String, isModel: Bool) {
        if isModel { mDone.insert(modelId) } else { tDone.insert(modelId) }
        guard mDone.contains(modelId), tDone.contains(modelId) else { return }

        tasks.removeValue(forKey: "\(modelId)|model")
        tasks.removeValue(forKey: "\(modelId)|tokenizer")

        let durationMs = startTimes.removeValue(forKey: modelId)
            .map { Int(Date().timeIntervalSince($0) * 1000) } ?? 0
        let fileSizeBytes = mTotal[modelId] ?? 0

        mRecv.removeValue(forKey: modelId)
        mTotal.removeValue(forKey: modelId)
        tRecv.removeValue(forKey: modelId)
        tTotal.removeValue(forKey: modelId)

        if let model = modelCatalog.first(where: { $0.id == modelId }) {
            let handle = WildEdge.shared.registerModel(
                modelId: modelId,
                info: ModelInfo(
                    modelName: model.name,
                    modelSource: model.modelURL.absoluteString,
                    modelFormat: "pte"
                )
            )
            handle.trackDownload(
                sourceUrl: model.modelURL.absoluteString,
                sourceType: "huggingface",
                fileSizeBytes: fileSizeBytes,
                downloadedBytes: fileSizeBytes,
                durationMs: durationMs,
                success: true
            )
        }

        states[modelId] = .done
    }
}

// MARK: - URLSessionDownloadDelegate

extension ModelDownloader: URLSessionDownloadDelegate {

    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData _: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard let desc = downloadTask.taskDescription else { return }
        let parts = desc.split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return }
        let (modelId, fileType) = (parts[0], parts[1])
        let isModel = fileType == "model"

        Task { @MainActor [weak self] in
            guard let self else { return }
            if isModel {
                self.mRecv[modelId]  = totalBytesWritten
                self.mTotal[modelId] = totalBytesExpectedToWrite
            } else {
                self.tRecv[modelId]  = totalBytesWritten
                self.tTotal[modelId] = totalBytesExpectedToWrite
            }
            self.updateState(for: modelId)
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let desc = downloadTask.taskDescription else { return }
        let parts = desc.split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.count == 2,
              let model = modelCatalog.first(where: { $0.id == parts[0] })
        else { return }

        let isModel = parts[1] == "model"
        let dest = isModel
            ? Self.documentsURL.appendingPathComponent(model.modelFilename)
            : Self.documentsURL.appendingPathComponent(model.tokenizerFilename)

        do {
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: location, to: dest)
            Task { @MainActor [weak self] in
                self?.finishFile(model.id, isModel: isModel)
            }
        } catch {
            Task { @MainActor [weak self] in
                self?.tasks.removeValue(forKey: desc)
                self?.states[model.id] = .failed(error.localizedDescription)
            }
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let error,
              let desc = task.taskDescription,
              (error as NSError).code != NSURLErrorCancelled
        else { return }
        let modelId = desc.split(separator: "|").first.map(String.init) ?? desc
        Task { @MainActor [weak self] in
            self?.tasks.removeValue(forKey: desc)
            self?.states[modelId] = .failed(error.localizedDescription)
        }
    }
}
