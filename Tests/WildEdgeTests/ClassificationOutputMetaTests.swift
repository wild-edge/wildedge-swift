import XCTest
@testable import WildEdge

final class ClassificationOutputMetaTests: XCTestCase {

    func testReturnsNilWhenNumClassesIsZero() {
        let output: [Any] = [[Float](repeating: 0.5, count: 3)]
        XCTAssertNil(classificationOutputMeta(output: output, numClasses: 0))
    }

    func testReturnsNilForUnrecognizedOutputType() {
        let output: [Any] = [[Int32](repeating: 0, count: 3)]
        XCTAssertNil(classificationOutputMeta(output: output, numClasses: 3))
    }

    func testReturnsNilForEmptyArray() {
        let output: [Any] = []
        XCTAssertNil(classificationOutputMeta(output: output, numClasses: 3))
    }

    func testReturnsNilWhenProbsSizeDoesNotMatchNumClasses() {
        let output: [Any] = [[Float](repeating: 1, count: 5)]
        XCTAssertNil(classificationOutputMeta(output: output, numClasses: 10))
    }

    func testFloatOutputTopClassIsArgmax() {
        var logits = [Float](repeating: 0, count: 5)
        logits[2] = 10
        let meta = classificationOutputMeta(output: [logits], numClasses: 5)
        XCTAssertEqual(meta?.topK?.first?.label, "2")
    }

    func testByteOutputTopClassIsArgmax() {
        var bytes = [UInt8](repeating: 0, count: 5)
        bytes[3] = 200
        let meta = classificationOutputMeta(output: [bytes], numClasses: 5)
        XCTAssertEqual(meta?.topK?.first?.label, "3")
    }

    func testUsesLabelNamesWhenProvided() {
        let labels = ["cat", "dog", "bird"]
        var logits = [Float](repeating: 0, count: 3)
        logits[1] = 5
        let meta = classificationOutputMeta(output: [logits], numClasses: 3, labels: labels)
        XCTAssertEqual(meta?.topK?.first?.label, "dog")
    }

    func testFallsBackToNumericIndexWhenLabelsNil() {
        var logits = [Float](repeating: 0, count: 3)
        logits[1] = 5
        let meta = classificationOutputMeta(output: [logits], numClasses: 3)
        XCTAssertEqual(meta?.topK?.first?.label, "1")
    }

    func testTopKCappedAtFive() {
        let logits = (0..<10).map { Float($0) }
        let meta = classificationOutputMeta(output: [logits], numClasses: 10)
        XCTAssertEqual(meta?.topK?.count, 5)
    }

    func testTopKIsAllClassesWhenFewerThanFive() {
        let logits = (0..<3).map { Float($0) }
        let meta = classificationOutputMeta(output: [logits], numClasses: 3)
        XCTAssertEqual(meta?.topK?.count, 3)
    }

    func testTopKIsDescendingByConfidence() {
        let logits = (0..<5).map { Float($0) }
        let meta = classificationOutputMeta(output: [logits], numClasses: 5)
        let confidences = meta?.topK?.compactMap { $0.confidence } ?? []
        for (a, b) in zip(confidences, confidences.dropFirst()) {
            XCTAssertGreaterThanOrEqual(a, b)
        }
    }

    func testNumPredictionsMatchesNumClasses() {
        let logits = [Float](repeating: 1, count: 7)
        let meta = classificationOutputMeta(output: [logits], numClasses: 7)
        XCTAssertEqual(meta?.numPredictions, 7)
    }

    func testAvgConfidenceMatchesTopOnePrediction() {
        var logits = [Float](repeating: 0, count: 4)
        logits[0] = 10
        let meta = classificationOutputMeta(output: [logits], numClasses: 4)
        XCTAssertEqual(meta?.avgConfidence, meta?.topK?.first?.confidence)
    }

    func testConfidenceIsInZeroOneRange() {
        let bytes = (0..<5).map { UInt8($0 * 50) }
        let meta = classificationOutputMeta(output: [bytes], numClasses: 5)
        for pred in meta?.topK ?? [] {
            let confidence = pred.confidence ?? -1
            XCTAssertGreaterThanOrEqual(confidence, 0)
            XCTAssertLessThanOrEqual(confidence, 1)
        }
    }

    func testToMapIncludesClassificationTask() {
        let logits = (0..<3).map { Float($0) }
        let meta = classificationOutputMeta(output: [logits], numClasses: 3)
        XCTAssertEqual(meta?.toMap()["task"] as? String, "classification")
    }
}
