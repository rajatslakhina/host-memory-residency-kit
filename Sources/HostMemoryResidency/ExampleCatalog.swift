import Foundation

/// A worked example of a shared domain core, sized so the interesting cases are
/// reachable rather than theoretical.
///
/// Every number here is illustrative. The point is not the numbers, it is that
/// the shape of the catalog — requirement, meaning floor, activation peak,
/// teardown peak — is what a real team would have to fill in, and that filling
/// it in is a design conversation rather than a measurement task.
public enum ExampleCatalog {

    public enum ID {
        public static let identitySession = ComponentID("identity-session")
        public static let entitlementEvaluator = ComponentID("entitlement-evaluator")
        public static let contentIndex = ComponentID("content-index")
        public static let imageDecodeCache = ComponentID("image-decode-cache")
        public static let analyticsBuffer = ComponentID("analytics-buffer")
        public static let onDeviceEmbedder = ComponentID("on-device-embedder")
        public static let syncJournal = ComponentID("sync-journal")
    }

    private static let everywhere: Set<HostPurpose> = Set(HostPurpose.allCases)

    /// One-line rationale per component, for the demo UI and for anyone reading
    /// the catalog cold.
    public static func rationale(for id: ComponentID) -> String {
        switch id {
        case ID.identitySession:
            return "Who the user is. Required everywhere; the minimal tier keeps the token but drops the cached profile."
        case ID.entitlementEvaluator:
            return "Required, and its meaning floor is 'reduced'. Below that it answers from a stale snapshot — a wrong answer, not a smaller one."
        case ID.contentIndex:
            return "Degradable. Below 'reduced' it searches titles only, which changes what a search means. Allowed, but recorded."
        case ID.imageDecodeCache:
            return "Optional and by far the largest. First thing a widget gives up; its activation peak is the decode buffer."
        case ID.analyticsBuffer:
            return "Optional. Cheap enough that dropping it saves nothing worth having."
        case ID.onDeviceEmbedder:
            return "Meaning floor is 'full': a more heavily quantised model returns different neighbours, so a lower tier is a declared behaviour change."
        case ID.syncJournal:
            return "Teardown costs more than it frees — flushing needs a bigger buffer than the journal occupies. Evicting it raises the peak, so the planner refuses to."
        default:
            return "—"
        }
    }

    /// The catalog. Force-unwrap-free: the declarations are validated at call
    /// time and a construction failure returns an empty catalog rather than
    /// trapping, because a library type that crashes a widget on access is the
    /// exact failure this package exists to prevent.
    public static func make() -> ComponentCatalog {
        (try? ComponentCatalog(declarations)) ?? .empty
    }

    /// Available so a caller can surface a malformed catalog instead of
    /// silently getting an empty one.
    public static func makeThrowing() throws -> ComponentCatalog {
        try ComponentCatalog(declarations)
    }

