import XCTest
@testable import WildEdge

final class InferQuantizationTests: XCTestCase {

    // MARK: - existing patterns

    func testInt8InNameReturnsInt8() {
        XCTAssertEqual(inferQuantization(from: "model_int8.tflite"), "int8")
    }

    func testInt4InNameReturnsInt4() {
        XCTAssertEqual(inferQuantization(from: "model_int4.tflite"), "int4")
    }

    func testFp16InNameReturnsF16() {
        XCTAssertEqual(inferQuantization(from: "model_fp16.tflite"), "f16")
    }

    func testFloat16InNameReturnsF16() {
        XCTAssertEqual(inferQuantization(from: "model_float16.tflite"), "f16")
    }

    func testFp32InNameReturnsF32() {
        XCTAssertEqual(inferQuantization(from: "model_fp32.tflite"), "f32")
    }

    func testFloat32InNameReturnsF32() {
        XCTAssertEqual(inferQuantization(from: "model_float32.tflite"), "f32")
    }

    // MARK: - _qN / _fN patterns

    func testQ8SegmentReturnsInt8() {
        XCTAssertEqual(inferQuantization(from: "model_seq128_q8_ekv1280.task"), "int8")
    }

    func testQ4SegmentReturnsInt4() {
        XCTAssertEqual(inferQuantization(from: "model_seq128_q4_ekv1280.task"), "int4")
    }

    func testF16SegmentReturnsF16() {
        XCTAssertEqual(inferQuantization(from: "model_seq128_f16_ekv1280.task"), "f16")
    }

    func testF32SegmentReturnsF32() {
        XCTAssertEqual(inferQuantization(from: "model_seq128_f32_ekv1280.task"), "f32")
    }

    // MARK: - real-world LiteRT LM filenames

    func testQwen25Q8TaskFileReturnsInt8() {
        XCTAssertEqual(
            inferQuantization(from: "Qwen2.5-0.5B-Instruct_multi-prefill-seq_q8_ekv1280.task"),
            "int8"
        )
    }

    func testGemma3Int4TaskFileReturnsInt4() {
        XCTAssertEqual(inferQuantization(from: "gemma3-1b-it-int4.task"), "int4")
    }

    func testGemma3Q4TaskFileReturnsInt4() {
        XCTAssertEqual(
            inferQuantization(from: "Gemma3-1B-IT_multi-prefill-seq_q4_block128_ekv1280.task"),
            "int4"
        )
    }

    // MARK: - case insensitivity

    func testUppercaseInt8IsRecognised() {
        XCTAssertEqual(inferQuantization(from: "Model_INT8.tflite"), "int8")
    }

    func testUppercaseQ8IsRecognised() {
        XCTAssertEqual(inferQuantization(from: "Model_Q8_Weights.task"), "int8")
    }

    // MARK: - no match

    func testUnknownQuantizationReturnsNil() {
        XCTAssertNil(inferQuantization(from: "mobilenet_v1_224.tflite"))
    }

    func testEmptyNameReturnsNil() {
        XCTAssertNil(inferQuantization(from: ".tflite"))
    }
}
