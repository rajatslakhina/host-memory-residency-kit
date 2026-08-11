import XCTest
@testable import HostMemoryResidency

final class ResidencyPlannerTests: XCTestCase {

    // MARK: - Fail-closed budget resolution

    func testUnknownHostFallsBackToTheSmallestBudgetNotTheLargest() {
        let big = HostClass(kind: .application, tier: .generous)
        let small = HostClass(kind: .widgetExtension, tier: .constrained)
        let table = HostBudgetTable(entries: [
            big: HostBudget(limit: ByteCount(megabytes: 4_000), baseline: .zero, safetyMargin: .zero),
            small: HostBudget(limit: ByteCount(megabytes: 30), baseline: .zero, safetyMargin: .zero),
        ])

        let unlisted = HostClass(kind: .notificationServiceExtension, tier: .generous)
        XCTAssertEqual(table.budget(for: unlisted)?.limit, ByteCount(megabytes: 30))
        XCTAssertEqual(table.budget(for: big)?.limit, ByteCount(megabytes: 4_000))
    }

    func testEmptyBudgetTableRefusesEveryPlan() throws {
        let planner = ResidencyPlanner(budgets: HostBudgetTable(entries: [:]))
        let catalog = try Fixture.catalog([])
        assertRefuses(
            try planner.plan(host: Fixture.host, purpose: .fullExperience, catalog: catalog),
            { if case .noBudgetForHost = $0 { return true }; return false },
            "an empty budget table must refuse rather than assume a default"
        )
    }

    // MARK: - The net-negative eviction rule

    /// A component whose teardown costs more than it frees cannot be evicted,
    /// so its bytes keep consuming headroom — and that tax can be what pushes a
    /// required component out of the plan.
    func testNetNegativeEvictionIsRetainedAndCanRefuseARequiredComponent() throws {
        let planner = ResidencyPlanner(budgets: Fixture.budgets(headroomMB: 100))
        let catalog = try Fixture.catalog([
            Fixture.declaration("keeper", .required, floor: .full, [
                Fixture.profile(.full, residentMB: 60)
            ])
        ])
        // 50 MB resident, but flushing it needs a 60 MB buffer.
        let ghost = Fixture.resident("ghost", residentMB: 50, teardownMB: 60)

        assertRefuses(
            try planner.plan(
                host: Fixture.host,
                purpose: .fullExperience,
                catalog: catalog,
                resident: [ghost]
            ),
            {
                guard case .requiredComponentDoesNotFit(let id, let needed, _) = $0 else { return false }
                return id == ComponentID("keeper") && needed == ByteCount(megabytes: 110)
            },
            "retained 50 MB + required 60 MB exceeds 100 MB of headroom"
        )
    }

    /// The control that makes the test above non-vacuous: change *only* the
    /// teardown cost and the identical scenario now succeeds, because the
    /// component becomes genuinely evictable.
    func testTheSameScenarioSucceedsWhenTeardownIsCheap() throws {
        let planner = ResidencyPlanner(budgets: Fixture.budgets(headroomMB: 100))
        let catalog = try Fixture.catalog([
            Fixture.declaration("keeper", .required, floor: .full, [
                Fixture.profile(.full, residentMB: 60)
            ])
        ])
        let ghost = Fixture.resident("ghost", residentMB: 50, teardownMB: 10)

        let plan = try planner.plan(
            host: Fixture.host,
            purpose: .fullExperience,
            catalog: catalog,
            resident: [ghost]
        )

        XCTAssertEqual(plan.evictions.map(\.id), [ComponentID("ghost")])
        XCTAssertTrue(plan.retained.isEmpty)
        XCTAssertEqual(plan.steadyStateBytes, ByteCount(megabytes: 60))
    }

    /// Freeing memory is not free, and a process can be too tight to shrink.
    func testTeardownItselfCanBeUnaffordable() throws {
        let planner = ResidencyPlanner(budgets: Fixture.budgets(headroomMB: 100))
        let catalog = try Fixture.catalog([])
        let ghost = Fixture.resident("ghost", residentMB: 90, teardownMB: 20)

        assertRefuses(
            try planner.plan(
                host: Fixture.host,
                purpose: .fullExperience,
                catalog: catalog,
                resident: [ghost]
            ),
            {
                guard case .cannotAffordTeardown(let needed, let headroom) = $0 else { return false }
                return needed == ByteCount(megabytes: 110) && headroom == ByteCount(megabytes: 100)
            },
            "90 MB resident plus a 20 MB flush buffer does not fit in 100 MB"
        )
    }