    public static let declarations: [ComponentDeclaration] = [

        ComponentDeclaration(
            id: ID.identitySession,
            requirement: .required,
            purposes: everywhere,
            meaningFloor: .minimal,
            profiles: [
                FidelityProfile(
                    fidelity: .full,
                    residentBytes: ByteCount(kilobytes: 6_144),
                    activationPeakBytes: ByteCount(kilobytes: 1_024),
                    teardownPeakBytes: ByteCount(kilobytes: 128),
                    rebuildCost: 3
                ),
                FidelityProfile(
                    fidelity: .minimal,
                    residentBytes: ByteCount(kilobytes: 1_536),
                    activationPeakBytes: ByteCount(kilobytes: 256),
                    teardownPeakBytes: ByteCount(kilobytes: 64),
                    rebuildCost: 3
                ),
            ]
        ),

        ComponentDeclaration(
            id: ID.entitlementEvaluator,
            requirement: .required,
            purposes: everywhere,
            meaningFloor: .reduced,
            profiles: [
                FidelityProfile(
                    fidelity: .full,
                    residentBytes: ByteCount(kilobytes: 4_096),
                    activationPeakBytes: ByteCount(kilobytes: 1_024),
                    rebuildCost: 4
                ),
                FidelityProfile(
                    fidelity: .reduced,
                    residentBytes: ByteCount(kilobytes: 2_048),
                    activationPeakBytes: ByteCount(kilobytes: 512),
                    rebuildCost: 4
                ),
                FidelityProfile(
                    fidelity: .minimal,
                    residentBytes: ByteCount(kilobytes: 640),
                    activationPeakBytes: ByteCount(kilobytes: 192),
                    rebuildCost: 4
                ),
            ]
        ),

        ComponentDeclaration(
            id: ID.contentIndex,
            requirement: .degradable,
            purposes: [.fullExperience, .timelineRefresh, .intentExecution],
            meaningFloor: .reduced,
            profiles: [
                FidelityProfile(
                    fidelity: .full,
                    residentBytes: ByteCount(kilobytes: 40_960),
                    activationPeakBytes: ByteCount(kilobytes: 10_240),
                    teardownPeakBytes: ByteCount(kilobytes: 512),
                    rebuildCost: 8
                ),
                FidelityProfile(
                    fidelity: .reduced,
                    residentBytes: ByteCount(kilobytes: 12_288),
                    activationPeakBytes: ByteCount(kilobytes: 3_072),
                    teardownPeakBytes: ByteCount(kilobytes: 256),
                    rebuildCost: 6
                ),
                FidelityProfile(
                    fidelity: .minimal,
                    residentBytes: ByteCount(kilobytes: 3_072),
                    activationPeakBytes: ByteCount(kilobytes: 1_024),
                    rebuildCost: 4
                ),
            ]
        ),

        ComponentDeclaration(
            id: ID.imageDecodeCache,
            requirement: .optional,
            purposes: [.fullExperience, .shareIngest, .timelineRefresh],
            meaningFloor: .reduced,
            profiles: [
                FidelityProfile(
                    fidelity: .full,
                    residentBytes: ByteCount(kilobytes: 98_304),
                    activationPeakBytes: ByteCount(kilobytes: 24_576),
                    teardownPeakBytes: ByteCount(kilobytes: 1_024),
                    rebuildCost: 2
                ),
                FidelityProfile(
                    fidelity: .reduced,
                    residentBytes: ByteCount(kilobytes: 24_576),
                    activationPeakBytes: ByteCount(kilobytes: 8_192),
                    teardownPeakBytes: ByteCount(kilobytes: 512),
                    rebuildCost: 2
                ),
                FidelityProfile(
                    fidelity: .minimal,
                    residentBytes: ByteCount(kilobytes: 6_144),
                    activationPeakBytes: ByteCount(kilobytes: 2_048),
                    rebuildCost: 2
                ),
            ]
        ),

        ComponentDeclaration(
            id: ID.analyticsBuffer,
            requirement: .optional,
            purposes: everywhere,
            meaningFloor: .minimal,
            profiles: [
                FidelityProfile(
                    fidelity: .full,
                    residentBytes: ByteCount(kilobytes: 2_048),
                    activationPeakBytes: ByteCount(kilobytes: 192),
                    rebuildCost: 1
                ),
                FidelityProfile(
                    fidelity: .minimal,
                    residentBytes: ByteCount(kilobytes: 384),
                    activationPeakBytes: ByteCount(kilobytes: 64),
                    rebuildCost: 1
                ),
            ]
        ),

        ComponentDeclaration(
            id: ID.onDeviceEmbedder,
            requirement: .degradable,
            purposes: [.fullExperience, .intentExecution],
            meaningFloor: .full,
            profiles: [
                FidelityProfile(
                    fidelity: .full,
                    residentBytes: ByteCount(kilobytes: 184_320),
                    // The mmap plus the dequantisation scratch buffer. This is
                    // the number that kills processes: the model "only" costs
                    // 180 MB resident, and loading it briefly needs 270 MB.
                    activationPeakBytes: ByteCount(kilobytes: 92_160),
                    teardownPeakBytes: ByteCount(kilobytes: 2_048),
                    rebuildCost: 10
                ),
                FidelityProfile(
                    fidelity: .reduced,
                    residentBytes: ByteCount(kilobytes: 49_152),
                    activationPeakBytes: ByteCount(kilobytes: 24_576),
                    teardownPeakBytes: ByteCount(kilobytes: 1_024),
                    rebuildCost: 8
                ),
                FidelityProfile(
                    fidelity: .minimal,
                    residentBytes: ByteCount(kilobytes: 12_288),
                    activationPeakBytes: ByteCount(kilobytes: 6_144),
                    rebuildCost: 6
                ),
            ]
        ),

        ComponentDeclaration(
            id: ID.syncJournal,
            requirement: .required,
            purposes: [.fullExperience],
            meaningFloor: .reduced,
            profiles: [
                FidelityProfile(
                    fidelity: .full,
                    residentBytes: ByteCount(kilobytes: 18_432),
                    activationPeakBytes: ByteCount(kilobytes: 4_096),
                    // Larger than the resident size on purpose: flushing the
                    // journal serialises it into a fresh buffer before the
                    // original can be released.
                    teardownPeakBytes: ByteCount(kilobytes: 20_480),
                    rebuildCost: 9
                ),
                FidelityProfile(
                    fidelity: .reduced,
                    residentBytes: ByteCount(kilobytes: 6_144),
                    activationPeakBytes: ByteCount(kilobytes: 1_536),
                    teardownPeakBytes: ByteCount(kilobytes: 7_168),
                    rebuildCost: 9
                ),
            ]
        ),
    ]
}
