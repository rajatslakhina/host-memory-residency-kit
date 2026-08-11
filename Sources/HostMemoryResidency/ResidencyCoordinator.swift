import Foundation

/// A plan that has been admitted and has bytes reserved against it.
public struct AdmittedResidency: Sendable, Hashable {
    public let plan: ResidencyPlan
    public let reservation: ReservationLedger.Reservation

    public init(plan: ResidencyPlan, reservation: ReservationLedger.Reservation) {
        self.plan = plan
        self.reservation = reservation
    }
}

/// What happened when pressure arrived.
public enum PressureOutcome: Sendable, Hashable {
    /// The current residency still fits under the reduced headroom.
    case absorbed
    /// Fit was restored by giving up optional or degradable components.
    case sacrificed([ComponentID])
    /// Nothing droppable is left. The required set is *not* touched — see
    /// `ResidencyCoordinator.apply(pressure:)` for why.
    case cannotSatisfy(PlanRefusal)
}

/// Owns the whole loop: measure, plan, reserve, apply, audit.
///
/// ### The one suspension point
///
/// `admit` awaits exactly once — the footprint probe — and it does so *first*,
/// before reading any of this actor's state. Everything after the `await` is
/// straight-line: plan, reserve, apply. No state is captured across the
/// suspension.
///
/// That ordering is the whole reentrancy argument. Actors are reentrant, so
/// while one `admit` is suspended on the probe another can enter and run to
/// completion. Because the suspended call reads nothing until it resumes, it
/// resumes onto the *post-mutation* state and reserves against a ledger that
/// already contains the other admission. Capturing so much as the resident set
/// before the `await` would reintroduce a lost update — and would look
/// completely innocuous in review.
public actor ResidencyCoordinator {

    private let planner: ResidencyPlanner
    private let catalog: ComponentCatalog
    private let probe: any FootprintProbe

    private var ledger: ReservationLedger
    private var resident: [ComponentID: ResidentComponent] = [:]
    private var audit: BudgetAudit
    private var pressure: MemoryPressureLevel = .normal

    public init(
        planner: ResidencyPlanner,
        catalog: ComponentCatalog,
        probe: any FootprintProbe,
        auditCapacity: Int = 64,
        maximumOutstandingReservations: Int = 64
    ) {
        self.planner = planner
        self.catalog = catalog
        self.probe = probe
        self.audit = BudgetAudit(capacity: auditCapacity)
        self.ledger = ReservationLedger(
            maximumOutstandingReservations: maximumOutstandingReservations
        )
    }

    // MARK: - Introspection

    public var residentComponents: [ResidentComponent] {
        resident.values.sorted { $0.id < $1.id }
    }

    public var trackedResidentBytes: ByteCount {
        ByteCount.sum(resident.values.map(\.residentBytes))
    }

    public var currentPressure: MemoryPressureLevel { pressure }
    public var outstandingReservationBytes: ByteCount { ledger.outstandingBytes }
    public var measuredBaseline: ByteCount { ledger.measuredBaseline }
    public var auditSnapshot: BudgetAudit { audit }

    // MARK: - Admission

    /// Plans and reserves for a host and purpose.
    ///
    /// Returns a `Result` rather than throwing so the refusal is impossible to
    /// ignore with `try?`. Refusing is the normal, designed outcome here, not
    /// an exceptional one.
    public func admit(
        host: HostClass,
        purpose: HostPurpose? = nil,
        activationModel: ActivationModel = .sequential
    ) async -> Result<AdmittedResidency, PlanRefusal> {

        // The single suspension point, taken before any state is read.
        let measured = await probe.currentFootprint()

        // ---- no `await` below this line ----
        ledger.setMeasuredBaseline(measured)

        guard let rawBudget = planner.budgets.budget(for: host) else {
            return .failure(.noBudgetForHost(host))
        }
        let budget = rawBudget.underPressure(pressure, policy: planner.pressurePolicy)
        let ceiling = budget.limit - budget.safetyMargin
        let effectivePurpose = purpose ?? host.kind.defaultPurpose

        let plan: ResidencyPlan
        do {
            plan = try planner.plan(
                host: host,
                purpose: effectivePurpose,
                catalog: catalog,
                resident: residentComponents,
                activationModel: activationModel,
                pressure: pressure
            )
        } catch {
            return .failure(error)
        }

        // The planner works in modelled bytes; the ledger works in measured
        // ones. The reservation is the *additional* peak this plan introduces
        // on top of components already resident, because those are already
        // inside the measured baseline. Reserving the full modelled peak would
        // double-count them and refuse plans that comfortably fit.
        let delta = plan.reservedPeakBytes - trackedResidentBytes

        guard let reservation = ledger.reserve(peak: delta, ceiling: ceiling) else {
            let available = ceiling - ledger.measuredBaseline - ledger.outstandingBytes
            return .failure(.headroomExhausted(needed: delta, headroom: available))
        }

        apply(plan)
        lastAppliedEpoch = reservation.epoch
        return .success(AdmittedResidency(plan: plan, reservation: reservation))
    }

    /// Records what the peak really was and releases the transient claim.
    ///
    /// Steady-state bytes are deliberately *not* kept in the ledger after
    /// completion: they are real allocations now, so the next probe will see
    /// them in the measured baseline. Keeping them in both places is how a
    /// budget layer slowly convinces itself it has no room left.
    @discardableResult
    public func complete(_ admitted: AdmittedResidency, observedPeak: ByteCount) -> Bool {
        // Release first, and only record if the reservation was genuinely live.
        // Recording unconditionally would file an audit sample for work that
        // `reset()` already cancelled, quietly polluting the gate with a
        // measurement of something that never finished.
        guard ledger.release(admitted.reservation) else { return false }
        audit.record(
            AuditSample(
                host: admitted.plan.host,
                purpose: admitted.plan.purpose,
                activationModel: admitted.plan.activationModel,
                reservedPeak: admitted.plan.reservedPeakBytes,
                observedPeak: observedPeak
            )
        )
        return true
    }

    /// Abandons a plan that never finished activating. No audit sample is
    /// recorded, because there is no honest peak to compare against.
    ///
    /// Residency is only rolled back when this admission is still the most
    /// recent one applied. Under concurrent admission, admission #1 sees
    /// `alreadyResident == false` for everything and #2 sees `true`; rolling #1
    /// back after #2 landed would delete components #2 is relying on while #2's
    /// reservation stays live — the same lost-update family as the bug the
    /// suspension-point ordering exists to prevent. When the plan has been
    /// superseded the reservation is still released and `false` is returned, so
    /// the caller can tell that nothing was undone.
    @discardableResult
    public func abandon(_ admitted: AdmittedResidency) -> Bool {
        let released = ledger.release(admitted.reservation)
        guard admitted.reservation.epoch == lastAppliedEpoch else { return false }

        for selection in admitted.plan.selections where !selection.alreadyResident {
            resident.removeValue(forKey: selection.id)
        }
        lastAppliedEpoch = nil
        return released
    }

    // MARK: - Pressure

    /// Re-plans under a new pressure level.
    ///
    /// The rule this method exists to enforce: **pressure revokes headroom for
    /// new work; it never retroactively makes an already-admitted `.required`
    /// component evictable.** A required component is required because the
    /// feature is wrong without it, and that does not stop being true when the
    /// device gets busy. If the reduced headroom cannot hold the required set,
    /// the honest answer is `cannotSatisfy` — which a caller can act on by
    /// tearing down the whole feature deliberately — not a silent eviction that
    /// leaves the feature running and answering incorrectly.
    public func apply(pressure newLevel: MemoryPressureLevel) async -> PressureOutcome {
        let measured = await probe.currentFootprint()

        // ---- no `await` below this line ----
        ledger.setMeasuredBaseline(measured)
        pressure = newLevel

        guard let host = inferredHost, let purpose = inferredPurpose else { return .absorbed }

        let before = Set(resident.keys)
        let plan: ResidencyPlan
        do {
            plan = try planner.plan(
                host: host,
                purpose: purpose,
                catalog: catalog,
                resident: residentComponents,
                activationModel: .sequential,
                pressure: newLevel
            )
        } catch {
            return .cannotSatisfy(error)
        }

        apply(plan)

        let after = Set(resident.keys)
        let lost = before.subtracting(after).sorted()
        return lost.isEmpty ? .absorbed : .sacrificed(lost)
    }

    // MARK: - Audit

    public func auditVerdict(tolerancePercent: Int = 0, minimumSamples: Int = 1) -> AuditVerdict {
        audit.verdict(tolerancePercent: tolerancePercent, minimumSamples: minimumSamples)
    }

    public func reset() {
        resident.removeAll()
        ledger.revokeAll()
        audit.reset()
        pressure = .normal
        lastHost = nil
        lastPurpose = nil
        lastAppliedEpoch = nil
    }

    // MARK: - Applying a plan

    private var lastHost: HostClass?
    private var lastPurpose: HostPurpose?
    /// Epoch of the most recently applied admission, so `abandon` can tell a
    /// live plan from a superseded one.
    private var lastAppliedEpoch: UInt64?

    private var inferredHost: HostClass? { lastHost }
    private var inferredPurpose: HostPurpose? { lastPurpose }

    private func apply(_ plan: ResidencyPlan) {
        lastHost = plan.host
        lastPurpose = plan.purpose

        for eviction in plan.evictions {
            resident.removeValue(forKey: eviction.id)
        }

        for selection in plan.selections {
            guard
                let descriptor = catalog[selection.id],
                let profile = descriptor.profile(for: selection.fidelity)
            else { continue }

            resident[selection.id] = ResidentComponent(
                id: selection.id,
                fidelity: selection.fidelity,
                residentBytes: profile.residentBytes,
                teardownPeakBytes: profile.teardownPeakBytes,
                rebuildCost: profile.rebuildCost
            )
        }

        // Anything that was a candidate for this purpose and did not make the
        // plan is gone. Components retained because their eviction is
        // net-negative are, by construction, not in `plan.selections` and not
        // in `plan.evictions` — they stay in `resident` untouched, which is
        // exactly what "we could not afford to let go of it" means.
        let planned = Set(plan.selections.map(\.id))
        for descriptor in catalog.components(for: plan.purpose)
        where !planned.contains(descriptor.id) {
            if let existing = resident[descriptor.id], !existing.evictionIsNetPositive { continue }
            resident.removeValue(forKey: descriptor.id)
        }
    }
}
