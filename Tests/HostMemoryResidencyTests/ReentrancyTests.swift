import XCTest
@testable import HostMemoryResidency

/// A probe that parks every caller until `expected` of them have arrived.
///
/// This is what makes the reentrancy tests deterministic rather than hopeful.
/// Without it, "run some tasks concurrently and see if the bug shows up" is a
/// flaky test that passes on a fast machine and proves nothing. With it, every
/// caller is guaranteed to be suspended inside the probe at the same moment,
/// which is exactly the interleaving the hazard needs.
actor BarrierProbe: FootprintProbe {

    private let expected: Int
    private let value: ByteCount
    private var arrived = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(expected: Int, value: ByteCount = .zero) {
        self.expected = expected
        self.value = value
    }

    func currentFootprint() async -> ByteCount {
        await arriveAndWait()
        return value
    }

    private func arriveAndWait() async {
        arrived += 1
        if arrived >= expected {
            let pending = waiters
            waiters.removeAll()
            for continuation in pending { continuation.resume() }
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waiters.append(continuation)
        }
    }
}

/// The bug, written down.
///
/// This is a deliberately incorrect reference implementation. It lives in the
/// test target rather than the library because nobody should be able to import
/// it by accident, and it exists so the safe design's claim is demonstrated
/// rather than asserted.
///
/// The only difference from `SafeAdmissionActor` below is the position of one
/// `await`.
actor CheckThenActActor {
    private var outstanding = ByteCount.zero
    private let probe: any FootprintProbe
    private let ceiling: ByteCount
    private let cost: ByteCount

    init(probe: any FootprintProbe, ceiling: ByteCount, cost: ByteCount) {
        self.probe = probe
        self.ceiling = ceiling
        self.cost = cost
    }

    var outstandingBytes: ByteCount { outstanding }

    func admit() async -> Bool {
        // BUG: the decision is computed here, before the suspension...
        let projected = outstanding + cost
        _ = await probe.currentFootprint()
        // ...and acted on here, after every other caller has already decided.
        guard projected <= ceiling else { return false }
        outstanding = outstanding + cost
        return true
    }
}

/// The same actor with the `await` moved above the read. This is the shape
/// `ResidencyCoordinator.admit` uses.
actor SafeAdmissionActor {
    private var outstanding = ByteCount.zero
    private let probe: any FootprintProbe
    private let ceiling: ByteCount
    private let cost: ByteCount

    init(probe: any FootprintProbe, ceiling: ByteCount, cost: ByteCount) {
        self.probe = probe
        self.ceiling = ceiling
        self.cost = cost
    }

    var outstandingBytes: ByteCount { outstanding }

    func admit() async -> Bool {
        _ = await probe.currentFootprint()
        // No suspension between this read and the write below.
        let projected = outstanding + cost
        guard projected <= ceiling else { return false }
        outstanding = outstanding + cost
        return true
    }
}

final class ReentrancyTests: XCTestCase {

    private static let callers = 6
    private static let cost = ByteCount(megabytes: 30)
    /// Room for exactly three of them.
    private static let ceiling = ByteCount(megabytes: 90)

    private func fireConcurrently(_ admit: @escaping @Sendable () async -> Bool) async -> Int {
        await withTaskGroup(of: Bool.self, returning: Int.self) { group in
            for _ in 0..<Self.callers {
                group.addTask { await admit() }
            }
            var admitted = 0
            for await granted in group where granted { admitted += 1 }
            return admitted
        }
    }

    /// Establishes that the hazard is real, so the test below is measuring
    /// something rather than restating an implementation detail.
    func testCheckThenActAcrossASuspensionPointOvercommits() async {
        let actor = CheckThenActActor(
            probe: BarrierProbe(expected: Self.callers),
            ceiling: Self.ceiling,
            cost: Self.cost
        )

        let admitted = await fireConcurrently { await actor.admit() }
        let outstanding = await actor.outstandingBytes

        XCTAssertEqual(admitted, Self.callers, "every caller decided against the same stale total")
        XCTAssertGreaterThan(
            outstanding, Self.ceiling,
            "180 MB committed against a 90 MB ceiling — the process is dead and no single caller did anything wrong"
        )
    }