    // MARK: - The reduction ladder

    /// Meaning-preserving reductions come first. If the phases ran in the other
    /// order the optional component would be gone and the degradable one would
    /// still be sitting at full.
    func testMeaningPreservingReductionRunsBeforeDroppingAnOptionalComponent() throws {
        let planner = ResidencyPlanner(budgets: Fixture.budgets(headroomMB: 50))
        let catalog = try Fixture.catalog([
            Fixture.declaration("index", .degradable, floor: .reduced, [
                Fixture.profile(.full, residentMB: 40),
                Fixture.profile(.reduced, residentMB: 10),
            ]),
            Fixture.declaration("cache", .optional, floor: .full, [
                Fixture.profile(.full, residentMB: 20)
            ]),
        ])

        let plan = try planner.plan(host: Fixture.host, purpose: .fullExperience, catalog: catalog)

        XCTAssertEqual(plan.selection(for: ComponentID("index"))?.fidelity, .reduced)
        XCTAssertEqual(
            plan.selection(for: ComponentID("cache"))?.fidelity, .full,
            "the optional component must survive: losing a whole feature costs more than losing resolution"
        )
        XCTAssertTrue(plan.degradations.isEmpty)
    }

    func testDroppingBelowTheMeaningFloorIsRecordedAndFlagged() throws {
        let planner = ResidencyPlanner(budgets: Fixture.budgets(headroomMB: 8))
        let catalog = try Fixture.catalog([
            Fixture.declaration("index", .degradable, floor: .reduced, [
                Fixture.profile(.full, residentMB: 40),
                Fixture.profile(.reduced, residentMB: 10),
                Fixture.profile(.minimal, residentMB: 3),
            ]),
            Fixture.declaration("session", .required, floor: .minimal, [
                Fixture.profile(.full, residentMB: 6),
                Fixture.profile(.minimal, residentMB: 2),
            ]),
        ])

        let plan = try planner.plan(host: Fixture.host, purpose: .fullExperience, catalog: catalog)

        XCTAssertEqual(plan.selection(for: ComponentID("index"))?.fidelity, .minimal)
        XCTAssertEqual(plan.selection(for: ComponentID("index"))?.meaningPreserved, false)
        XCTAssertEqual(plan.degradations.count, 1)
        let record = try XCTUnwrap(plan.degradations.first)
        XCTAssertEqual(record.component, ComponentID("index"))
        XCTAssertEqual(record.from, .full)
        XCTAssertEqual(record.to, .minimal)
        XCTAssertEqual(record.meaningFloor, .reduced)
        XCTAssertEqual(plan.steadyStateBytes, ByteCount(megabytes: 5))
    }

    /// A required component must never be quietly stepped below its meaning
    /// floor, even though a cheaper profile exists and would have fitted.
    func testRequiredComponentIsRefusedRatherThanSteppedBelowItsMeaningFloor() throws {
        let planner = ResidencyPlanner(budgets: Fixture.budgets(headroomMB: 3))
        let catalog = try Fixture.catalog([
            Fixture.declaration("entitlements", .required, floor: .reduced, [
                Fixture.profile(.full, residentMB: 6),
                Fixture.profile(.reduced, residentMB: 4),
                // 1 MB would have fitted. Taking it would mean answering
                // entitlement questions from a stale snapshot.
                Fixture.profile(.minimal, residentMB: 1),
            ])
        ])

        assertRefuses(
            try planner.plan(host: Fixture.host, purpose: .fullExperience, catalog: catalog),
            {
                guard case .requiredComponentDoesNotFit(let id, _, _) = $0 else { return false }
                return id == ComponentID("entitlements")
            },
            "the 1 MB profile fits but is below the meaning floor, so it must not be chosen"
        )
    }

