import Foundation

/// How components are brought up.
///
/// This is the single most dangerous knob in the API, so it is explicit rather
/// than inferred. Under `.sequential` the transient activation cost of one
/// component is released before the next one starts, so the peak carries a
/// single activation. Under `.concurrent` every activation is in flight at
/// once and the peaks add.
///
/// The default is `.sequential` because that is what a loader written as a
/// `for` loop actually does. A caller who activates inside a `TaskGroup` and
/// leaves this at the default has told the planner a specific lie, and the
/// planner will authorise work the process cannot afford. `BudgetAudit` exists
/// largely to catch exactly this class of mistake in the field.
public enum ActivationModel: String, Sendable, Hashable, CaseIterable, Codable {
    case sequential
    case concurrent
}

/// One component's place in a plan.
public struct ResidencySelection: Sendable, Hashable, Identifiable {
    public let id: ComponentID
    public let fidelity: Fidelity
    public let residentBytes: ByteCount
    public let activationPeakBytes: ByteCount
    /// `false` when this selection sits below the component's declared meaning
    /// floor. Never inferred — see `DegradationRecord`.
    public let meaningPreserved: Bool
    /// `true` when the component is already resident at this exact fidelity and
    /// therefore pays no activation cost in this plan.
    public let alreadyResident: Bool

    /// Public so a consumer can build a synthetic plan and unit-test their own
    /// code against this library without reaching for a real catalog.
    public init(
        id: ComponentID,
        fidelity: Fidelity,
        residentBytes: ByteCount,
        activationPeakBytes: ByteCount,
        meaningPreserved: Bool,
        alreadyResident: Bool
    ) {
        self.id = id
        self.fidelity = fidelity
        self.residentBytes = residentBytes
        self.activationPeakBytes = activationPeakBytes
        self.meaningPreserved = meaningPreserved
        self.alreadyResident = alreadyResident
    }
}

/// A component the plan gives back.
public struct EvictionDecision: Sendable, Hashable, Identifiable {
    public let id: ComponentID
    public let residentBytes: ByteCount
    public let teardownPeakBytes: ByteCount
    public let netReclaim: ByteCount
    /// Relative cost of bringing this component back. Evictions are ordered by
    /// bytes reclaimed per unit of rebuild cost, so the cheapest-to-rebuild wins
    /// go first and a caller that has to stop early has already banked the best
    /// of them.
    public let rebuildCost: Int

    public init(
        id: ComponentID,
        residentBytes: ByteCount,
        teardownPeakBytes: ByteCount,
        netReclaim: ByteCount,
        rebuildCost: Int
    ) {
        self.id = id
        self.residentBytes = residentBytes
        self.teardownPeakBytes = teardownPeakBytes
        self.netReclaim = netReclaim
        self.rebuildCost = Swift.max(1, rebuildCost)
    }
}

/// A component the plan *wanted* to evict and could not, because tearing it
/// down would cost more than it returns.
public struct RetainedComponent: Sendable, Hashable, Identifiable {
    public let id: ComponentID
    public let residentBytes: ByteCount
    public let teardownPeakBytes: ByteCount

    public init(id: ComponentID, residentBytes: ByteCount, teardownPeakBytes: ByteCount) {
        self.id = id
        self.residentBytes = residentBytes
        self.teardownPeakBytes = teardownPeakBytes
    }
}

/// A declared, auditable change of meaning.
public struct DegradationRecord: Sendable, Hashable, Identifiable {
    public var id: ComponentID { component }
    public let component: ComponentID
    public let from: Fidelity
    public let to: Fidelity
    public let meaningFloor: Fidelity

    public init(component: ComponentID, from: Fidelity, to: Fidelity, meaningFloor: Fidelity) {
        self.component = component
        self.from = from
        self.to = to
        self.meaningFloor = meaningFloor
    }
}

/// The output of planning: what may be resident, at what fidelity, and what
/// the peak footprint of getting there will be.
public struct ResidencyPlan: Sendable, Hashable {
    public let host: HostClass
    public let purpose: HostPurpose
    public let pressure: MemoryPressureLevel
    public let activationModel: ActivationModel

    public let selections: [ResidencySelection]
    public let evictions: [EvictionDecision]
    public let retained: [RetainedComponent]
    public let degradations: [DegradationRecord]

    /// Bytes held once everything has settled.
    public let steadyStateBytes: ByteCount
    /// Bytes that must be available at the worst instant of executing this
    /// plan — the larger of the teardown phase and the activation phase. This,
    /// not `steadyStateBytes`, is what gets reserved.
    public let reservedPeakBytes: ByteCount
    public let headroomBytes: ByteCount

