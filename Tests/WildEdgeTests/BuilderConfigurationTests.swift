import XCTest
@testable import WildEdge

final class BuilderConfigurationTests: XCTestCase {
    func testEventQueueFileURLPointsToAppSupportDirectory() {
        let url = WildEdge.Builder.eventQueueFileURL()
        XCTAssertEqual(url.lastPathComponent, "eventqueue.bin")
        XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, "wildedge")
        XCTAssertEqual(url.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent.lowercased(), "application support")
    }
}