    /// The same barrier, the same six callers, the `await` in the right place.
    func testAwaitingBeforeReadingStateDoesNotOvercommit() async {
        let actor = SafeAdmissionActor(
            probe: BarrierProbe(expected: Self.callers),
            ceiling: Self.ceiling,
            cost: Self.cost
        )

        let admitted = await fireConcurrently { await actor.admit() }
        let outstanding = await actor.outstandingBytes

        XCTAssertEqual(admitted, 3, "exactly as many as fit")
        XCTAssertLessThanOrEqual(outstanding, Self.ceiling)
    }

    /// And the property held against the real coordinator, driven by the same
    /// barrier so every admission is genuinely in flight at once.
    func testCoordinatorNeverReservesBeyondItsCeilingUnderConcurrentAdmission() async throws {
        let host = HostClass(kind: .widgetExtension, tier: .constrained)
        let catalog = ExampleCatalog.make()
        let planner = ResidencyPlanner(budgets: .illustrative)
        let callers = 6

        let coordinator = ResidencyCoordinator(
            planner: planner,
            catalog: catalog,
            probe: BarrierProbe(expected: callers, value: ByteCount(megabytes: 9))
        )

        let refusals = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
            for _ in 0..<callers {
                group.addTask {
                    if case .failure = await coordinator.admit(host: host) { return true }
                    return false
                }
            }
            var count = 0
            for await refused in group where refused { count += 1 }
            return count
        }

        // The exact figure a single cold admission would reserve. Asserting
        // against this rather than against some loose upper bound is the point:
        // if `admit` reserved the full peak per caller instead of the delta, the
        // ledger would hold a multiple of it and this would fail. A bound like
        // "less than 6x" would not — the ledger's own ceiling check stops the
        // stacking bug well before 6x, so a loose assertion passes against it.
        let coldPlan = try planner.plan(
            host: host,
            purpose: host.kind.defaultPurpose,
            catalog: catalog
        )
        let reserved = await coordinator.outstandingReservationBytes

        XCTAssertEqual(
            reserved, coldPlan.reservedPeakBytes,
            "six callers must reserve the peak once between them, not once each"
        )
        XCTAssertEqual(refusals, 0, "all six fit; the second onwards cost nothing extra")
    }
}

final class ResidencyCoordinatorTests: XCTestCase {

    private func makeCoordinator(
        footprintMB: Int = 0,
        catalog: ComponentCatalog = ExampleCatalog.make()
    ) -> ResidencyCoordinator {
        ResidencyCoordinator(
            planner: ResidencyPlanner(budgets: .illustrative),
            catalog: catalog,
            probe: MutableFootprintProbe(ByteCount(megabytes: footprintMB))
        )
    }

    func testAdmissionMakesTheSelectedComponentsResident() async throws {
        let coordinator = makeCoordinator()
        let host = HostClass(kind: .widgetExtension, tier: .standard)

        let outcome = await coordinator.admit(host: host)
        guard case .success(let admitted) = outcome else {
            return XCTFail("expected an admission, got \(outcome)")
        }

        let resident = await coordinator.residentComponents
        XCTAssertEqual(
            Set(resident.map(\.id)),
            Set(admitted.plan.selections.map(\.id))
        )
        let reserved = await coordinator.outstandingReservationBytes
        XCTAssertGreaterThan(reserved, .zero)
    }

    func testCompletingAnAdmissionReleasesTheReservationAndRecordsTheSample() async throws {
        let coordinator = makeCoordinator()
        let host = HostClass(kind: .widgetExtension, tier: .standard)

        guard case .success(let admitted) = await coordinator.admit(host: host) else {
            return XCTFail("expected an admission")
        }

        let released = await coordinator.complete(
            admitted,
            observedPeak: admitted.plan.reservedPeakBytes.scaled(numerator: 95, denominator: 100)
        )
        XCTAssertTrue(released)
        let reserved = await coordinator.outstandingReservationBytes
        let verdict = await coordinator.auditVerdict()
        XCTAssertEqual(reserved, .zero)
        XCTAssertTrue(verdict.isPass)
    }

    func testAnUnderPredictedActivationFailsTheCoordinatorsGate() async throws {
        let coordinator = makeCoordinator()
        let host = HostClass(kind: .widgetExtension, tier: .standard)

        guard case .success(let admitted) = await coordinator.admit(host: host) else {
            return XCTFail("expected an admission")
        }
        await coordinator.complete(
            admitted,
            observedPeak: admitted.plan.reservedPeakBytes.scaled(numerator: 180, denominator: 100)
        )

        let verdict = await coordinator.auditVerdict(tolerancePercent: 10)
        XCTAssertFalse(verdict.isPass)
    }

