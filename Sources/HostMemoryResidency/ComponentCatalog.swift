import Foundation

/// Stable identifier for a domain component.
public struct ComponentID: Sendable, Hashable, Codable, RawRepresentable, Comparable, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }
    public static func < (lhs: ComponentID, rhs: ComponentID) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// How much of a component is resident.
public enum Fidelity: Int, Sendable, Hashable, CaseIterable, Codable, Comparable {
    case absent = 0
    case minimal = 1
    case reduced = 2
    case full = 3

    public static func < (lhs: Fidelity, rhs: Fidelity) -> Bool { lhs.rawValue < rhs.rawValue }

    public var label: String {
        switch self {
        case .absent: return "absent"
        case .minimal: return "minimal"
        case .reduced: return "reduced"
        case .full: return "full"
        }
    }
}

/// What the planner is allowed to do to a component when it runs out of room.
///
/// This is declared per component by the team that owns it, and it is the one
/// thing the planner must not infer. Only the owner of an entitlement evaluator
/// knows that a "reduced" entitlement evaluator answering `false` is not a
/// smaller answer, it is a wrong one.
public enum ComponentRequirement: String, Sendable, Hashable, Codable, CaseIterable {
    /// May be reduced no further than `meaningFloor`. If it does not fit there,
    /// the plan is refused rather than quietly shipped without it.
    case required
    /// May be reduced below `meaningFloor` — but doing so is recorded as a
    /// declared meaning change, never applied silently.
    case degradable
    /// May be dropped entirely.
    case optional
}

/// The cost of holding one component at one fidelity.
public struct FidelityProfile: Sendable, Hashable, Codable {
    public let fidelity: Fidelity

    /// Steady-state cost once resident.
    public let residentBytes: ByteCount

    /// Transient cost *above* `residentBytes` while activating: the decode
    /// buffer, the parse tree, the copy that exists for one frame. Budgeting
    /// against steady state alone is how a process that "fits" gets killed
    /// during the load that made it fit.
    public let activationPeakBytes: ByteCount

    /// Transient cost *above* `residentBytes` while tearing down: the
    /// serialisation buffer, the flush, the snapshot written before release.
    public let teardownPeakBytes: ByteCount

    /// Relative cost of rebuilding this component after eviction. Clamped to at
    /// least 1 so it can be used as a divisor's stand-in without any division.
    public let rebuildCost: Int

    public init(
        fidelity: Fidelity,
        residentBytes: ByteCount,
        activationPeakBytes: ByteCount = .zero,
        teardownPeakBytes: ByteCount = .zero,
        rebuildCost: Int = 1
    ) {
        self.fidelity = fidelity
        self.residentBytes = residentBytes
        self.activationPeakBytes = activationPeakBytes
        self.teardownPeakBytes = teardownPeakBytes
        self.rebuildCost = Swift.max(1, rebuildCost)
    }

    /// Peak instantaneous footprint while this component is coming up.
    public var activationCeiling: ByteCount { residentBytes + activationPeakBytes }
}

/// A component of the shared domain core, described in the only terms a budget
/// layer can act on.
public struct ComponentDescriptor: Sendable, Hashable, Codable, Identifiable {
    public let id: ComponentID
    public let requirement: ComponentRequirement

    /// Which host purposes this component is a candidate for at all.
    public let purposes: Set<HostPurpose>

    /// Lowest fidelity at which this component still answers the same
    /// questions the same way. Below this line the component still runs but
    /// means something different.
    public let meaningFloor: Fidelity

    /// Declared profiles, highest fidelity first, `.absent` excluded.
    public let profiles: [FidelityProfile]

    fileprivate init(
        id: ComponentID,
        requirement: ComponentRequirement,
        purposes: Set<HostPurpose>,
        meaningFloor: Fidelity,
        profiles: [FidelityProfile]
    ) {
        self.id = id
        self.requirement = requirement
        self.purposes = purposes
        self.meaningFloor = meaningFloor
        self.profiles = profiles
    }

