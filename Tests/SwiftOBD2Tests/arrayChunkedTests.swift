//
//  arrayChunkedTests.swift
//
//  Covers Array.chunked(into:), added so requestPIDs can split a long PID
//  list into requests a vehicle will actually answer instead of sending
//  every PID as one oversized mode-01 query (see requestPIDs in
//  obd2service.swift for why: SAE J1979's 6-PID-per-request cap, and ECUs
//  that answer "NO DATA" to the whole query once it's exceeded).
//

@testable import SwiftOBD2
import XCTest

final class arrayChunkedTests: XCTestCase {
    func testSplitsEvenlyDivisibleArray() {
        let chunks = Array(1...6).chunked(into: 3)
        XCTAssertEqual(chunks, [[1, 2, 3], [4, 5, 6]])
    }

    func testLastChunkIsShorterWhenNotEvenlyDivisible() {
        // Mirrors the motivating case: 10 PIDs, max 6 per request.
        let chunks = Array(1...10).chunked(into: 6)
        XCTAssertEqual(chunks, [[1, 2, 3, 4, 5, 6], [7, 8, 9, 10]])
    }

    func testArrayShorterThanChunkSizeYieldsOneChunk() {
        let chunks = [1, 2].chunked(into: 6)
        XCTAssertEqual(chunks, [[1, 2]])
    }

    func testEmptyArrayYieldsNoChunks() {
        let chunks = [Int]().chunked(into: 6)
        XCTAssertTrue(chunks.isEmpty)
    }

    func testExactMultipleOfChunkSizeHasNoTrailingEmptyChunk() {
        let chunks = Array(1...12).chunked(into: 6)
        XCTAssertEqual(chunks, [[1, 2, 3, 4, 5, 6], [7, 8, 9, 10, 11, 12]])
    }

    /// size <= 0 is a degenerate input a caller should never actually pass;
    /// this only guards against it looping forever or crashing.
    func testNonPositiveSizeReturnsWholeArrayAsOneChunk() {
        let chunks = [1, 2, 3].chunked(into: 0)
        XCTAssertEqual(chunks, [[1, 2, 3]])
    }
}
