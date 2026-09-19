//
//  mockManagerTests.swift
//
//  Regression coverage for two bugs in OBDCommand.mockResponse(forCommand:)
//  that silently broke demo/simulator polling:
//    - .fuelLevel passed a Double to a %02X specifier, which crashes
//      String(format:) and drops the whole batch response.
//    - .controlModuleVoltage had no case at all and fell through to
//      `default: return nil`, so the PID always came back "No Data".
//
//  See /swiftobd2-bug-report.md in DriveOps for the original report.
//

@testable import SwiftOBD2
import XCTest

final class mockManagerTests: XCTestCase {
    /// %02X expects an integer; formatting a Double for it throws inside
    /// String(format:), so this only regresses if the call is fed a Double
    /// again. Repeated because the underlying value is randomised.
    func testFuelLevelDoesNotCrashAndReturnsWellFormedResponse() {
        for _ in 0..<50 {
            guard let response = OBDCommand.mockResponse(forCommand: "012F") else {
                XCTFail("expected a mock response for fuelLevel")
                continue
            }
            XCTAssertNotEqual(response, "Invalid command")

            let parts = response.split(separator: " ")
            XCTAssertEqual(parts.count, 2, "expected \"2F <byte>\", got: \(response)")
            XCTAssertEqual(parts.first, "2F")

            // The payload byte must be valid two-digit hex (0x00...0xFF) —
            // the original bug produced a thrown-away/garbled value here.
            let byteString = String(parts[1])
            XCTAssertEqual(byteString.count, 2)
            let byteValue = UInt8(byteString, radix: 16)
            XCTAssertNotNil(byteValue, "payload byte was not valid hex: \(byteString)")
        }
    }

    /// controlModuleVoltage previously fell through to `default: return nil`,
    /// which OBDService/sendCommand surfaces as "No Data" for every poll.
    func testControlModuleVoltageReturnsAResponse() {
        for _ in 0..<50 {
            guard let response = OBDCommand.mockResponse(forCommand: "0142") else {
                XCTFail("expected a mock response for controlModuleVoltage")
                continue
            }
            XCTAssertNotEqual(response, "Invalid command")
            XCTAssertNotEqual(response, "No Data")

            let parts = response.split(separator: " ")
            XCTAssertEqual(parts.count, 3, "expected \"42 <A> <B>\", got: \(response)")
            XCTAssertEqual(parts.first, "42")

            // Decode A*256+B millivolts back to volts and sanity-check it
            // falls in the plausible range the generator draws from.
            guard let a = UInt16(parts[1], radix: 16), let b = UInt16(parts[2], radix: 16) else {
                XCTFail("payload bytes were not valid hex: \(response)")
                continue
            }
            let volts = Double(a * 256 + b) / 1000.0
            XCTAssertGreaterThanOrEqual(volts, 13.5)
            XCTAssertLessThanOrEqual(volts, 14.5)
        }
    }
}