    /// The most expensive declared profile. Non-optional by construction:
    /// `ComponentCatalog` rejects a component with no profiles, so this is the
    /// one place in the module where a first-element access is provably safe.
    public var richestProfile: FidelityProfile {
        // Safe: `profiles` is validated non-empty by `ComponentCatalog.init`,
        // which is the only path that can construct a `ComponentDescriptor`.
        // Still written defensively so a future refactor cannot turn a
        // relaxed invariant into a crash.
        profiles.first ?? FidelityProfile(fidelity: .minimal, residentBytes: .zero)
    }

    public func profile(for fidelity: Fidelity) -> FidelityProfile? {
        profiles.first { $0.fidelity == fidelity }
    }

    /// The declared fidelity immediately below `fidelity`, or `nil` if this is
    /// already the lowest declared one.
    public func nextLowerFidelity(below fidelity: Fidelity) -> Fidelity? {
        profiles.first { $0.fidelity < fidelity }?.fidelity
    }

    /// Lowest fidelity this component may occupy given its requirement.
    /// `.required` stops at the meaning floor; `.degradable` may go below it
    /// but never to absent; `.optional` may vanish.
    public var lowestPermittedFidelity: Fidelity {
        switch requirement {
        case .required:
            // `meaningFloor` is validated to be a declared profile, and it is
            // by definition at or above the lowest declared one.
            return meaningFloor
        case .degradable:
            return profiles.last?.fidelity ?? meaningFloor
        case .optional:
            return .absent
        }
    }
}

/// Why a catalog was rejected.
public enum CatalogError: Error, Sendable, Hashable, CustomStringConvertible {
    case duplicateComponent(ComponentID)
    case componentHasNoProfiles(ComponentID)
    case duplicateFidelity(ComponentID, Fidelity)
    case absentFidelityDeclared(ComponentID)
    /// A lower fidelity that costs at least as much as a higher one. This is
    /// always a catalog bug and it silently defeats every degradation step, so
    /// it is rejected at construction rather than tolerated at runtime.
    case nonMonotonicCost(ComponentID, lower: Fidelity, higher: Fidelity)
    case meaningFloorNotDeclared(ComponentID, Fidelity)

    public var description: String {
        switch self {
        case .duplicateComponent(let id):
            return "duplicate component '\(id)'"
        case .componentHasNoProfiles(let id):
            return "component '\(id)' declares no fidelity profiles"
        case .duplicateFidelity(let id, let f):
            return "component '\(id)' declares fidelity '\(f.label)' twice"
        case .absentFidelityDeclared(let id):
            return "component '\(id)' declares an '.absent' profile; absence is modelled by omission"
        case .nonMonotonicCost(let id, let lower, let higher):
            return "component '\(id)': fidelity '\(lower.label)' does not cost less than '\(higher.label)'"
        case .meaningFloorNotDeclared(let id, let f):
            return "component '\(id)' names meaning floor '\(f.label)' but declares no such profile"
        }
    }
}

/// A validated set of component descriptors.
///
/// Validation happens once, at construction, and everything downstream is
/// allowed to rely on it. That is what lets the planner be a total function
/// over its inputs instead of a pile of defensive `guard`s.
public struct ComponentCatalog: Sendable, Hashable {
    public let components: [ComponentDescriptor]
    private let index: [ComponentID: ComponentDescriptor]

