import XCTest
@testable import HostMemoryResidency

/// Every one of these inputs traps if the arithmetic is written the obvious
/// way. That is the point of the type, so it is the point of the suite.
final class ByteCountTests: XCTestCase {

    func testNegativeInitialiserClampsToZeroRatherThanTrapping() {
        XCTAssertEqual(ByteCount(rawValue: -1).rawValue, 0)
        XCTAssertEqual(ByteCount(bytes: Int.min).rawValue, 0)
    }

    func testAdditionSaturatesInsteadOfOverflowing() {
        let sum = ByteCount.max + ByteCount(megabytes: 1)
        XCTAssertEqual(sum, .max, "plain Int + would have trapped here")
    }

    func testSubtractionClampsAtZero() {
        let result = ByteCount(megabytes: 1) - ByteCount(megabytes: 4)
        XCTAssertEqual(result, .zero, "a process already over budget must be describable, not fatal")
    }

    func testMultiplicationSaturates() {
        XCTAssertEqual(ByteCount.max * 2, .max)
        XCTAssertEqual(ByteCount(megabytes: 1) * -5, .zero)
    }

    func testMegabyteInitialiserSaturatesRatherThanOverflowing() {
        // Int.max megabytes overflows a 64-bit Int by 20 bits.
        XCTAssertEqual(ByteCount(megabytes: Int.max), .max)
        XCTAssertEqual(ByteCount(kilobytes: Int.max), .max)
    }

    func testDoubleConversionHandlesEveryTrappingCase() {
        // Int(Double.nan) traps.
        XCTAssertEqual(ByteCount(approximately: Double.nan), .zero)
        // Int(Double.infinity) traps.
        XCTAssertEqual(ByteCount(approximately: .infinity), .max)
        XCTAssertEqual(ByteCount(approximately: -.infinity), .zero)
        // Int(1e30) traps.
        XCTAssertEqual(ByteCount(approximately: 1e30), .max)
        XCTAssertEqual(ByteCount(approximately: -12), .zero)
        XCTAssertEqual(ByteCount(approximately: 4096).rawValue, 4096)
    }

    func testDoubleConversionAtTheIntMaxBoundary() {
        // Double(Int.max) rounds up to exactly 2^63, which is one past the
        // representable range — the boundary the initialiser has to catch.
        XCTAssertEqual(ByteCount(approximately: Double(Int.max)), .max)
    }

    func testScaledDoesNotDivideByZero() {
        let value = ByteCount(megabytes: 100)
        XCTAssertEqual(value.scaled(numerator: 50, denominator: 0), .zero)
        XCTAssertEqual(value.scaled(numerator: -50, denominator: 100), .zero)
    }

    func testScaledIsAccurateAtLargeMagnitudes() {
        // Naive `value * numerator` overflows well before this.
        let huge = ByteCount(rawValue: Int.max / 2)
        let half = huge.scaled(numerator: 50, denominator: 100)
        // Allow one byte of integer-division slack.
        XCTAssertLessThanOrEqual(abs(half.rawValue - huge.rawValue / 2), 1)
    }

    func testPercentOfZeroBaseDoesNotDivideByZero() {
        XCTAssertEqual(ByteCount(megabytes: 1).percent(of: .zero), Int.max)
        XCTAssertEqual(ByteCount.zero.percent(of: .zero), 0)
        XCTAssertEqual(ByteCount(megabytes: 25).percent(of: ByteCount(megabytes: 100)), 25)
    }

    func testPercentSaturatesRatherThanOverflowing() {
        // rawValue * 100 overflows for anything above Int.max / 100.
        let verdict = ByteCount.max.percent(of: ByteCount(bytes: 1))
        XCTAssertGreaterThan(verdict, 0, "saturating multiply must keep the sign sane")
    }

    func testSumOverEmptySequenceIsZero() {
        XCTAssertEqual(ByteCount.sum([ByteCount]()), .zero)
    }

    func testSumSaturates() {
        XCTAssertEqual(ByteCount.sum([.max, .max, .max]), .max)
    }

    func testSaturatingMultiplyCoversIntMinTimesNegativeOne() {
        // The one multiplication that overflows without a large operand.
        XCTAssertEqual(ByteCount.saturatingMultiply(Int.min, -1), Int.max)
    }

    func testDescriptionIsStableAcrossMagnitudes() {
        XCTAssertEqual(ByteCount(bytes: 512).description, "512 B")
        XCTAssertEqual(ByteCount(kilobytes: 2).description, "2 KB")
        XCTAssertEqual(ByteCount(megabytes: 3).description, "3.0 MB")
    }
}
