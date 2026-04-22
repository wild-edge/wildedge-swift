import XCTest
@testable import WildEdge

final class AutoInitTests: XCTestCase {

    override func tearDown() {
        // Restore shared to env-var state so tests don't bleed into each other.
        WildEdge.autoInit()
        super.tearDown()
    }

    // Proves +load fired before any test code ran.
    func testAutoInitFiredBeforeTestSuiteRan() {
        XCTAssertTrue(WildEdge.autoInitFired)
    }

    // Without WILDEDGE_DSN the auto-created shared client must be noop.
    func testSharedIsNoopWhenDsnAbsent() throws {
        try XCTSkipIf(
            ProcessInfo.processInfo.environment["WILDEDGE_DSN"] != nil,
            "WILDEDGE_DSN is set — shared will be an active client"
        )
        XCTAssertTrue(WildEdge.shared is NoopWildEdgeClient)
    }

    // When WILDEDGE_DSN is set the auto-created shared client must be active.
    func testSharedIsActiveWhenDsnPresent() throws {
        try XCTSkipIf(
            ProcessInfo.processInfo.environment["WILDEDGE_DSN"] == nil,
            "WILDEDGE_DSN not set"
        )
        XCTAssertTrue(WildEdge.shared is WildEdge)
    }

    // Explicit initialize() must update shared and return the same instance.
    func testExplicitInitializeUpdatesShared() {
        let client = WildEdge.initialize { $0.dsn = "https://test-secret@ingest.wildedge.dev" }
        defer { client.close() }

        XCTAssertTrue(WildEdge.shared is WildEdge)
        XCTAssertTrue(WildEdge.shared === client)
    }
}