    public init(_ declarations: [ComponentDeclaration]) throws {
        var index: [ComponentID: ComponentDescriptor] = [:]
        var built: [ComponentDescriptor] = []

        for declaration in declarations {
            let id = declaration.id
            guard index[id] == nil else { throw CatalogError.duplicateComponent(id) }
            guard !declaration.profiles.isEmpty else { throw CatalogError.componentHasNoProfiles(id) }

            var seen: Set<Fidelity> = []
            for profile in declaration.profiles {
                guard profile.fidelity != .absent else { throw CatalogError.absentFidelityDeclared(id) }
                guard seen.insert(profile.fidelity).inserted else {
                    throw CatalogError.duplicateFidelity(id, profile.fidelity)
                }
            }

            // Highest fidelity first. Sorting here means the planner never has
            // to care what order a feature team wrote them in.
            let sorted = declaration.profiles.sorted { $0.fidelity > $1.fidelity }

            for (higher, lower) in zip(sorted, sorted.dropFirst()) where lower.residentBytes >= higher.residentBytes {
                throw CatalogError.nonMonotonicCost(id, lower: lower.fidelity, higher: higher.fidelity)
            }

            guard seen.contains(declaration.meaningFloor) else {
                throw CatalogError.meaningFloorNotDeclared(id, declaration.meaningFloor)
            }

            let descriptor = ComponentDescriptor(
                id: id,
                requirement: declaration.requirement,
                purposes: declaration.purposes,
                meaningFloor: declaration.meaningFloor,
                profiles: sorted
            )
            index[id] = descriptor
            built.append(descriptor)
        }

        // Deterministic iteration order regardless of declaration order, so
        // two runs over the same catalog produce byte-identical plans.
        self.components = built.sorted { $0.id < $1.id }
        self.index = index
    }

    /// The empty catalog.
    ///
    /// Built through a private non-throwing initialiser rather than
    /// `try! ComponentCatalog([])`, so this package contains no trapping path
    /// at all. Every validation failure requires at least one declaration, so
    /// there is genuinely nothing to check here.
    public static let empty = ComponentCatalog()

    private init() {
        self.components = []
        self.index = [:]
    }

    public subscript(id: ComponentID) -> ComponentDescriptor? { index[id] }

    public var isEmpty: Bool { components.isEmpty }

    /// Components eligible for a purpose, richest-first ordering preserved by id.
    public func components(for purpose: HostPurpose) -> [ComponentDescriptor] {
        components.filter { $0.purposes.contains(purpose) }
    }
}

/// The unvalidated input to `ComponentCatalog`.
public struct ComponentDeclaration: Sendable, Hashable {
    public let id: ComponentID
    public let requirement: ComponentRequirement
    public let purposes: Set<HostPurpose>
    public let meaningFloor: Fidelity
    public let profiles: [FidelityProfile]

    public init(
        id: ComponentID,
        requirement: ComponentRequirement,
        purposes: Set<HostPurpose>,
        meaningFloor: Fidelity,
        profiles: [FidelityProfile]
    ) {
        self.id = id
        self.requirement = requirement
        self.purposes = purposes
        self.meaningFloor = meaningFloor
        self.profiles = profiles
    }
}

/// A component currently held in memory, as observed rather than as planned.
public struct ResidentComponent: Sendable, Hashable {
    public let id: ComponentID
    public let fidelity: Fidelity
    public let residentBytes: ByteCount
    public let teardownPeakBytes: ByteCount
    public let rebuildCost: Int

    public init(
        id: ComponentID,
        fidelity: Fidelity,
        residentBytes: ByteCount,
        teardownPeakBytes: ByteCount = .zero,
        rebuildCost: Int = 1
    ) {
        self.id = id
        self.fidelity = fidelity
        self.residentBytes = residentBytes
        self.teardownPeakBytes = teardownPeakBytes
        self.rebuildCost = Swift.max(1, rebuildCost)
    }

    /// Whether evicting this actually reduces the instantaneous peak.
    ///
    /// The trap every "evict LRU until under budget" loop falls into: tearing a
    /// component down is not free. If flushing it needs a serialisation buffer
    /// at least as large as the bytes it gives back, the eviction *raises* the
    /// peak — precisely at the moment the process is already near its ceiling,
    /// which is the moment jetsam fires. Such an eviction must be refused, and
    /// the bytes it would have freed must keep counting against headroom.
    public var evictionIsNetPositive: Bool {
        teardownPeakBytes < residentBytes
    }

    /// Net bytes an eviction actually returns.
    public var netReclaim: ByteCount {
        evictionIsNetPositive ? residentBytes - teardownPeakBytes : .zero
    }
}
