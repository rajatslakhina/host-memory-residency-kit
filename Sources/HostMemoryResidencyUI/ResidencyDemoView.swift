#if canImport(SwiftUI)
import SwiftUI
import Observation
import HostMemoryResidency

/// Drives the demo.
///
/// Deliberately thin. Planning is a pure function, so the plan is a *computed*
/// property rather than cached state — there is no second copy of the answer to
/// drift out of sync with the pickers, and what appears on screen is the
/// library's real output rather than a UI reinterpretation of it.
@MainActor
@Observable
public final class ResidencyDemoModel {

    public var hostKind: HostKind = .widgetExtension
    public var tier: DeviceMemoryTier = .standard
    public var pressure: MemoryPressureLevel = .normal
    public var activationModel: ActivationModel = .sequential

    public private(set) var measuredFootprint: ByteCount = .zero
    public private(set) var concurrencyResult: ConcurrencyResult?

    private var audit = BudgetAudit(capacity: 32)

    private let catalog = ExampleCatalog.make()
    private let planner = ResidencyPlanner(budgets: .illustrative)

    public init() {}

    public var host: HostClass { HostClass(kind: hostKind, tier: tier) }

    public var budget: HostBudget? {
        planner.budgets.budget(for: host)?.underPressure(pressure, policy: .default)
    }

    public var planResult: Result<ResidencyPlan, PlanRefusal> {
        do {
            let plan = try planner.plan(
                host: host,
                purpose: hostKind.defaultPurpose,
                catalog: catalog,
                activationModel: activationModel,
                pressure: pressure
            )
            return .success(plan)
        } catch {
            return .failure(error)
        }
    }

    public var plan: ResidencyPlan? {
        guard case .success(let plan) = planResult else { return nil }
        return plan
    }

    public var refusal: PlanRefusal? {
        guard case .failure(let refusal) = planResult else { return nil }
        return refusal
    }

    public var auditVerdict: AuditVerdict {
        audit.verdict(tolerancePercent: 5)
    }

    /// Reads this process's real footprint. Informational only: the plan is
    /// computed against the modelled baseline in the budget table, because the
    /// demo shows what a *widget* would decide while running inside an app.
    public func refreshMeasuredFootprint() async {
        measuredFootprint = await DefaultFootprintProbe().currentFootprint()
    }

    public func recordWellBehavedActivation() { record(multiplierPercent: 90) }
    public func recordUnderPredictedActivation() { record(multiplierPercent: 140) }

    public func resetAudit() { audit.reset() }

    private func record(multiplierPercent: Int) {
        guard let plan else { return }
        audit.record(
            AuditSample(
                host: plan.host,
                purpose: plan.purpose,
                activationModel: plan.activationModel,
                reservedPeak: plan.reservedPeakBytes,
                observedPeak: plan.reservedPeakBytes.scaled(
                    numerator: multiplierPercent,
                    denominator: 100
                )
            )
        )
    }

    public struct ConcurrencyResult: Sendable, Hashable {
        public let attempts: Int
        public let admitted: Int
        public let actuallyReserved: ByteCount
        /// What the ledger would hold if each caller had reserved its own full
        /// peak — i.e. what a check-and-act across a suspension point produces.
        public let naiveReservation: ByteCount
    }

    /// Fires several admissions at one coordinator simultaneously.
    ///
    /// The interesting number is not how many are admitted — after the first
    /// one lands, the components are resident and the rest genuinely cost
    /// nothing extra. It is how much ends up *reserved*. Six callers reserve
    /// the peak once between them, because each resumes onto post-mutation
    /// state and reserves only the delta. Had the check and the reserve
    /// straddled an `await`, all six would have reserved the full peak and the
    /// ledger would read six times higher for the same work.
    public func runConcurrentAdmissions() async {
        let coordinator = ResidencyCoordinator(
            planner: planner,
            catalog: catalog,
            probe: MutableFootprintProbe(.zero)
        )
        let host = self.host
        let attempts = 6
        let singlePeak = plan?.reservedPeakBytes ?? .zero

        let outcomes = await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
            for _ in 0..<attempts {
                group.addTask {
                    if case .success = await coordinator.admit(host: host) { return true }
                    return false
                }
            }
            var collected: [Bool] = []
            for await result in group { collected.append(result) }
            return collected
        }