    public init(
        host: HostClass,
        purpose: HostPurpose,
        pressure: MemoryPressureLevel,
        activationModel: ActivationModel,
        selections: [ResidencySelection],
        evictions: [EvictionDecision],
        retained: [RetainedComponent],
        degradations: [DegradationRecord],
        steadyStateBytes: ByteCount,
        reservedPeakBytes: ByteCount,
        headroomBytes: ByteCount
    ) {
        self.host = host
        self.purpose = purpose
        self.pressure = pressure
        self.activationModel = activationModel
        self.selections = selections
        self.evictions = evictions
        self.retained = retained
        self.degradations = degradations
        self.steadyStateBytes = steadyStateBytes
        self.reservedPeakBytes = reservedPeakBytes
        self.headroomBytes = headroomBytes
    }

    /// Fraction of headroom the peak consumes, in percent, computed without
    /// dividing by a possibly-zero headroom.
    public var peakUtilisationPercent: Int {
        guard headroomBytes.rawValue > 0 else { return 100 }
        return Swift.min(100, reservedPeakBytes.rawValue / Swift.max(1, headroomBytes.rawValue / 100))
    }

    public func selection(for id: ComponentID) -> ResidencySelection? {
        selections.first { $0.id == id }
    }
}

/// Why a plan could not be produced.
///
/// Refusal is the point. Jetsam cannot be caught, so declining to start is the
/// only control this layer has; every one of these cases is a place where the
/// alternative would have been to authorise work that gets the process killed.
public enum PlanRefusal: Error, Sendable, Hashable, CustomStringConvertible {
    /// The budget table has no entry and no floor to fall back to.
    case noBudgetForHost(HostClass)
    /// Even at its meaning floor, a required component does not fit.
    case requiredComponentDoesNotFit(ComponentID, needed: ByteCount, headroom: ByteCount)
    /// Everything droppable has been dropped and it still does not fit.
    case headroomExhausted(needed: ByteCount, headroom: ByteCount)
    /// The process is already holding so much that it cannot even afford the
    /// transient cost of letting go. Counter-intuitive and real: freeing memory
    /// is not free, and a process can be too tight to shrink.
    case cannotAffordTeardown(needed: ByteCount, headroom: ByteCount)

    public var description: String {
        switch self {
        case .noBudgetForHost(let host):
            return "no budget available for host \(host)"
        case .requiredComponentDoesNotFit(let id, let needed, let headroom):
            return "cannot give up required component '\(id)': cheapest permitted configuration peaks at \(needed), headroom is \(headroom)"
        case .headroomExhausted(let needed, let headroom):
            return "plan needs \(needed) at peak, headroom is \(headroom)"
        case .cannotAffordTeardown(let needed, let headroom):
            return "teardown alone peaks at \(needed), headroom is \(headroom)"
        }
    }
}

/// Turns `(host, purpose, catalog, current residency)` into a plan.
///
/// A pure value type with no storage of its own beyond configuration, so it is
/// trivially `Sendable`, trivially testable, and callable from inside an actor
/// without an `await` — which is what lets `ResidencyCoordinator` keep its
/// check-and-reserve step free of suspension points.
public struct ResidencyPlanner: Sendable {

    /// Belt-and-braces bound on the reduction ladder.
    ///
    /// The ladder provably terminates: the catalog rejects non-monotonic costs,
    /// so every step strictly reduces steady-state bytes, and there are finitely
    /// many declared fidelities. The cap exists anyway because an unbounded
    /// `while` inside a memory-pressure handler is the kind of thing that turns
    /// a bad afternoon into an incident, and the cost of the guard is nothing.
    private static let maximumLadderSteps = 4_096

    public let budgets: HostBudgetTable
    public let pressurePolicy: PressurePolicy

    public init(budgets: HostBudgetTable, pressurePolicy: PressurePolicy = .default) {
        self.budgets = budgets
        self.pressurePolicy = pressurePolicy
    }