    func testOptionalComponentsAreDroppedBeforeMeaningIsChanged() throws {
        let planner = ResidencyPlanner(budgets: Fixture.budgets(headroomMB: 12))
        let catalog = try Fixture.catalog([
            Fixture.declaration("index", .degradable, floor: .reduced, [
                Fixture.profile(.full, residentMB: 30),
                Fixture.profile(.reduced, residentMB: 10),
                Fixture.profile(.minimal, residentMB: 2),
            ]),
            Fixture.declaration("cache", .optional, floor: .full, [
                Fixture.profile(.full, residentMB: 8)
            ]),
        ])

        let plan = try planner.plan(host: Fixture.host, purpose: .fullExperience, catalog: catalog)

        XCTAssertNil(plan.selection(for: ComponentID("cache")), "optional should be dropped")
        XCTAssertEqual(
            plan.selection(for: ComponentID("index"))?.fidelity, .reduced,
            "the degradable component must stay at its meaning floor"
        )
        XCTAssertTrue(plan.degradations.isEmpty)
    }

    // MARK: - Activation modelling

    func testConcurrentActivationReservesMoreThanSequential() throws {
        let planner = ResidencyPlanner(budgets: Fixture.budgets(headroomMB: 200))
        let catalog = try Fixture.catalog([
            Fixture.declaration("a", .required, floor: .full, [
                Fixture.profile(.full, residentMB: 10, activationMB: 5)
            ]),
            Fixture.declaration("b", .required, floor: .full, [
                Fixture.profile(.full, residentMB: 10, activationMB: 7)
            ]),
        ])

        let sequential = try planner.plan(
            host: Fixture.host, purpose: .fullExperience, catalog: catalog, activationModel: .sequential
        )
        let concurrent = try planner.plan(
            host: Fixture.host, purpose: .fullExperience, catalog: catalog, activationModel: .concurrent
        )

        XCTAssertEqual(sequential.steadyStateBytes, ByteCount(megabytes: 20))
        XCTAssertEqual(sequential.reservedPeakBytes, ByteCount(megabytes: 27), "20 + max(5, 7)")
        XCTAssertEqual(concurrent.reservedPeakBytes, ByteCount(megabytes: 32), "20 + 5 + 7")
    }

    /// Re-planning must not invent an activation cost for something that never
    /// leaves memory. Without this, every pressure re-plan would look like a
    /// cold start and refuse work that comfortably fits.
    func testAlreadyResidentComponentsPayNoActivationCost() throws {
        let planner = ResidencyPlanner(budgets: Fixture.budgets(headroomMB: 25))
        let catalog = try Fixture.catalog([
            Fixture.declaration("model", .required, floor: .full, [
                Fixture.profile(.full, residentMB: 10, activationMB: 20)
            ])
        ])

        assertRefuses(
            try planner.plan(host: Fixture.host, purpose: .fullExperience, catalog: catalog),
            { if case .requiredComponentDoesNotFit = $0 { return true }; return false },
            "a cold load peaks at 30 MB against 25 MB of headroom"
        )

        let warm = try planner.plan(
            host: Fixture.host,
            purpose: .fullExperience,
            catalog: catalog,
            resident: [Fixture.resident("model", .full, residentMB: 10)]
        )
        XCTAssertEqual(warm.reservedPeakBytes, ByteCount(megabytes: 10))
        XCTAssertEqual(warm.selection(for: ComponentID("model"))?.alreadyResident, true)
    }

    // MARK: - Determinism and totality

    func testPlanIsIdenticalRegardlessOfDeclarationOrder() throws {
        let declarations = [
            Fixture.declaration("zeta", .optional, floor: .full, [Fixture.profile(.full, residentMB: 9)]),
            Fixture.declaration("alpha", .optional, floor: .full, [Fixture.profile(.full, residentMB: 9)]),
            Fixture.declaration("mid", .degradable, floor: .reduced, [
                Fixture.profile(.full, residentMB: 20),
                Fixture.profile(.reduced, residentMB: 5),
            ]),
        ]
        let planner = ResidencyPlanner(budgets: Fixture.budgets(headroomMB: 24))

        let forward = try planner.plan(
            host: Fixture.host, purpose: .fullExperience, catalog: try Fixture.catalog(declarations)
        )
        let reversed = try planner.plan(
            host: Fixture.host, purpose: .fullExperience, catalog: try Fixture.catalog(declarations.reversed())
        )

        XCTAssertEqual(forward, reversed, "identical inputs must produce byte-identical plans")
    }