        let reserved = await coordinator.outstandingReservationBytes
        concurrencyResult = ConcurrencyResult(
            attempts: attempts,
            admitted: outcomes.filter { $0 }.count,
            actuallyReserved: reserved,
            naiveReservation: singlePeak * attempts
        )
    }
}

/// The demo screen.
public struct ResidencyDemoView: View {

    @State private var model = ResidencyDemoModel()

    public init() {}

    public var body: some View {
        NavigationStack {
            List {
                configurationSection
                budgetSection
                refusalSection
                planSection
                degradationSection
                retainedSection
                auditSection
                concurrencySection
                measuredSection
            }
            .navigationTitle("Host Memory Residency")
        }
        .task {
            await model.refreshMeasuredFootprint()
        }
    }

    // MARK: - Sections

    private var configurationSection: some View {
        Section {
            Picker("Host process", selection: $model.hostKind) {
                ForEach(HostKind.allCases, id: \.self) { kind in
                    Text(Self.label(for: kind)).tag(kind)
                }
            }
            Picker("Device class", selection: $model.tier) {
                ForEach(DeviceMemoryTier.allCases, id: \.self) { tier in
                    Text(tier.rawValue.capitalized).tag(tier)
                }
            }
            .pickerStyle(.segmented)
            Picker("Memory pressure", selection: $model.pressure) {
                ForEach(MemoryPressureLevel.allCases, id: \.self) { level in
                    Text(level.rawValue.capitalized).tag(level)
                }
            }
            .pickerStyle(.segmented)
            Picker("Activation", selection: $model.activationModel) {
                ForEach(ActivationModel.allCases, id: \.self) { activation in
                    Text(activation.rawValue.capitalized).tag(activation)
                }
            }
            .pickerStyle(.segmented)
        } header: {
            Text("Where is the shared core running?")
        } footer: {
            Text("The same domain code and the same catalog every time. Only the process it is loaded into changes.")
        }
    }

    @ViewBuilder
    private var budgetSection: some View {
        if let budget = model.budget {
            Section("Budget") {
                metric("Jetsam limit", budget.limit)
                metric("Modelled baseline", budget.baseline)
                metric("Safety margin", budget.safetyMargin)
                metric("Headroom", budget.headroom, emphasised: true)
                if let plan = model.plan {
                    metric("Steady state", plan.steadyStateBytes)
                    metric("Reserved peak", plan.reservedPeakBytes, emphasised: true)
                    utilisationBar(percent: plan.peakUtilisationPercent)
                }
            }
        }
    }

