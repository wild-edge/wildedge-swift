import XCTest
@testable import WildEdge

final class DsnParserTests: XCTestCase {
    func testParseDsnExtractsSecretAndHost() throws {
        let parsed = try WildEdge.Builder.parseDsn("https://test-secret@ingest.wildedge.dev/test-key")
        XCTAssertEqual(parsed.secret, "test-secret")
        XCTAssertEqual(parsed.host, "https://ingest.wildedge.dev")
    }

    func testParseDsnKeepsPortWhenPresent() throws {
        let parsed = try WildEdge.Builder.parseDsn("https://test-secret@localhost:8443/key")
        XCTAssertEqual(parsed.secret, "test-secret")
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
