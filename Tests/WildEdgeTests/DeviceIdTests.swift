import XCTest
@testable import WildEdge

final class DeviceIdTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "DeviceIdTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func testInstallIdIsStableAcrossCalls() {
        let first = DeviceInfo.installId(in: defaults)
        let second = DeviceInfo.installId(in: defaults)

        XCTAssertFalse(first.isEmpty)
        XCTAssertEqual(first, second)
    }

    func testInstallIdSurvivesANewDefaultsInstance() {
        let first = DeviceInfo.installId(in: defaults)
        let reopened = UserDefaults(suiteName: suiteName)!

        XCTAssertEqual(DeviceInfo.installId(in: reopened), first)
    }

    func testFreshInstallsGetDifferentIds() {
        let otherSuite = "DeviceIdTests-\(UUID().uuidString)"
        let other = UserDefaults(suiteName: otherSuite)!
        defer { other.removePersistentDomain(forName: otherSuite) }

        XCTAssertNotEqual(DeviceInfo.installId(in: defaults), DeviceInfo.installId(in: other))
    }

    func testDetectReturnsTheSameDeviceIdEachLaunch() {
        let first = DeviceInfo.detect(projectSecret: "secret").deviceId
        let second = DeviceInfo.detect(projectSecret: "secret").deviceId

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.count, 64, "HMAC-SHA256 hex")
    }
}
