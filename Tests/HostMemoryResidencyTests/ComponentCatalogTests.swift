import XCTest
@testable import HostMemoryResidency

final class ComponentCatalogTests: XCTestCase {

    func testDuplicateComponentIsRejected() {
        let declarations = [
            Fixture.declaration("a", .optional, floor: .full, [Fixture.profile(.full, residentMB: 1)]),
            Fixture.declaration("a", .optional, floor: .full, [Fixture.profile(.full, residentMB: 2)]),
        ]
        XCTAssertThrowsError(try Fixture.catalog(declarations)) { error in
            XCTAssertEqual(error as? CatalogError, .duplicateComponent(ComponentID("a")))
        }
    }

    func testComponentWithNoProfilesIsRejected() {
        let declarations = [Fixture.declaration("a", .optional, floor: .full, [])]
        XCTAssertThrowsError(try Fixture.catalog(declarations)) { error in
            XCTAssertEqual(error as? CatalogError, .componentHasNoProfiles(ComponentID("a")))
        }
    }

    func testDuplicateFidelityIsRejected() {
        let declarations = [
            Fixture.declaration("a", .optional, floor: .full, [
                Fixture.profile(.full, residentMB: 4),
                Fixture.profile(.full, residentMB: 2),
            ])
        ]
        XCTAssertThrowsError(try Fixture.catalog(declarations)) { error in
            XCTAssertEqual(error as? CatalogError, .duplicateFidelity(ComponentID("a"), .full))
        }
    }

    func testAbsentFidelityCannotBeDeclared() {
        let declarations = [
            Fixture.declaration("a", .optional, floor: .full, [
                Fixture.profile(.full, residentMB: 4),
                Fixture.profile(.absent, residentMB: 0),
            ])
        ]
        XCTAssertThrowsError(try Fixture.catalog(declarations)) { error in
            XCTAssertEqual(error as? CatalogError, .absentFidelityDeclared(ComponentID("a")))
        }
    }

    /// A "reduced" tier that costs as much as "full" makes every degradation
    /// step a no-op, and the ladder would spin through it doing nothing.
    /// Catching it at construction is what lets the planner's termination
    /// argument hold.
    func testNonMonotonicCostIsRejected() {
        let declarations = [
            Fixture.declaration("a", .degradable, floor: .reduced, [
                Fixture.profile(.full, residentMB: 4),
                Fixture.profile(.reduced, residentMB: 4),
            ])
        ]
        XCTAssertThrowsError(try Fixture.catalog(declarations)) { error in
            XCTAssertEqual(
                error as? CatalogError,
                .nonMonotonicCost(ComponentID("a"), lower: .reduced, higher: .full)
            )
        }
    }

    func testMeaningFloorMustBeADeclaredProfile() {
        let declarations = [
            Fixture.declaration("a", .required, floor: .minimal, [
                Fixture.profile(.full, residentMB: 4),
                Fixture.profile(.reduced, residentMB: 2),
            ])
        ]
        XCTAssertThrowsError(try Fixture.catalog(declarations)) { error in
            XCTAssertEqual(
                error as? CatalogError,
                .meaningFloorNotDeclared(ComponentID("a"), .minimal)
            )
        }
    }

    func testProfilesAreSortedRichestFirstRegardlessOfDeclarationOrder() throws {
        let catalog = try Fixture.catalog([
            Fixture.declaration("a", .degradable, floor: .minimal, [
                Fixture.profile(.minimal, residentMB: 1),
                Fixture.profile(.full, residentMB: 8),
                Fixture.profile(.reduced, residentMB: 4),
            ])
        ])
        let component = try XCTUnwrap(catalog[ComponentID("a")])
        XCTAssertEqual(component.profiles.map(\.fidelity), [.full, .reduced, .minimal])
        XCTAssertEqual(component.richestProfile.fidelity, .full)
        XCTAssertEqual(component.nextLowerFidelity(below: .full), .reduced)
        XCTAssertNil(component.nextLowerFidelity(below: .minimal))
    }

    /// The ladder's exit condition tests the *peak*, so a lower tier whose
    /// activation ceiling is not also lower could make a step down raise it.
    func testNonMonotonicActivationCeilingIsRejected() {
        let declarations = [
            Fixture.declaration("a", .degradable, floor: .reduced, [
                FidelityProfile(
                    fidelity: .full,
                    residentBytes: ByteCount(megabytes: 10),
                    activationPeakBytes: ByteCount(megabytes: 1)
                ),
                FidelityProfile(
                    fidelity: .reduced,
                    residentBytes: ByteCount(megabytes: 8),
                    activationPeakBytes: ByteCount(megabytes: 40)
                ),
            ])
        ]
        XCTAssertThrowsError(try Fixture.catalog(declarations)) { error in
            XCTAssertEqual(
                error as? CatalogError,
                .nonMonotonicCost(ComponentID("a"), lower: .reduced, higher: .full)
            )
        }
    }

