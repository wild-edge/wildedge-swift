import XCTest
@testable import WildEdge

final class BuilderConfigurationTests: XCTestCase {
    func testResolvePersistQueueToDiskDefaultsToTrue() {
        XCTAssertTrue(
            WildEdge.Builder.resolvePersistQueueToDisk(
                environmentValue: nil,
                infoDictionaryValue: nil
            )
        )
    }

    func testResolvePersistQueueToDiskPrefersEnvironmentValue() {
        XCTAssertFalse(
            WildEdge.Builder.resolvePersistQueueToDisk(
                environmentValue: "false",
                infoDictionaryValue: true
            )
        )
    }

    func testResolvePersistQueueToDiskFallsBackToInfoDictionaryValue() {
        XCTAssertFalse(
            WildEdge.Builder.resolvePersistQueueToDisk(
                environmentValue: nil,
                infoDictionaryValue: false
            )
        )
    }

    func testResolvePersistQueueToDiskIgnoresInvalidEnvironmentValue() {
        XCTAssertFalse(
            WildEdge.Builder.resolvePersistQueueToDisk(
                environmentValue: "not-a-bool",
                infoDictionaryValue: false
            )
        )
    }

    func testEventQueueFileURLIsNilWhenPersistenceDisabled() {
        XCTAssertNil(WildEdge.Builder.eventQueueFileURL(persistQueueToDisk: false))
    }

    func testEventQueueFileURLUsesCachesDirectoryWhenPersistenceEnabled() throws {
        let url = try XCTUnwrap(WildEdge.Builder.eventQueueFileURL(persistQueueToDisk: true))

        XCTAssertEqual(url.lastPathComponent, "dev.wildedge.eventqueue.ndjson")
        XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent.lowercased(), "caches")
    }
}