    func testEmptyCatalogProducesAnEmptyPlanRatherThanFailing() throws {
        let planner = ResidencyPlanner(budgets: Fixture.budgets(headroomMB: 10))
        let plan = try planner.plan(
            host: Fixture.host, purpose: .fullExperience, catalog: try Fixture.catalog([])
        )
        XCTAssertTrue(plan.selections.isEmpty)
        XCTAssertEqual(plan.steadyStateBytes, .zero)
        XCTAssertEqual(plan.reservedPeakBytes, .zero)
        XCTAssertEqual(plan.peakUtilisationPercent, 0)
    }

    func testZeroHeadroomIsDescribableRatherThanFatal() throws {
        let table = HostBudgetTable(entries: [
            Fixture.host: HostBudget(
                limit: ByteCount(megabytes: 10),
                baseline: ByteCount(megabytes: 40),
                safetyMargin: ByteCount(megabytes: 5)
            )
        ])
        let planner = ResidencyPlanner(budgets: table)
        // Baseline already exceeds the limit: headroom saturates at zero.
        XCTAssertEqual(table.budget(for: Fixture.host)?.headroom, .zero)

        let plan = try planner.plan(
            host: Fixture.host, purpose: .fullExperience, catalog: try Fixture.catalog([])
        )
        XCTAssertEqual(plan.headroomBytes, .zero)
        XCTAssertEqual(plan.peakUtilisationPercent, 100)
    }

    // MARK: - Pressure

    func testPressureRevokesHeadroomByRaisingTheMarginNotLoweringTheLimit() {
        let budget = HostBudget(
            limit: ByteCount(megabytes: 100),
            baseline: .zero,
            safetyMargin: .zero
        )
        let underPressure = budget.underPressure(.critical, policy: .default)

        XCTAssertEqual(underPressure.limit, budget.limit, "the OS's number must not be rewritten")
        XCTAssertEqual(underPressure.safetyMargin, ByteCount(megabytes: 60))
        XCTAssertEqual(underPressure.headroom, ByteCount(megabytes: 40))
    }

    func testPressureChangesThePlanItProduces() throws {
        let planner = ResidencyPlanner(budgets: Fixture.budgets(headroomMB: 40))
        let catalog = try Fixture.catalog([
            Fixture.declaration("index", .degradable, floor: .reduced, [
                Fixture.profile(.full, residentMB: 30),
                Fixture.profile(.reduced, residentMB: 6),
            ]),
            Fixture.declaration("cache", .optional, floor: .full, [
                Fixture.profile(.full, residentMB: 8)
            ]),
        ])

        let calm = try planner.plan(host: Fixture.host, purpose: .fullExperience, catalog: catalog)
        XCTAssertEqual(calm.selection(for: ComponentID("index"))?.fidelity, .full)

        let stressed = try planner.plan(
            host: Fixture.host, purpose: .fullExperience, catalog: catalog, pressure: .critical
        )
        XCTAssertEqual(stressed.headroomBytes, ByteCount(megabytes: 16))
        XCTAssertEqual(stressed.selection(for: ComponentID("index"))?.fidelity, .reduced)
    }

    func testPressurePolicyClampsOutOfRangeConfiguration() {
        let absurd = PressurePolicy(warningRevocationPercent: 400, criticalRevocationPercent: -20)
        XCTAssertEqual(absurd.warningRevocationPercent, 100)
        XCTAssertEqual(absurd.criticalRevocationPercent, 0)
    }

    // MARK: - Purpose scoping

    func testComponentsOutsideThePurposeAreNotCandidates() throws {
        let planner = ResidencyPlanner(budgets: Fixture.budgets(headroomMB: 500))
        let catalog = try Fixture.catalog([
            Fixture.declaration("app-only", .required, floor: .full, purposes: [.fullExperience], [
                Fixture.profile(.full, residentMB: 10)
            ]),
            Fixture.declaration("widget-only", .required, floor: .full, purposes: [.timelineRefresh], [
                Fixture.profile(.full, residentMB: 4)
            ]),
        ])

        let widgetPlan = try planner.plan(
            host: Fixture.host, purpose: .timelineRefresh, catalog: catalog
        )
        XCTAssertEqual(widgetPlan.selections.map(\.id), [ComponentID("widget-only")])
    }

    // MARK: - The shipped example, end to end