    /// `Decodable` on a public type is a second constructor. It must enforce the
    /// same invariants, or every "by construction" claim downstream is false.
    func testDecodingAComponentDescriptorEnforcesTheSameInvariants() throws {
        let valid = try XCTUnwrap(ExampleCatalog.make()[ExampleCatalog.ID.contentIndex])

        // Take a genuinely valid payload and break exactly one invariant, so the
        // test cannot pass merely because the JSON was malformed.
        var raw = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(valid)) as? [String: Any]
        )
        raw["profiles"] = [Any]()
        let gutted = try JSONSerialization.data(withJSONObject: raw)

        XCTAssertThrowsError(try JSONDecoder().decode(ComponentDescriptor.self, from: gutted)) { error in
            XCTAssertEqual(
                error as? CatalogError,
                .componentHasNoProfiles(ExampleCatalog.ID.contentIndex)
            )
        }

        let round = try JSONDecoder().decode(
            ComponentDescriptor.self,
            from: JSONEncoder().encode(valid)
        )
        XCTAssertEqual(round, valid)
    }

    func testDecodingAPressurePolicyClampsOutOfRangeValues() throws {
        let policy = try JSONDecoder().decode(
            PressurePolicy.self,
            from: Data(#"{"warningRevocationPercent":400,"criticalRevocationPercent":-20}"#.utf8)
        )
        XCTAssertEqual(policy.warningRevocationPercent, 100)
        XCTAssertEqual(policy.criticalRevocationPercent, 0)
    }

    /// The fail-closed floor is a stored property, so synthesized decoding would
    /// let a crafted payload supply a generous one.
    func testDecodingABudgetTableRecomputesTheFailClosedFloor() throws {
        let table = HostBudgetTable(entries: [
            HostClass(kind: .application, tier: .generous): HostBudget(
                limit: ByteCount(megabytes: 4_000), baseline: .zero, safetyMargin: .zero
            ),
            HostClass(kind: .widgetExtension, tier: .constrained): HostBudget(
                limit: ByteCount(megabytes: 30), baseline: .zero, safetyMargin: .zero
            ),
        ])
        let round = try JSONDecoder().decode(
            HostBudgetTable.self,
            from: JSONEncoder().encode(table)
        )
        let unlisted = HostClass(kind: .shareExtension, tier: .generous)
        XCTAssertEqual(round.budget(for: unlisted)?.limit, ByteCount(megabytes: 30))
    }

    func testEmptyCatalogIsValidAndSelectsNothing() throws {
        let catalog = try Fixture.catalog([])
        XCTAssertTrue(catalog.isEmpty)
        XCTAssertTrue(catalog.components(for: .fullExperience).isEmpty)
        XCTAssertEqual(catalog, ComponentCatalog.empty)
    }

    func testLowestPermittedFidelityFollowsRequirement() throws {
        let catalog = try Fixture.catalog([
            Fixture.declaration("req", .required, floor: .reduced, [
                Fixture.profile(.full, residentMB: 8),
                Fixture.profile(.reduced, residentMB: 4),
                Fixture.profile(.minimal, residentMB: 1),
            ]),
            Fixture.declaration("deg", .degradable, floor: .reduced, [
                Fixture.profile(.full, residentMB: 8),
                Fixture.profile(.reduced, residentMB: 4),
                Fixture.profile(.minimal, residentMB: 1),
            ]),
            Fixture.declaration("opt", .optional, floor: .reduced, [
                Fixture.profile(.full, residentMB: 8),
                Fixture.profile(.reduced, residentMB: 4),
            ]),
        ])

        XCTAssertEqual(catalog[ComponentID("req")]?.lowestPermittedFidelity, .reduced)
        XCTAssertEqual(catalog[ComponentID("deg")]?.lowestPermittedFidelity, .minimal)
        XCTAssertEqual(catalog[ComponentID("opt")]?.lowestPermittedFidelity, .absent)
    }

    func testExampleCatalogIsWellFormed() throws {
        // The shipped example is validated by the same rules as user input.
        // If it stops satisfying them, this fails rather than silently
        // returning `.empty` and making every demo screen look broken.
        let catalog = try ExampleCatalog.makeThrowing()
        XCTAssertEqual(catalog.components.count, ExampleCatalog.declarations.count)
        XCTAssertFalse(ExampleCatalog.make().isEmpty)
    }

    func testEvictionNetPositivityIsDecidedByTeardownCost() {
        let cheapToDrop = Fixture.resident("a", residentMB: 50, teardownMB: 10)
        let expensiveToDrop = Fixture.resident("b", residentMB: 50, teardownMB: 60)
        let breakEven = Fixture.resident("c", residentMB: 50, teardownMB: 50)

        XCTAssertTrue(cheapToDrop.evictionIsNetPositive)
        XCTAssertEqual(cheapToDrop.netReclaim, ByteCount(megabytes: 40))

        XCTAssertFalse(expensiveToDrop.evictionIsNetPositive)
        XCTAssertEqual(expensiveToDrop.netReclaim, .zero)

        // Break-even is treated as net-negative: paying a transient spike for
        // zero gain is strictly worse than doing nothing.
        XCTAssertFalse(breakEven.evictionIsNetPositive)
    }
}