    func testAbandoningAnAdmissionRollsBackTheComponentsItBroughtIn() async throws {
        let coordinator = makeCoordinator()
        let host = HostClass(kind: .widgetExtension, tier: .standard)

        guard case .success(let admitted) = await coordinator.admit(host: host) else {
            return XCTFail("expected an admission")
        }
        let populated = await coordinator.residentComponents
        XCTAssertFalse(populated.isEmpty)

        let released = await coordinator.abandon(admitted)
        let remaining = await coordinator.residentComponents
        let reserved = await coordinator.outstandingReservationBytes
        XCTAssertTrue(released)
        XCTAssertTrue(remaining.isEmpty)
        XCTAssertEqual(reserved, .zero)
    }

    /// Pressure may take optional and degradable components. It must never
    /// silently evict a required one — a feature that keeps running while
    /// answering incorrectly is worse than a feature that is told to stop.
    func testPressureSacrificesOptionalComponentsAndKeepsRequiredOnes() async throws {
        let catalog = try ComponentCatalog([
            Fixture.declaration(
                "entitlements", .required, floor: .reduced,
                purposes: [.timelineRefresh],
                [
                    Fixture.profile(.full, residentMB: 4),
                    Fixture.profile(.reduced, residentMB: 2),
                ]
            ),
            Fixture.declaration(
                "cache", .optional, floor: .full,
                purposes: [.timelineRefresh],
                [Fixture.profile(.full, residentMB: 16)]
            ),
        ])
        let coordinator = makeCoordinator(catalog: catalog)
        let host = HostClass(kind: .widgetExtension, tier: .standard)

        guard case .success = await coordinator.admit(host: host) else {
            return XCTFail("expected an admission")
        }
        let before = await coordinator.residentComponents.map(\.id)
        XCTAssertTrue(before.contains(ComponentID("cache")))

        let outcome = await coordinator.apply(pressure: .critical)
        let after = await coordinator.residentComponents.map(\.id)

        XCTAssertTrue(
            after.contains(ComponentID("entitlements")),
            "the required component survives pressure"
        )
        if case .sacrificed(let lost) = outcome {
            XCTAssertEqual(lost, [ComponentID("cache")])
        } else {
            // The whole point of the outcome type is that a loss is *reported*.
            // If pressure returned `.absorbed`, the optional component must
            // still be resident — a silent eviction is the bug.
            XCTAssertTrue(
                after.contains(ComponentID("cache")),
                "nothing was reported as sacrificed, so nothing may have quietly disappeared: \(outcome)"
            )
        }
    }

