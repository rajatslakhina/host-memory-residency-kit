import XCTest
@testable import HostMemoryResidency

enum Fixture {

    static let host = HostClass(kind: .application, tier: .standard)

    static func profile(
        _ fidelity: Fidelity,
        residentMB: Int,
        activationMB: Int = 0,
        teardownMB: Int = 0,
        rebuildCost: Int = 1
    ) -> FidelityProfile {
        FidelityProfile(
            fidelity: fidelity,
            residentBytes: ByteCount(megabytes: residentMB),
            activationPeakBytes: ByteCount(megabytes: activationMB),
            teardownPeakBytes: ByteCount(megabytes: teardownMB),
            rebuildCost: rebuildCost
        )
    }

    static func declaration(
        _ id: String,
        _ requirement: ComponentRequirement,
        floor: Fidelity,
        purposes: Set<HostPurpose> = [.fullExperience],
        _ profiles: [FidelityProfile]
    ) -> ComponentDeclaration {
        ComponentDeclaration(
            id: ComponentID(id),
            requirement: requirement,
            purposes: purposes,
            meaningFloor: floor,
            profiles: profiles
        )
    }

    /// A single-entry budget table with exact, easy-to-reason-about numbers.
    static func budgets(
        headroomMB: Int,
        baselineMB: Int = 0,
        marginMB: Int = 0,
        host: HostClass = Fixture.host
    ) -> HostBudgetTable {
        HostBudgetTable(entries: [
            host: HostBudget(
                limit: ByteCount(megabytes: headroomMB + baselineMB + marginMB),
                baseline: ByteCount(megabytes: baselineMB),
                safetyMargin: ByteCount(megabytes: marginMB)
            )
        ])
    }

    static func resident(
        _ id: String,
        _ fidelity: Fidelity = .full,
        residentMB: Int,
        teardownMB: Int = 0,
        rebuildCost: Int = 1
    ) -> ResidentComponent {
        ResidentComponent(
            id: ComponentID(id),
            fidelity: fidelity,
            residentBytes: ByteCount(megabytes: residentMB),
            teardownPeakBytes: ByteCount(megabytes: teardownMB),
            rebuildCost: rebuildCost
        )
    }

    static func catalog(_ declarations: [ComponentDeclaration]) throws -> ComponentCatalog {
        try ComponentCatalog(declarations)
    }
}

extension XCTestCase {

    /// Asserts a specific `PlanRefusal` case, and fails loudly if the planner
    /// returned a plan instead. Written out rather than using
    /// `XCTAssertThrowsError` so the success path reports what was planned.
    func assertRefuses(
        _ expression: @autoclosure () throws -> ResidencyPlan,
        _ matches: (PlanRefusal) -> Bool,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        do {
            let plan = try expression()
            XCTFail(
                "\(message) — but a plan was produced: peak \(plan.reservedPeakBytes), "
                + "\(plan.selections.count) selections",
                file: file,
                line: line
            )
        } catch let refusal as PlanRefusal {
            XCTAssertTrue(matches(refusal), "\(message) — got \(refusal)", file: file, line: line)
        } catch {
            XCTFail("unexpected error type \(error)", file: file, line: line)
        }
    }
}
