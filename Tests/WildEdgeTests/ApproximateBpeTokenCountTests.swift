import XCTest
@testable import WildEdge

final class ApproximateBpeTokenCountTests: XCTestCase {

    func testEmptyInputReturnsOne() {
        XCTAssertEqual(approximateBpeTokenCount(charCount: 0), 1)
    }

    func testExactlyFourCharsIsOneToken() {
        XCTAssertEqual(approximateBpeTokenCount(charCount: 4), 1)
    }

    func testExactlyEightCharsIsTwoTokens() {
        XCTAssertEqual(approximateBpeTokenCount(charCount: 8), 2)
    }

    func testRoundsHalfUp() {
        // 6 chars / 4.0 = 1.5, rounds to 2
        XCTAssertEqual(approximateBpeTokenCount(charCount: 6), 2)
    }

    func testTypicalEnglishSentence() {
        // "The quick brown fox" = 19 chars -> 19/4 = 4.75 -> 5
        XCTAssertEqual(approximateBpeTokenCount(charCount: 19), 5)
    }

    func testLargerOutputScalesLinearly() {
        // 400 chars -> 100 tokens
        XCTAssertEqual(approximateBpeTokenCount(charCount: 400), 100)
    }

    func testSingleCharReturnsOne() {
        XCTAssertEqual(approximateBpeTokenCount(charCount: 1), 1)
    }

    func testThreeCharsRoundsToOne() {
        // 3 / 4.0 = 0.75 -> rounds to 1, minimum of 1 ensures at least 1
        XCTAssertGreaterThanOrEqual(approximateBpeTokenCount(charCount: 3), 1)
    }
}
