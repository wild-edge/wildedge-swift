import XCTest
@testable import WildEdge

final class DsnParserTests: XCTestCase {
    func testParseDsnExtractsSecretAndHost() throws {
        let dsn = try configuredDsn()
        let parsed = try WildEdge.Builder.parseDsn(dsn)

        let components = try XCTUnwrap(URLComponents(string: dsn))
        let expectedSecret = try XCTUnwrap(components.user)
        let scheme = try XCTUnwrap(components.scheme)
        let host = try XCTUnwrap(components.host)
        var expectedHost = "\(scheme)://\(host)"
        if let port = components.port {
            expectedHost += ":\(port)"
        }

        XCTAssertEqual(parsed.secret, expectedSecret)
        XCTAssertEqual(parsed.host, expectedHost)
    }

    func testParseDsnKeepsPortWhenPresent() throws {
        let secret = extractSecret(from: try configuredDsn())
        let parsed = try WildEdge.Builder.parseDsn("https://\(secret)@localhost:8443/key")
        XCTAssertEqual(parsed.secret, secret)
        XCTAssertEqual(parsed.host, "https://localhost:8443")
    }

    func testParseDsnThrowsMissingSecret() {
        XCTAssertThrowsError(try WildEdge.Builder.parseDsn("https://ingest.wildedge.dev/key")) { error in
            guard let parseError = error as? WildEdge.Builder.ParseError else {
                return XCTFail("Unexpected error type: \(error)")
            }
            XCTAssertEqual(parseError, .missingSecret)
        }
    }

    func testParseDsnThrowsInvalidDsn() {
        XCTAssertThrowsError(try WildEdge.Builder.parseDsn("not-a-dsn")) { error in
            guard let parseError = error as? WildEdge.Builder.ParseError else {
                return XCTFail("Unexpected error type: \(error)")
            }
            XCTAssertEqual(parseError, .invalidDsn)
        }
    }

    private func configuredDsn() throws -> String {
        try XCTUnwrap(
            ProcessInfo.processInfo.environment["WILDEDGE_DSN"],
            "WILDEDGE_DSN must be set for DSN parser tests"
        )
    }

    private func extractSecret(from dsn: String) -> String {
        guard
            let components = URLComponents(string: dsn),
            let secret = components.user,
            !secret.isEmpty
        else {
            return "test-secret"
        }
        return secret
    }
}
