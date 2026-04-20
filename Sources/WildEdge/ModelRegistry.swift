import Foundation

internal final class ModelRegistry {
    private let lock = NSLock()
    private var models: [String: [String: Any]] = [:]

    func register(modelId: String, info: ModelInfo) {
        lock.lock()
        defer { lock.unlock() }
        models[modelId] = info.toMap()
    }

    func snapshot() -> [String: [String: Any]] {
        lock.lock()
        defer { lock.unlock() }
        return models
    }
}