    func testTheExampleCatalogDegradesAsTheHostGetsSmaller() throws {
        let planner = ResidencyPlanner(budgets: .illustrative)
        let catalog = ExampleCatalog.make()

        let app = try planner.plan(
            host: HostClass(kind: .application, tier: .standard),
            purpose: .fullExperience,
            catalog: catalog
        )
        XCTAssertTrue(
            app.degradations.isEmpty,
            "an app process on a standard device should not have to change any component's meaning"
        )

        let widget = try planner.plan(
            host: HostClass(kind: .widgetExtension, tier: .constrained),
            purpose: .timelineRefresh,
            catalog: catalog
        )
        // Exact figures rather than "fits", which the planner guarantees by
        // construction — a plan that did not fit would have been refused, so
        // asserting that it fits asserts nothing.
        XCTAssertEqual(widget.headroomBytes, ByteCount(megabytes: 17))
        XCTAssertEqual(widget.steadyStateBytes, ByteCount(kilobytes: 6_656))
        XCTAssertEqual(widget.selections.count, 3)
        XCTAssertEqual(widget.degradations.map(\.component), [ExampleCatalog.ID.contentIndex])
        XCTAssertLessThan(
            widget.steadyStateBytes, app.steadyStateBytes,
            "the same catalog must cost less inside a widget than inside the app"
        )
    }

    /// A resident component that the ladder drops to `.absent` is torn down, so
    /// its teardown buffer belongs in the reserved peak. Charging only the
    /// activation phase under-predicts — the one direction this library treats
    /// as unacceptable.
    func testTeardownOfADroppedCandidateIsChargedToTheReservedPeak() throws {
        let planner = ResidencyPlanner(budgets: Fixture.budgets(headroomMB: 60))
        let catalog = try Fixture.catalog([
            Fixture.declaration("cache", .optional, floor: .full, [
                Fixture.profile(.full, residentMB: 40, teardownMB: 12)
            ]),
            Fixture.declaration("core", .required, floor: .full, [
                Fixture.profile(.full, residentMB: 30)
            ]),
        ])
        // 40 + 30 = 70 > 60, so `cache` is dropped and torn down.
        let resident = [Fixture.resident("cache", residentMB: 40, teardownMB: 12)]

        let plan = try planner.plan(
            host: Fixture.host,
            purpose: .fullExperience,
            catalog: catalog,
            resident: resident
        )

        XCTAssertEqual(plan.evictions.map(\.id), [ComponentID("cache")])
        XCTAssertEqual(plan.steadyStateBytes, ByteCount(megabytes: 30))
        XCTAssertEqual(
            plan.reservedPeakBytes, ByteCount(megabytes: 52),
            "40 MB still resident + 12 MB flush buffer, which is worse than the 30 MB settled state"
        )
    }

    /// Evictions come back ordered by bytes reclaimed per unit of rebuild cost,
    /// not by id — so a caller that has to stop early has banked the best wins.
    func testEvictionsAreOrderedByBenefitNotAlphabetically() throws {
        let planner = ResidencyPlanner(budgets: Fixture.budgets(headroomMB: 200))
        let catalog = try Fixture.catalog([])
        let resident = [
            // Alphabetically first, but 10 MB net for 10 units of rebuild.
            Fixture.resident("aaa-cheap-bytes", residentMB: 12, teardownMB: 2, rebuildCost: 10),
            // Alphabetically last, and 40 MB net for 1 unit of rebuild.
            Fixture.resident("zzz-best-value", residentMB: 44, teardownMB: 4, rebuildCost: 1),
        ]

        let plan = try planner.plan(
            host: Fixture.host,
            purpose: .fullExperience,
            catalog: catalog,
            resident: resident
        )

        XCTAssertEqual(
            plan.evictions.map(\.id),
            [ComponentID("zzz-best-value"), ComponentID("aaa-cheap-bytes")]
        )
    }

    func testTheAppPlanRetainsTheJournalItCannotAffordToFlush() throws {
        let planner = ResidencyPlanner(budgets: .illustrative)
        let catalog = ExampleCatalog.make()

        // The journal is resident, but is not a candidate for a widget refresh.
        let journal = Fixture.resident(
            ExampleCatalog.ID.syncJournal.rawValue,
            residentMB: 18,
            teardownMB: 20
        )
        let plan = try planner.plan(
            host: HostClass(kind: .application, tier: .standard),
            purpose: .timelineRefresh,
            catalog: catalog,
            resident: [journal]
        )

        XCTAssertEqual(plan.retained.map(\.id), [ExampleCatalog.ID.syncJournal])
        XCTAssertTrue(plan.evictions.isEmpty)
    }
}
