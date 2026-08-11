import XCTest
@testable import HostMemoryResidency

final class ReservationLedgerTests: XCTestCase {

    func testReserveRefusesRatherThanTruncatingWhenItDoesNotFit() {
        var ledger = ReservationLedger()
        ledger.setMeasuredBaseline(ByteCount(megabytes: 30))

        let ceiling = ByteCount(megabytes: 50)
        XCTAssertNotNil(ledger.reserve(peak: ByteCount(megabytes: 15), ceiling: ceiling))
        XCTAssertNil(
            ledger.reserve(peak: ByteCount(megabytes: 10), ceiling: ceiling),
            "30 measured + 15 reserved + 10 requested exceeds 50"
        )
        XCTAssertEqual(ledger.outstandingBytes, ByteCount(megabytes: 15))
    }

    func testExactFitIsAdmitted() {
        var ledger = ReservationLedger()
        ledger.setMeasuredBaseline(ByteCount(megabytes: 40))
        XCTAssertNotNil(
            ledger.reserve(peak: ByteCount(megabytes: 10), ceiling: ByteCount(megabytes: 50))
        )
    }

    func testDoubleReleaseIsReportedRatherThanAbsorbed() throws {
        var ledger = ReservationLedger()
        let claim = try XCTUnwrap(
            ledger.reserve(peak: ByteCount(megabytes: 5), ceiling: ByteCount(megabytes: 50))
        )

        XCTAssertTrue(ledger.release(claim))
        XCTAssertFalse(ledger.release(claim), "a double release is a caller bug worth surfacing")
        XCTAssertEqual(ledger.outstandingBytes, .zero)
    }

    func testEpochsAreMonotonic() {
        var ledger = ReservationLedger()
        let ceiling = ByteCount(megabytes: 100)
        let first = ledger.reserve(peak: ByteCount(megabytes: 1), ceiling: ceiling)
        let second = ledger.reserve(peak: ByteCount(megabytes: 1), ceiling: ceiling)
        XCTAssertNotNil(first)
        XCTAssertNotNil(second)
        XCTAssertLessThan(first?.epoch ?? 0, second?.epoch ?? 0)
    }

    func testHighWaterMarkIsNotResetByRelease() {
        var ledger = ReservationLedger()
        let ceiling = ByteCount(megabytes: 100)
        guard let claim = ledger.reserve(peak: ByteCount(megabytes: 60), ceiling: ceiling) else {
            return XCTFail("should fit")
        }
        XCTAssertEqual(ledger.highWaterMark, ByteCount(megabytes: 60))
        ledger.release(claim)
        XCTAssertEqual(ledger.highWaterMark, ByteCount(megabytes: 60))
        XCTAssertEqual(ledger.outstandingBytes, .zero)
    }

    func testRevokeAllClearsEveryOutstandingClaim() {
        var ledger = ReservationLedger()
        let ceiling = ByteCount(megabytes: 100)
        _ = ledger.reserve(peak: ByteCount(megabytes: 10), ceiling: ceiling)
        _ = ledger.reserve(peak: ByteCount(megabytes: 10), ceiling: ceiling)
        XCTAssertEqual(ledger.reservationCount, 2)
        ledger.revokeAll()
        XCTAssertEqual(ledger.reservationCount, 0)
        XCTAssertEqual(ledger.outstandingBytes, .zero)
    }
}

final class BudgetAuditTests: XCTestCase {

    private func sample(reservedMB: Int, observedMB: Int) -> AuditSample {
        AuditSample(
            host: Fixture.host,
            purpose: .fullExperience,
            activationModel: .sequential,
            reservedPeak: ByteCount(megabytes: reservedMB),
            observedPeak: ByteCount(megabytes: observedMB)
        )
    }

    /// The mutation test for the gate itself.
    ///
    /// A model that reports half the true peak is exactly the bug the gate
    /// exists to catch. If this fed the gate and the gate said "pass", the gate
    /// would be decoration — so the assertion is that the check **fails**.
    func testGateFailsAgainstADeliberatelyUnderPredictingModel() {
        var audit = BudgetAudit(capacity: 8)
        for _ in 0..<5 {
            audit.record(sample(reservedMB: 50, observedMB: 100))
        }

        let verdict = audit.verdict(tolerancePercent: 10)
        guard case .fail(let samples, let worst, let tolerance) = verdict else {
            return XCTFail("a model under-predicting by 100% must not pass; got \(verdict)")
        }
        XCTAssertEqual(samples, 5)
        XCTAssertEqual(worst, 100)
        XCTAssertEqual(tolerance, 10)
        XCTAssertEqual(audit.underPredictionCount, 5)
    }

    func testGatePassesAnHonestlyConservativeModel() {
        var audit = BudgetAudit(capacity: 8)
        for _ in 0..<3 {
            audit.record(sample(reservedMB: 50, observedMB: 44))
        }
        XCTAssertTrue(audit.verdict().isPass, "over-prediction wastes headroom but is not unsafe")
        XCTAssertEqual(audit.underPredictionCount, 0)
    }

