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
