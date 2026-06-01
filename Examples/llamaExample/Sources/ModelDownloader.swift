import Foundation
import WildEdge

enum ModelSource: String {
    case huggingFace = "huggingface"
    case liquidAI = "liquid"
}

struct CatalogModel: Identifiable {
    let id: String
    let name: String
    let subtitle: String
    let sizeLabel: String
    let downloadURL: URL
    let filename: String
    var source: ModelSource = .huggingFace
}

let liquidAICatalog: [CatalogModel] = [
    CatalogModel(
        id: "lfm25-audio-15b-q40",
        name: "LFM2.5-Audio-1.5B",
        subtitle: "LiquidAI/LFM2.5-Audio-1.5B-GGUF · Q4_0",
        sizeLabel: "663 MB",
        downloadURL: URL(string: "https://huggingface.co/LiquidAI/LFM2.5-Audio-1.5B-GGUF/resolve/main/LFM2.5-Audio-1.5B-Q4_0.gguf")!,
        filename: "LFM2.5-Audio-1.5B-Q4_0.gguf",
        source: .liquidAI
    ),
    CatalogModel(
        id: "lfm2-350m-q4km",
        name: "LFM2-350M Instruct",
        subtitle: "LiquidAI/LFM2-350M-GGUF · Q4_K_M",
        sizeLabel: "229 MB",
        downloadURL: URL(string: "https://huggingface.co/LiquidAI/LFM2-350M-GGUF/resolve/main/LFM2-350M-Q4_K_M.gguf")!,
        filename: "LFM2-350M-Q4_K_M.gguf",
        source: .liquidAI
    ),
    CatalogModel(
        id: "lfm2-12b-q4km",
        name: "LFM2-1.2B Instruct",
        subtitle: "LiquidAI/LFM2-1.2B-GGUF · Q4_K_M",
        sizeLabel: "697 MB",
        downloadURL: URL(string: "https://huggingface.co/LiquidAI/LFM2-1.2B-GGUF/resolve/main/LFM2-1.2B-Q4_K_M.gguf")!,
        filename: "LFM2-1.2B-Q4_K_M.gguf",
        source: .liquidAI
    ),
]

let huggingFaceCatalog: [CatalogModel] = [
    CatalogModel(
        id: "qwen25-05b-q4km",
        name: "Qwen2.5 0.5B Instruct",
        subtitle: "Qwen/Qwen2.5-0.5B-Instruct-GGUF · Q4_K_M",
        sizeLabel: "491 MB",
        downloadURL: URL(string: "https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct-GGUF/resolve/main/qwen2.5-0.5b-instruct-q4_k_m.gguf")!,
        filename: "qwen2.5-0.5b-instruct-q4_k_m.gguf"
    ),
    CatalogModel(
        id: "tinyllama-11b-q4km",
        name: "TinyLlama 1.1B Chat",
        subtitle: "TheBloke/TinyLlama-1.1B-Chat-v1.0-GGUF · Q4_K_M",
        sizeLabel: "670 MB",
        downloadURL: URL(string: "https://huggingface.co/TheBloke/TinyLlama-1.1B-Chat-v1.0-GGUF/resolve/main/tinyllama-1.1b-chat-v1.0.Q4_K_M.gguf")!,
        filename: "tinyllama-1.1b-chat-v1.0.Q4_K_M.gguf"
    ),
]

let modelCatalog: [CatalogModel] = liquidAICatalog + huggingFaceCatalog

// MARK: -

@MainActor
final class ModelDownloader: NSObject, ObservableObject {

    enum DownloadState {
        case downloading(progress: Double, received: Int64, total: Int64)
        case done
        case failed(String)
    }

    @Published private(set) var states: [String: DownloadState] = [:]

    private var tasks: [String: URLSessionDownloadTask] = [:]
    private var downloadStartTimes: [String: Date] = [:]

    private lazy var session: URLSession = {
        URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    }()

    static let documentsURL: URL =
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]

    func localURL(for model: CatalogModel) -> URL {
        Self.documentsURL.appendingPathComponent(model.filename)
    }

    func isDownloaded(_ model: CatalogModel) -> Bool {
        FileManager.default.fileExists(atPath: localURL(for: model).path)
    }

    func currentState(for model: CatalogModel) -> DownloadState? {
        states[model.id]
    }

    func download(_ model: CatalogModel) {
        guard tasks[model.id] == nil else { return }
        states[model.id] = .downloading(progress: 0, received: 0, total: 0)
        downloadStartTimes[model.id] = Date()
        let task = session.downloadTask(with: model.downloadURL)
        task.taskDescription = model.id
        tasks[model.id] = task
        task.resume()
    }

    func cancel(_ model: CatalogModel) {
        tasks[model.id]?.cancel()
        tasks.removeValue(forKey: model.id)
        states.removeValue(forKey: model.id)
        downloadStartTimes.removeValue(forKey: model.id)
    }

    func delete(_ model: CatalogModel) {
        try? FileManager.default.removeItem(at: localURL(for: model))
        states.removeValue(forKey: model.id)
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
        guard let id = downloadTask.taskDescription else { return }
        let progress = totalBytesExpectedToWrite > 0
            ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            : 0
        Task { @MainActor [weak self] in
            self?.states[id] = .downloading(
                progress: progress,
                received: totalBytesWritten,
                total: totalBytesExpectedToWrite
            )
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let id = downloadTask.taskDescription,
              let model = modelCatalog.first(where: { $0.id == id })
        else { return }

        let dest = Self.documentsURL.appendingPathComponent(model.filename)
        do {
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: location, to: dest)
            Task { @MainActor [weak self] in
                guard let self else { return }
                let startTime = self.downloadStartTimes.removeValue(forKey: id)
                let durationMs = startTime.map { Int(Date().timeIntervalSince($0) * 1000) } ?? 0
                var fileSizeBytes: Int64 = 0
                if case .downloading(_, let received, let total) = self.states[id] {
                    fileSizeBytes = total > 0 ? total : received
                }
                let handle = WildEdge.shared.registerModel(
                    modelId: model.id,
                    info: ModelInfo(
                        modelName: model.name,
                        modelSource: model.downloadURL.absoluteString,
                        modelFormat: "gguf"
                    )
                )
                handle.trackDownload(
                    sourceUrl: model.downloadURL.absoluteString,
                    sourceType: model.source.rawValue,
                    fileSizeBytes: fileSizeBytes,
                    downloadedBytes: fileSizeBytes,
                    durationMs: durationMs,
                    success: true
                )
                self.tasks.removeValue(forKey: id)
                self.states[id] = .done
            }
        } catch {
            Task { @MainActor [weak self] in
                self?.downloadStartTimes.removeValue(forKey: id)
                self?.tasks.removeValue(forKey: id)
                self?.states[id] = .failed(error.localizedDescription)
            }
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let error,
              let id = task.taskDescription,
              (error as NSError).code != NSURLErrorCancelled
        else { return }
        Task { @MainActor [weak self] in
            self?.downloadStartTimes.removeValue(forKey: id)
            self?.tasks.removeValue(forKey: id)
            self?.states[id] = .failed(error.localizedDescription)
        }
    }
}
