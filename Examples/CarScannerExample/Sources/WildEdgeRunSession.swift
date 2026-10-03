import UIKit
import WildEdge

/// Gives WildEdge one run per app session, so everything the app does between
/// opening and putting it away (loads, scans, errors, feedback) lands in a
/// single run.
///
/// A session ends once the app has spent more than `idleTimeout` in the
/// background; coming back after that starts a new run. The run id and the
/// moment the app went to the background are stored, so a relaunch shortly
/// after the system killed the app continues the same run.
final class WildEdgeRunSession {
    static let idleTimeout: TimeInterval = 2 * 60

    private enum Key {
        static let runId = "wildedge.session.runId"
        static let backgroundedAt = "wildedge.session.backgroundedAt"
    }

    private let client: WildEdgeClient
    private let defaults: UserDefaults
    private var observers: [NSObjectProtocol] = []

    init(client: WildEdgeClient = WildEdge.shared, defaults: UserDefaults = .standard) {
        self.client = client
        self.defaults = defaults

        resume()

        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            self?.defaults.set(Date(), forKey: Key.backgroundedAt)
        })
        observers.append(center.addObserver(forName: UIApplication.willEnterForegroundNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            self?.resume()
        })
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    /// Keeps the stored run unless the app was away longer than
    /// `idleTimeout`, in which case a new one starts.
    private func resume() {
        let backgroundedAt = defaults.object(forKey: Key.backgroundedAt) as? Date
        defaults.removeObject(forKey: Key.backgroundedAt)

        let expired = backgroundedAt.map { Date().timeIntervalSince($0) > Self.idleTimeout } ?? false
        if !expired, let stored = defaults.string(forKey: Key.runId) {
            client.defaultRunId = stored
            return
        }

        let runId = UUID().uuidString
        defaults.set(runId, forKey: Key.runId)
        client.defaultRunId = runId
    }
}