    @ViewBuilder
    private var refusalSection: some View {
        if let refusal = model.refusal {
            Section("Refused") {
                Label(String(describing: refusal), systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red)
                Text("Refusing is the control. Jetsam cannot be caught, so declining to start is the only lever this layer has.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var planSection: some View {
        if let plan = model.plan {
            Section {
                if plan.selections.isEmpty {
                    Text("No component in the catalog serves this purpose.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(plan.selections) { selection in
                        selectionRow(selection)
                    }
                }
            } header: {
                Text("Resident plan — \(plan.purpose.rawValue)")
            } footer: {
                Text("\(plan.selections.count) resident · \(plan.evictions.count) evicted · \(plan.retained.count) retained")
            }
        }
    }

    @ViewBuilder
    private var degradationSection: some View {
        if let plan = model.plan, !plan.degradations.isEmpty {
            Section {
                ForEach(plan.degradations) { record in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(record.component.rawValue)
                            .font(.subheadline.weight(.semibold))
                        Text("\(record.from.label) → \(record.to.label), below its \(record.meaningFloor.label) meaning floor")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            } header: {
                Label("Declared meaning changes", systemImage: "exclamationmark.triangle.fill")
            } footer: {
                Text("These components still run and no longer answer the same question. The planner may only do this because the catalog says so, and it records it rather than inferring it.")
            }
        }
    }

    @ViewBuilder
    private var retainedSection: some View {
        if let plan = model.plan, !plan.retained.isEmpty {
            Section {
                ForEach(plan.retained) { component in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(component.id.rawValue)
                            .font(.subheadline.weight(.semibold))
                        Text("\(component.residentBytes) resident · \(component.teardownPeakBytes) to tear down")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Label("Could not afford to evict", systemImage: "lock.fill")
            } footer: {
                Text("Tearing these down needs a bigger transient buffer than they give back, so evicting them would raise the peak. They keep consuming headroom — a net-negative eviction is a tax, not a win.")
            }
        }
    }

    private var auditSection: some View {
        Section {
            Text(String(describing: model.auditVerdict))
                .font(.callout.monospaced())
                .foregroundStyle(model.auditVerdict.isPass ? Color.green : Color.primary)
            Button("Record a well-behaved activation (peak 90% of model)") {
                model.recordWellBehavedActivation()
            }
            Button("Record an under-predicted activation (peak 140% of model)") {
                model.recordUnderPredictedActivation()
            }
            Button("Reset audit", role: .destructive) {
                model.resetAudit()
            }
        } header: {
            Text("Model-vs-reality gate")
        } footer: {
            Text("Only under-prediction can fail the gate. Over-prediction wastes headroom; under-prediction manufactures confidence in a plan that gets the process killed.")
        }
    }

    @ViewBuilder
    private var concurrencySection: some View {
        Section {
            Button("Fire 6 concurrent admissions") {
                Task { await model.runConcurrentAdmissions() }
            }
            if let result = model.concurrencyResult {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(result.admitted)/\(result.attempts) admitted")
                        .font(.callout.monospaced())
                    Text("reserved once: \(result.actuallyReserved)")
                        .font(.callout.monospaced())
                        .foregroundStyle(.green)
                    Text("check-then-act would hold: \(result.naiveReservation)")
                        .font(.callout.monospaced())
                        .foregroundStyle(.red)
                }
            }
        } header: {
            Text("Concurrent admission")
        } footer: {
            Text("Six callers reserve the peak once between them, because each resumes onto post-mutation state and reserves only the delta. Put an await between the check and the reserve and every caller books the full peak instead.")
        }
    }

    private var measuredSection: some View {
        Section {
            LabeledContent("phys_footprint", value: model.measuredFootprint.description)
        } header: {
            Text("This process, measured")
        } footer: {
            Text("The demo app's own footprint, read from task_vm_info. Informational — the plan above is computed against the modelled baseline for the selected host.")
        }
    }

    // MARK: - Rows

    private func selectionRow(_ selection: ResidencySelection) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(selection.id.rawValue)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(selection.fidelity.label)
                    .font(.caption.weight(.bold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        selection.meaningPreserved
                            ? Color.blue.opacity(0.15)
                            : Color.orange.opacity(0.28)
                    )
                    .clipShape(Capsule())
            }
            Text("\(selection.residentBytes) resident · +\(selection.activationPeakBytes) while loading")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(ExampleCatalog.rationale(for: selection.id))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private func metric(_ title: String, _ value: ByteCount, emphasised: Bool = false) -> some View {
        LabeledContent(title) {
            Text(value.description)
                .font(emphasised ? .body.weight(.semibold).monospaced() : .body.monospaced())
        }
    }

    private func utilisationBar(percent: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ProgressView(value: Double(min(100, max(0, percent))), total: 100)
                .tint(percent > 85 ? .red : (percent > 60 ? .orange : .green))
            Text("\(percent)% of headroom at peak")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private static func label(for kind: HostKind) -> String {
        switch kind {
        case .application: return "App"
        case .widgetExtension: return "Widget extension"
        case .intentExtension: return "Intent extension"
        case .notificationServiceExtension: return "Notification service"
        case .shareExtension: return "Share extension"
        }
    }
}

#Preview {
    ResidencyDemoView()
}
#endif