    /// Typed throws: the only thing this can fail with is a `PlanRefusal`, and
    /// saying so in the signature means callers never need an unreachable
    /// `catch` branch to satisfy the compiler.
    public func plan(
        host: HostClass,
        purpose: HostPurpose,
        catalog: ComponentCatalog,
        resident: [ResidentComponent] = [],
        activationModel: ActivationModel = .sequential,
        pressure: MemoryPressureLevel = .normal
    ) throws(PlanRefusal) -> ResidencyPlan {

        guard let rawBudget = budgets.budget(for: host) else {
            throw PlanRefusal.noBudgetForHost(host)
        }
        let budget = rawBudget.underPressure(pressure, policy: pressurePolicy)
        let headroom = budget.headroom

        let residentByID = Dictionary(resident.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let candidates = catalog.components(for: purpose)
        let candidateIDs = Set(candidates.map(\.id))

        // ── Teardown feasibility, checked once against the worst case ────────
        //
        // Everything currently resident but not a candidate for this purpose is
        // eligible for eviction. The instantaneous cost of that eviction is
        // bounded above by "everything tracked is still resident, plus the
        // largest single teardown buffer". That bound does not depend on which
        // fidelities the ladder later settles on, so checking it here — before
        // any ladder work — is both cheaper and easier to reason about than
        // re-checking it at every step.
        let allResidentBytes = ByteCount.sum(resident.map(\.residentBytes))
        // Every net-positive resident component is a *possible* eviction: a
        // component that is a candidate for this purpose can still be laddered
        // to `.absent` and torn down. Bounding over all of them rather than only
        // over non-candidates is deliberately conservative — the alternative
        // under-charges the peak, which is the one direction this library
        // treats as unacceptable. Net-negative ones are never torn down, so
        // charging their teardown buffer would refuse plans over a cost that
        // will never be paid.
        let evictable = resident.filter(\.evictionIsNetPositive)
        let teardownTerm = transientTerm(
            evictable.map(\.teardownPeakBytes),
            model: activationModel
        )
        let teardownPeak = allResidentBytes + teardownTerm
        if !evictable.isEmpty, teardownPeak > headroom {
            throw PlanRefusal.cannotAffordTeardown(needed: teardownPeak, headroom: headroom)
        }

        // ── Feasibility floor ────────────────────────────────────────────────
        //
        // The cheapest configuration the requirements permit. If even this does
        // not fit, no amount of laddering will help, and computing it up front
        // buys a precise refusal instead of "ran out of options".
        var floorState: [ComponentID: Fidelity] = [:]
        for component in candidates {
            floorState[component.id] = component.lowestPermittedFidelity
        }
        let floorCost = cost(
            state: floorState,
            candidates: candidates,
            residentByID: residentByID,
            retainedBytes: retainedBytes(resident: resident, candidateIDs: candidateIDs, state: floorState),
            model: activationModel
        )
        if floorCost.peak > headroom {
            if let culprit = mostExpensiveRequired(candidates, state: floorState) {
                // `needed` is the whole floor configuration's peak, not the
                // culprit's own size. The culprit names *what* cannot be given
                // up; the peak explains *why* there is no room for it, which is
                // often a retained component's tax rather than its own bulk.
                throw PlanRefusal.requiredComponentDoesNotFit(
                    culprit.id,
                    needed: floorCost.peak,
                    headroom: headroom
                )
            }
            throw PlanRefusal.headroomExhausted(needed: floorCost.peak, headroom: headroom)
        }

        // ── Reduction ladder ─────────────────────────────────────────────────
        //
        // Start rich, step down. The order of the three phases is a policy
        // choice, stated rather than buried: meaning-preserving reductions
        // everywhere first, then sanctioned removal of optional components,
        // then — last — reductions that change what a component means.
        //
        // The rejected alternative was "drop optional components first, since
        // they are explicitly expendable". That produces smaller plans faster,
        // but it throws away a whole feature while a different component is
        // still sitting at `full` purely because nobody looked at it. Losing a
        // feature should cost more than losing resolution.
        var state: [ComponentID: Fidelity] = [:]
        for component in candidates {
            state[component.id] = component.richestProfile.fidelity
        }

        var steps = 0
        var current = evaluate(state, candidates, residentByID, resident, candidateIDs, activationModel)

        while current.peak > headroom, steps < Self.maximumLadderSteps {
            steps += 1
            guard let move = nextReduction(state: state, candidates: candidates) else { break }
            state[move.component] = move.to
            current = evaluate(state, candidates, residentByID, resident, candidateIDs, activationModel)
        }

        if current.peak > headroom {
            // Unreachable given the feasibility floor above, but a planner that
            // silently returns an over-budget plan would be worse than useless,
            // so the check is real rather than an assertion.
            throw PlanRefusal.headroomExhausted(needed: current.peak, headroom: headroom)
        }

        return assemble(
            host: host,
            purpose: purpose,
            pressure: pressure,
            activationModel: activationModel,
            state: state,
            candidates: candidates,
            resident: resident,
            residentByID: residentByID,
            candidateIDs: candidateIDs,
            cost: current,
            teardownPhasePeak: teardownPeak,
            headroom: headroom
        )
    }

    // MARK: - Ladder

    private struct Reduction {
        let component: ComponentID
        let to: Fidelity
    }

    /// Picks the next single reduction, deterministically.
    ///
    /// Within a phase, the largest current resident cost goes first — the
    /// greedy choice that gets under budget in the fewest steps — with ties
    /// broken by component id so two runs over identical inputs produce
    /// identical plans. Determinism is not cosmetic here: a plan that varies
    /// run to run makes the audit trail unreadable and makes a jetsam report
    /// impossible to reproduce.
    private func nextReduction(
        state: [ComponentID: Fidelity],
        candidates: [ComponentDescriptor]
    ) -> Reduction? {
        for phase in LadderPhase.allCases {
            if let move = bestMove(state: state, candidates: candidates, phase: phase) {
                return move
            }
        }
        return nil
    }

    /// The three reduction phases, in the order they are tried.
    private enum LadderPhase: CaseIterable {
        /// Step down while staying at or above the meaning floor.
        case meaningPreserving
        /// Remove `.optional` components entirely.
        case removeOptional
        /// Step `.degradable` components below their meaning floor.
        case belowMeaningFloor
    }

    private func bestMove(
        state: [ComponentID: Fidelity],
        candidates: [ComponentDescriptor],
        phase: LadderPhase
    ) -> Reduction? {
        var best: (reduction: Reduction, bytes: ByteCount)?

        for component in candidates {
            guard let currentFidelity = state[component.id], currentFidelity != .absent else { continue }
            guard let currentProfile = component.profile(for: currentFidelity) else { continue }

            let target: Fidelity?
            switch phase {
            case .meaningPreserving:
                target = component.nextLowerFidelity(below: currentFidelity)
                    .flatMap { $0 >= component.meaningFloor ? $0 : nil }
            case .removeOptional:
                target = component.requirement == .optional ? .absent : nil
            case .belowMeaningFloor:
                target = component.nextLowerFidelity(below: currentFidelity)
                    .flatMap { $0 >= component.lowestPermittedFidelity ? $0 : nil }
            }

            guard let target, target < currentFidelity else { continue }

            // Greedy: reduce the currently most expensive component first, so
            // the ladder gets under budget in the fewest steps. Ties break on
            // component id, which is what makes the plan reproducible.
            if let incumbent = best, incumbent.bytes >= currentProfile.residentBytes { continue }
            best = (Reduction(component: component.id, to: target), currentProfile.residentBytes)
        }

        return best?.reduction
    }

    // MARK: - Costing

    private struct Cost {
        let steady: ByteCount
        let peak: ByteCount
    }

    private func evaluate(
        _ state: [ComponentID: Fidelity],
        _ candidates: [ComponentDescriptor],
        _ residentByID: [ComponentID: ResidentComponent],
        _ resident: [ResidentComponent],
        _ candidateIDs: Set<ComponentID>,
        _ model: ActivationModel
    ) -> Cost {
        cost(
            state: state,
            candidates: candidates,
            residentByID: residentByID,
            retainedBytes: retainedBytes(resident: resident, candidateIDs: candidateIDs, state: state),
            model: model
        )
    }

    /// Bytes this plan is stuck with: components that are resident, are not
    /// staying, and whose eviction would cost more than it returns. They are
    /// not in the plan and they still consume headroom, which is the whole
    /// point — a net-negative eviction is a permanent tax, not a free win.
    private func retainedBytes(
        resident: [ResidentComponent],
        candidateIDs: Set<ComponentID>,
        state: [ComponentID: Fidelity]
    ) -> ByteCount {
        ByteCount.sum(
            resident
                .filter { component in
                    let staying = candidateIDs.contains(component.id) && (state[component.id] ?? .absent) != .absent
                    return !staying && !component.evictionIsNetPositive
                }
                .map(\.residentBytes)
        )
    }

    private func cost(
        state: [ComponentID: Fidelity],
        candidates: [ComponentDescriptor],
        residentByID: [ComponentID: ResidentComponent],
        retainedBytes: ByteCount,
        model: ActivationModel
    ) -> Cost {
        var steady = retainedBytes
        var activationPeaks: [ByteCount] = []

        for component in candidates {
            let fidelity = state[component.id] ?? .absent
            guard fidelity != .absent, let profile = component.profile(for: fidelity) else { continue }
            steady = steady + profile.residentBytes

            // Already resident at exactly this fidelity means no re-activation,
            // so no transient cost. Modelling this is what stops a re-plan
            // under pressure from inventing a peak that will never happen.
            let isAlreadyResident = residentByID[component.id]?.fidelity == fidelity
            if !isAlreadyResident {
                activationPeaks.append(profile.activationPeakBytes)
            }
        }

        return Cost(steady: steady, peak: steady + transientTerm(activationPeaks, model: model))
    }

    /// Sequential activation carries one peak at a time; concurrent activation
    /// carries all of them at once.
    private func transientTerm(_ peaks: [ByteCount], model: ActivationModel) -> ByteCount {
        switch model {
        case .sequential:
            return peaks.reduce(ByteCount.zero, ByteCount.maximum)
        case .concurrent:
            return ByteCount.sum(peaks)
        }
    }

    private func mostExpensiveRequired(
        _ candidates: [ComponentDescriptor],
        state: [ComponentID: Fidelity]
    ) -> (id: ComponentID, bytes: ByteCount)? {
        var worst: (id: ComponentID, bytes: ByteCount)?
        for component in candidates where component.requirement == .required {
            let fidelity = state[component.id] ?? component.meaningFloor
            guard let profile = component.profile(for: fidelity) else { continue }
            let bytes = profile.activationCeiling
            if worst == nil || bytes > (worst?.bytes ?? .zero) {
                worst = (component.id, bytes)
            }
        }
        return worst
    }

    // MARK: - Assembly

    private func assemble(
        host: HostClass,
        purpose: HostPurpose,
        pressure: MemoryPressureLevel,
        activationModel: ActivationModel,
        state: [ComponentID: Fidelity],
        candidates: [ComponentDescriptor],
        resident: [ResidentComponent],
        residentByID: [ComponentID: ResidentComponent],
        candidateIDs: Set<ComponentID>,
        cost: Cost,
        teardownPhasePeak: ByteCount,
        headroom: ByteCount
    ) -> ResidencyPlan {

        var selections: [ResidencySelection] = []
        var degradations: [DegradationRecord] = []

        for component in candidates {
            let fidelity = state[component.id] ?? .absent
            guard fidelity != .absent, let profile = component.profile(for: fidelity) else { continue }

            let meaningPreserved = fidelity >= component.meaningFloor
            if !meaningPreserved {
                degradations.append(
                    DegradationRecord(
                        component: component.id,
                        from: component.richestProfile.fidelity,
                        to: fidelity,
                        meaningFloor: component.meaningFloor
                    )
                )
            }

            selections.append(
                ResidencySelection(
                    id: component.id,
                    fidelity: fidelity,
                    residentBytes: profile.residentBytes,
                    activationPeakBytes: profile.activationPeakBytes,
                    meaningPreserved: meaningPreserved,
                    alreadyResident: residentByID[component.id]?.fidelity == fidelity
                )
            )
        }

        var evictions: [EvictionDecision] = []
        var retained: [RetainedComponent] = []

        for component in resident {
            let staying = candidateIDs.contains(component.id) && (state[component.id] ?? .absent) != .absent
            if staying { continue }
            if component.evictionIsNetPositive {
                evictions.append(
                    EvictionDecision(
                        id: component.id,
                        residentBytes: component.residentBytes,
                        teardownPeakBytes: component.teardownPeakBytes,
                        netReclaim: component.netReclaim,
                        rebuildCost: component.rebuildCost
                    )
                )
            } else {
                retained.append(
                    RetainedComponent(
                        id: component.id,
                        residentBytes: component.residentBytes,
                        teardownPeakBytes: component.teardownPeakBytes
                    )
                )
            }
        }

        return ResidencyPlan(
            host: host,
            purpose: purpose,
            pressure: pressure,
            activationModel: activationModel,
            selections: selections.sorted { $0.id < $1.id },
            // Best benefit first: bytes reclaimed per unit of rebuild cost,
            // tie-broken on id so the order is reproducible.
            evictions: evictions.sorted { lhs, rhs in
                if ByteCount.ratioIsGreater(
                    value: lhs.netReclaim, weight: lhs.rebuildCost,
                    than: rhs.netReclaim, weight: rhs.rebuildCost
                ) { return true }
                if ByteCount.ratioIsGreater(
                    value: rhs.netReclaim, weight: rhs.rebuildCost,
                    than: lhs.netReclaim, weight: lhs.rebuildCost
                ) { return false }
                return lhs.id < rhs.id
            },
            retained: retained.sorted { $0.id < $1.id },
            degradations: degradations.sorted { $0.component < $1.component },
            steadyStateBytes: cost.steady,
            // The worst instant of executing this plan is whichever phase peaks
            // higher. Reserving only the activation phase would under-charge
            // every plan that tears something down first.
            reservedPeakBytes: evictions.isEmpty
                ? cost.peak
                : ByteCount.maximum(cost.peak, teardownPhasePeak),
            headroomBytes: headroom
        )
    }
}