    func testToleranceIsRespectedInBothDirections() {
        var audit = BudgetAudit(capacity: 8)
        audit.record(sample(reservedMB: 100, observedMB: 105))
        XCTAssertTrue(audit.verdict(tolerancePercent: 10).isPass)
        XCTAssertFalse(audit.verdict(tolerancePercent: 2).isPass)
    }

    /// A burst of bad samples must not be erasable simply by pushing enough
    /// good ones through afterwards.
    func testUnderPredictionCountersSurviveRingEviction() {
        var audit = BudgetAudit(capacity: 2)
        audit.record(sample(reservedMB: 10, observedMB: 40))
        for _ in 0..<10 {
            audit.record(sample(reservedMB: 10, observedMB: 9))
        }

        XCTAssertEqual(audit.samples.count, 2, "storage stays bounded")
        XCTAssertEqual(audit.totalSamples, 11)
        XCTAssertEqual(audit.underPredictionCount, 1)
        XCTAssertFalse(
            audit.verdict(tolerancePercent: 50).isPass,
            "the 300% under-prediction still fails the gate after being evicted from the ring"
        )
    }

    func testStorageIsBounded() {
        var audit = BudgetAudit(capacity: 4)
        for index in 0..<200 {
            audit.record(sample(reservedMB: 10, observedMB: index % 7))
        }
        XCTAssertEqual(audit.samples.count, 4)
        XCTAssertEqual(audit.totalSamples, 200)
    }

    func testSamplesAreReturnedOldestFirstAfterWrapping() {
        var audit = BudgetAudit(capacity: 3)
        for index in 1...5 {
            audit.record(sample(reservedMB: 10, observedMB: index))
        }
        XCTAssertEqual(
            audit.samples.map(\.observedPeak),
            [3, 4, 5].map { ByteCount(megabytes: $0) }
        )
    }

    func testGateReportsInsufficientDataRatherThanPassingByDefault() {
        let audit = BudgetAudit(capacity: 4)
        guard case .insufficientData(let samples, let required) = audit.verdict(minimumSamples: 3) else {
            return XCTFail("an empty audit must not report a pass")
        }
        XCTAssertEqual(samples, 0)
        XCTAssertEqual(required, 3)
    }

    func testZeroCapacityIsClampedSoTheGateIsNeverBlind() {
        var audit = BudgetAudit(capacity: 0)
        audit.record(sample(reservedMB: 10, observedMB: 20))
        XCTAssertEqual(audit.capacity, 1)
        XCTAssertEqual(audit.samples.count, 1)
        XCTAssertFalse(audit.verdict().isPass)
    }

    func testTheReservationCapIsEnforced() {
        var ledger = ReservationLedger(maximumOutstandingReservations: 2)
        let ceiling = ByteCount(megabytes: 100)
        // Zero-byte reservations always satisfy the ceiling check, which is why
        // the count cap has to exist independently of it.
        XCTAssertNotNil(ledger.reserve(peak: .zero, ceiling: ceiling))
        XCTAssertNotNil(ledger.reserve(peak: .zero, ceiling: ceiling))
        XCTAssertNil(ledger.reserve(peak: .zero, ceiling: ceiling))
        XCTAssertEqual(ledger.reservationCount, 2)
    }

    func testUnderPredictionPercentDoesNotDivideByZero() {
        let zeroReserved = AuditSample(
            host: Fixture.host,
            purpose: .fullExperience,
            activationModel: .sequential,
            reservedPeak: .zero,
            observedPeak: ByteCount(megabytes: 1)
        )
        XCTAssertTrue(zeroReserved.underPredicted)
        // Clamped rather than Int.max: one such sample would otherwise pin the
        // gate at 9223372036854775807% forever — still failing, but unreadable.
        XCTAssertEqual(
            zeroReserved.underPredictionPercent,
            AuditSample.maximumReportedUnderPredictionPercent
        )

        var audit = BudgetAudit(capacity: 4)
        audit.record(zeroReserved)
        XCTAssertEqual(
            audit.worstUnderPredictionPercent,
            AuditSample.maximumReportedUnderPredictionPercent
        )
        XCTAssertFalse(audit.verdict(tolerancePercent: 50).isPass)
    }

    func testResetClearsEverything() {
        var audit = BudgetAudit(capacity: 4)
        audit.record(sample(reservedMB: 10, observedMB: 40))
        audit.reset()
        XCTAssertEqual(audit.totalSamples, 0)
        XCTAssertEqual(audit.underPredictionCount, 0)
        XCTAssertEqual(audit.worstUnderPredictionPercent, 0)
        XCTAssertTrue(audit.samples.isEmpty)
    }
}
