import Foundation
import Network

typealias RemoteSDKConfig = [String: JSONValue]

enum JSONValue: Codable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            throw DecodingError.typeMismatch(
                JSONValue.self,
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Unsupported JSON value")
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()

        switch self {
        case .string(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }

    var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    var intValue: Int? {
        guard case .number(let value) = self else { return nil }
        return Int(value)
    }

    var boolValue: Bool? {
        guard case .bool(let value) = self else { return nil }
        return value
    }

    var objectValue: [String: JSONValue]? {
        guard case .object(let value) = self else { return nil }
        return value
    }
}

private struct RemoteSDKConfigResponse: Decodable {
    let config: RemoteSDKConfig

    init(from decoder: Decoder) throws {
        let rawObject = try RemoteSDKConfig(from: decoder)
        if let wrappedConfig = rawObject["config"]?.objectValue {
            config = wrappedConfig
            return
        }

        config = rawObject
    }
}

private actor RemoteSDKConfigRefreshGate {
    private var isRefreshing = false

    func begin() -> Bool {
        guard !isRefreshing else { return false }
        isRefreshing = true
        return true
    }

    func end() {
        isRefreshing = false
    }
}

final class RemoteSDKConfigStore {
    static let shared = RemoteSDKConfigStore()

    private let lock = NSLock()
    private var storedConfig: RemoteSDKConfig?
    private var storedAt: Date?

    var current: RemoteSDKConfig? {
        lock.lock()
        defer { lock.unlock() }
        return storedConfig
    }

    var lastUpdatedAt: Date? {
        lock.lock()
        defer { lock.unlock() }
        return storedAt
    }

    func replace(with config: RemoteSDKConfig) {
        lock.lock()
        storedConfig = config
        storedAt = Date()
        lock.unlock()
    }
}

final class RemoteSDKConfigRefresher {
    enum ConfigError: LocalizedError {
        case invalidDsn
        case missingProjectId
        case invalidConfigURL
        case badStatus(Int)

        var errorDescription: String? {
            switch self {
            case .invalidDsn:
                return "Invalid WILDEDGE_DSN"
            case .missingProjectId:
                return "WILDEDGE_DSN must include the project id as the path"
            case .invalidConfigURL:
                return "Could not build remote SDK config URL"
            case .badStatus(let statusCode):
                return "Remote SDK config request failed with HTTP \(statusCode)"
            }
        }
    }

    let endpointURL: URL

    private var refreshEvery: TimeInterval
    private let store: RemoteSDKConfigStore
    private let session: URLSession
    private let monitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "dev.wildedge.sample.remote-sdk-config")
    private var refreshTask: Task<Void, Never>?
    private var onFetchStarted: (() -> Void)?
    private var onChange: ((Result<RemoteSDKConfig, Swift.Error>) -> Void)?
    private let refreshGate = RemoteSDKConfigRefreshGate()

    init(
        dsn: String,
        refreshEvery: TimeInterval,
        store: RemoteSDKConfigStore = .shared,
        session: URLSession = .shared
    ) throws {
        self.endpointURL = try Self.makeConfigURL(fromDSN: dsn)
        self.refreshEvery = refreshEvery
        self.store = store
        self.session = session
    }

    func start(
        onFetchStarted: (() -> Void)? = nil,
        onChange: @escaping (Result<RemoteSDKConfig, Swift.Error>) -> Void,
        fetchImmediately: Bool = true
    ) {
        self.onFetchStarted = onFetchStarted
        self.onChange = onChange
        monitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            Task { await self?.refresh() }
        }
        monitor.start(queue: monitorQueue)
        startRefreshLoop()
        if fetchImmediately {
            Task { await refresh() }
        }
    }

    func stop() {
        monitor.cancel()
        refreshTask?.cancel()
        refreshTask = nil
    }

    func updateRefreshEvery(_ refreshEvery: TimeInterval) {
        guard self.refreshEvery != refreshEvery else { return }
        self.refreshEvery = refreshEvery
        startRefreshLoop()
    }

    deinit {
        stop()
    }

    @discardableResult
    func refresh() async -> RemoteSDKConfig? {
        guard await refreshGate.begin() else { return nil }

        do {
            onFetchStarted?()
            let request = URLRequest(url: endpointURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
            let (data, response) = try await session.data(for: request)
            if let httpResponse = response as? HTTPURLResponse, !(200..<300).contains(httpResponse.statusCode) {
                throw ConfigError.badStatus(httpResponse.statusCode)
            }

            let decoder = JSONDecoder()
            let config = try decoder.decode(RemoteSDKConfigResponse.self, from: data).config
            store.replace(with: config)
            onChange?(.success(config))
            await refreshGate.end()
            return config
        } catch {
            onChange?(.failure(error))
            await refreshGate.end()
            return nil
        }
    }

    private func startRefreshLoop() {
        refreshTask?.cancel()
        guard refreshEvery > 0 else { return }

        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let delay = UInt64(max(self.refreshEvery, 1) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: delay)
                guard !Task.isCancelled else { return }
                await self.refresh()
            }
        }
    }

    private static func makeConfigURL(fromDSN dsn: String) throws -> URL {
        guard
            var components = URLComponents(string: dsn),
            let scheme = components.scheme,
            let host = components.host,
            !scheme.isEmpty,
            !host.isEmpty
        else {
            throw ConfigError.invalidDsn
        }

        let projectId = components.path
            .split(separator: "/")
            .last
            .map(String.init)

        guard let projectId, !projectId.isEmpty else {
            throw ConfigError.missingProjectId
        }

        components.user = nil
        components.password = nil
        components.host = appHost(fromIngestHost: host)
        components.path = "/api/sdk-configs/\(projectId)"
        components.query = nil
        components.fragment = nil

        guard let url = components.url else {
            throw ConfigError.invalidConfigURL
        }
        return url
    }

    private static func appHost(fromIngestHost host: String) -> String {
        if host == "ingest.wildedge.dev" {
            return "app.wildedge.dev"
        }

        if host.hasPrefix("ingest.") {
            return "app." + String(host.dropFirst("ingest.".count))
        }

        return host
    }
}