    /// `apply(_:)` writes fidelity and byte costs into the resident set. Without
    /// this, recording every component at the wrong tier passes the whole suite.
    func testAdmissionRecordsTheExactFidelityAndCostsItPlanned() async throws {
        let coordinator = makeCoordinator()
        let host = HostClass(kind: .widgetExtension, tier: .standard)

        guard case .success(let admitted) = await coordinator.admit(host: host) else {
            return XCTFail("expected an admission")
        }
        let resident = await coordinator.residentComponents
        let byID = Dictionary(resident.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        XCTAssertEqual(resident.count, admitted.plan.selections.count)
        for selection in admitted.plan.selections {
            let recorded = try XCTUnwrap(byID[selection.id], "\(selection.id) missing from residency")
            XCTAssertEqual(recorded.fidelity, selection.fidelity, "\(selection.id) fidelity")
            XCTAssertEqual(recorded.residentBytes, selection.residentBytes, "\(selection.id) bytes")
        }
        let tracked = await coordinator.trackedResidentBytes
        XCTAssertEqual(tracked, admitted.plan.steadyStateBytes)
    }

    /// A superseded plan must not roll residency back out from under the plan
    /// that replaced it.
    func testAbandoningASupersededPlanDoesNotDeleteTheLivePlansComponents() async throws {
        let coordinator = makeCoordinator()
        let host = HostClass(kind: .widgetExtension, tier: .standard)

        guard case .success(let first) = await coordinator.admit(host: host),
              case .success(let second) = await coordinator.admit(host: host) else {
            return XCTFail("expected two admissions")
        }

        let rolledBack = await coordinator.abandon(first)
        let resident = await coordinator.residentComponents
        let stillReserved = await coordinator.outstandingReservationBytes

        XCTAssertFalse(rolledBack, "the first plan is stale; it must report that it undid nothing")
        XCTAssertEqual(
            Set(resident.map(\.id)),
            Set(second.plan.selections.map(\.id)),
            "the live plan's components must survive"
        )
        XCTAssertEqual(stillReserved, .zero, "the stale reservation is released either way")
    }

    /// The control for the test above: a plan that has *not* been superseded
    /// does roll its own components back out.
    func testAbandoningTheLivePlanRollsItsComponentsBack() async throws {
        let coordinator = makeCoordinator()
        let host = HostClass(kind: .widgetExtension, tier: .standard)

        guard case .success(let only) = await coordinator.admit(host: host) else {
            return XCTFail("expected an admission")
        }
        let populated = await coordinator.residentComponents
        XCTAssertFalse(populated.isEmpty)

        let rolledBack = await coordinator.abandon(only)
        let remaining = await coordinator.residentComponents
        let reserved = await coordinator.outstandingReservationBytes

        XCTAssertTrue(rolledBack)
        XCTAssertTrue(remaining.isEmpty)
        XCTAssertEqual(reserved, .zero)
    }

    /// `reset` revokes reservations; a later `complete` must not file a sample
    /// for work that was cancelled.
    func testCompletingACancelledAdmissionRecordsNothing() async throws {
        let coordinator = makeCoordinator()
        let host = HostClass(kind: .widgetExtension, tier: .standard)
        guard case .success(let admitted) = await coordinator.admit(host: host) else {
            return XCTFail("expected an admission")
        }

        await coordinator.reset()
        let recorded = await coordinator.complete(admitted, observedPeak: ByteCount(megabytes: 999))
        let verdict = await coordinator.auditVerdict()

        XCTAssertFalse(recorded)
        if case .insufficientData = verdict {
            // expected: no sample was filed
        } else {
            XCTFail("a cancelled admission must not reach the audit: \(verdict)")
        }
    }

    /// Zero-byte reservations always satisfy the ceiling check, so the only
    /// thing standing between a re-admitting widget and an unbounded dictionary
    /// is the cap.
    func testTheLedgerRefusesOnceItsReservationCapIsReached() async {
        let coordinator = ResidencyCoordinator(
            planner: ResidencyPlanner(budgets: .illustrative),
            catalog: ExampleCatalog.make(),
            probe: MutableFootprintProbe(.zero),
            maximumOutstandingReservations: 3
        )
        let host = HostClass(kind: .widgetExtension, tier: .standard)

        var admitted = 0
        for _ in 0..<10 {
            if case .success = await coordinator.admit(host: host) { admitted += 1 }
        }
        XCTAssertEqual(admitted, 3, "the cap, not the ceiling, is what stops this")
    }

    func testResetClearsResidencyReservationsAndAudit() async throws {
        let coordinator = makeCoordinator()
        let host = HostClass(kind: .widgetExtension, tier: .standard)
        guard case .success(let admitted) = await coordinator.admit(host: host) else {
            return XCTFail("expected an admission")
        }
        await coordinator.complete(admitted, observedPeak: admitted.plan.reservedPeakBytes)

        await coordinator.reset()

        let remaining = await coordinator.residentComponents
        let reserved = await coordinator.outstandingReservationBytes
        let level = await coordinator.currentPressure
        XCTAssertTrue(remaining.isEmpty)
        XCTAssertEqual(reserved, .zero)
        XCTAssertEqual(level, .normal)
        if case .insufficientData = await coordinator.auditVerdict() {
            // expected
        } else {
            XCTFail("audit should have been cleared")
        }
    }

    func testAdmissionIsRefusedWhenTheMeasuredFootprintAlreadyFillsTheCeiling() async {
        // The device is already at 45 MB inside a 48 MB widget ceiling.
        let coordinator = makeCoordinator(footprintMB: 45)
        let host = HostClass(kind: .widgetExtension, tier: .standard)

        let outcome = await coordinator.admit(host: host)
        guard case .failure(let refusal) = outcome else {
            return XCTFail("expected a refusal, got \(outcome)")
        }
        if case .headroomExhausted = refusal {
            // expected
        } else {
            XCTFail("expected headroomExhausted, got \(refusal)")
        }
        let remaining = await coordinator.residentComponents
        XCTAssertTrue(remaining.isEmpty)
    }
}
