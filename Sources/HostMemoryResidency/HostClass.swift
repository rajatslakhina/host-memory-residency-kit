import Foundation

/// The kind of process the shared domain core is currently running inside.
///
/// This is the axis every "shared core" design forgets. The same `Sources/`
/// directory is linked into five processes with wildly different jetsam
/// ceilings, and a cache sized for the app is a launch-time kill in a widget.
public enum HostKind: String, Sendable, Hashable, CaseIterable, Codable {
    case application
    case widgetExtension
    case intentExtension
    case notificationServiceExtension
    case shareExtension

    /// The work this host exists to do. Used to decide which components are
    /// even candidates for residency — not to decide how much memory it gets.
    public var defaultPurpose: HostPurpose {
        switch self {
        case .application: return .fullExperience
        case .widgetExtension: return .timelineRefresh
        case .intentExtension: return .intentExecution
        case .notificationServiceExtension: return .notificationMutation
        case .shareExtension: return .shareIngest
        }
    }
}

/// What the host is currently trying to accomplish.
public enum HostPurpose: String, Sendable, Hashable, CaseIterable, Codable {
    case fullExperience
    case timelineRefresh
    case intentExecution
    case notificationMutation
    case shareIngest
}

/// A coarse device memory class.
///
/// Deliberately coarse. The exact per-device jetsam limit is not a documented
/// contract and changes between OS releases, so a design that keys off an exact
/// number is encoding a number that will be wrong. Three classes is enough to
/// make the decisions that matter and few enough to actually test.
public enum DeviceMemoryTier: String, Sendable, Hashable, CaseIterable, Codable, Comparable {
    case constrained
    case standard
    case generous

    var rank: Int {
        switch self {
        case .constrained: return 0
        case .standard: return 1
        case .generous: return 2
        }
    }

    public static func < (lhs: DeviceMemoryTier, rhs: DeviceMemoryTier) -> Bool {
        lhs.rank < rhs.rank
    }
}

/// The `(process kind, device class)` pair a budget is resolved against.
public struct HostClass: Sendable, Hashable, Codable, CustomStringConvertible {
    public let kind: HostKind
    public let tier: DeviceMemoryTier

    public init(kind: HostKind, tier: DeviceMemoryTier) {
        self.kind = kind
        self.tier = tier
    }

    public var description: String { "\(kind.rawValue)/\(tier.rawValue)" }
}

/// The three numbers a residency decision is actually made from.
///
/// The important one is not `limit`. It is `headroom`, which is what is left
/// after the process's own irreducible cost and after a margin held back for
/// everything this layer does not model — framework allocations, the
/// autorelease pool, and the OS deciding to fault pages back in. Comparing new
/// work against `limit` rather than `headroom` is the single most common way a
/// budget layer authorizes work that gets the process killed.
public struct HostBudget: Sendable, Hashable, Codable {
    /// The point past which the process is expected to be terminated.
    public let limit: ByteCount
    /// Irreducible cost of being this process at all, before any tracked
    /// component is resident.
    public let baseline: ByteCount
    /// Held back for allocations this layer does not model.
    public let safetyMargin: ByteCount

    public init(limit: ByteCount, baseline: ByteCount, safetyMargin: ByteCount) {
        self.limit = limit
        self.baseline = baseline
        self.safetyMargin = safetyMargin
    }

    /// Bytes available for tracked components. Saturates at zero when the
    /// process is already over budget, which is a state this layer must be able
    /// to describe rather than crash inside.
    public var headroom: ByteCount {
        limit - baseline - safetyMargin
    }

    /// Applies memory-pressure policy by *raising the margin*, never by
    /// lowering the limit.
    ///
    /// Lowering `limit` would silently rewrite the fact the OS gave us.
    /// Raising the margin keeps the observed limit intact and makes the
    /// revocation attributable in the audit trail.
    public func underPressure(_ level: MemoryPressureLevel, policy: PressurePolicy) -> HostBudget {
        let revoked = headroom.scaled(
            numerator: policy.revokedHeadroomPercent(for: level),
            denominator: 100
        )
        return HostBudget(
            limit: limit,
            baseline: baseline,
            safetyMargin: safetyMargin + revoked
        )
    }
}

/// System memory pressure, ordered so policy can compare levels.
public enum MemoryPressureLevel: String, Sendable, Hashable, CaseIterable, Codable, Comparable {
    case normal
    case warning
    case critical

    var rank: Int {
        switch self {
        case .normal: return 0
        case .warning: return 1
        case .critical: return 2
        }
    }

    public static func < (lhs: MemoryPressureLevel, rhs: MemoryPressureLevel) -> Bool {
        lhs.rank < rhs.rank
    }
}

/// How much headroom each pressure level takes away.
///
/// Percentages, not absolute byte counts, because the same policy has to be
/// correct in a 4 GB app process and a 30 MB notification extension.
public struct PressurePolicy: Sendable, Hashable, Codable {
    public let warningRevocationPercent: Int
    public let criticalRevocationPercent: Int

    public static let `default` = PressurePolicy(
        warningRevocationPercent: 30,
        criticalRevocationPercent: 60
    )

    public init(warningRevocationPercent: Int, criticalRevocationPercent: Int) {
        // Clamped rather than asserted: a remotely-delivered policy of 400%
        // should degrade to "revoke everything", not trap.
        self.warningRevocationPercent = Swift.min(100, Swift.max(0, warningRevocationPercent))
        self.criticalRevocationPercent = Swift.min(100, Swift.max(0, criticalRevocationPercent))
    }

    func revokedHeadroomPercent(for level: MemoryPressureLevel) -> Int {
        switch level {
        case .normal: return 0
        case .warning: return warningRevocationPercent
        case .critical: return criticalRevocationPercent
        }
    }
}

/// Maps a `HostClass` to its budget.
///
/// The load-bearing property is the fallback. A table is configuration: it can
/// be shipped incomplete, or a future OS can introduce a host kind this build
/// has never seen. An unmatched lookup therefore resolves to the **smallest**
/// budget in the table, never the largest and never a permissive default.
///
/// This matters more here than in most fail-closed designs, because there is no
/// recovery path on the other side. Jetsam is not an error you can catch: there
/// is no `catch OutOfMemory`, no unwind, no retry. Refusing to start is the
/// only control this layer actually has, so guessing high is unrecoverable
/// while guessing low merely degrades.
public struct HostBudgetTable: Sendable, Hashable, Codable {
    private let entries: [HostClass: HostBudget]

    /// The most conservative budget present. Computed from the table rather
    /// than supplied, so a caller cannot configure a generous fallback.
    private let floor: HostBudget?

    public init(entries: [HostClass: HostBudget]) {
        self.entries = entries
        // Deterministic: minimum headroom, tie-broken by the host class's
        // description so two runs over the same table pick the same floor.
        self.floor = entries
            .sorted { lhs, rhs in
                if lhs.value.headroom != rhs.value.headroom {
                    return lhs.value.headroom < rhs.value.headroom
                }
                return lhs.key.description < rhs.key.description
            }
            .first?
            .value
    }

    /// Resolves a budget, falling back to the table's most conservative entry.
    /// Returns `nil` only for a genuinely empty table, which refuses every plan.
    public func budget(for host: HostClass) -> HostBudget? {
        entries[host] ?? floor
    }

    public var isEmpty: Bool { entries.isEmpty }

    /// A worked example sized to the orders of magnitude iOS actually enforces:
    /// an app process measured in gigabytes, widget and notification
    /// extensions measured in tens of megabytes.
    ///
    /// These are illustrative constants for the demo, not documented Apple
    /// limits — Apple does not publish per-process jetsam ceilings, which is
    /// itself the reason this layer is table-driven and fail-closed rather than
    /// hardcoded.
    public static let illustrative: HostBudgetTable = {
        var table: [HostClass: HostBudget] = [:]

        func put(
            _ kind: HostKind,
            _ tier: DeviceMemoryTier,
            limitMB: Int,
            baselineMB: Int,
            marginMB: Int
        ) {
            table[HostClass(kind: kind, tier: tier)] = HostBudget(
                limit: ByteCount(megabytes: limitMB),
                baseline: ByteCount(megabytes: baselineMB),
                safetyMargin: ByteCount(megabytes: marginMB)
            )
        }

        put(.application, .constrained, limitMB: 1_400, baselineMB: 120, marginMB: 140)
        put(.application, .standard, limitMB: 2_800, baselineMB: 140, marginMB: 200)
        put(.application, .generous, limitMB: 4_000, baselineMB: 150, marginMB: 240)

        put(.widgetExtension, .constrained, limitMB: 30, baselineMB: 9, marginMB: 4)
        put(.widgetExtension, .standard, limitMB: 48, baselineMB: 10, marginMB: 6)
        put(.widgetExtension, .generous, limitMB: 64, baselineMB: 10, marginMB: 8)

        put(.intentExtension, .constrained, limitMB: 48, baselineMB: 12, marginMB: 6)
        put(.intentExtension, .standard, limitMB: 96, baselineMB: 14, marginMB: 10)
        put(.intentExtension, .generous, limitMB: 128, baselineMB: 14, marginMB: 12)

        put(.notificationServiceExtension, .constrained, limitMB: 24, baselineMB: 8, marginMB: 4)
        put(.notificationServiceExtension, .standard, limitMB: 24, baselineMB: 8, marginMB: 4)
        put(.notificationServiceExtension, .generous, limitMB: 24, baselineMB: 8, marginMB: 4)

        put(.shareExtension, .constrained, limitMB: 96, baselineMB: 16, marginMB: 10)
        put(.shareExtension, .standard, limitMB: 120, baselineMB: 18, marginMB: 12)
        put(.shareExtension, .generous, limitMB: 160, baselineMB: 18, marginMB: 16)

        return HostBudgetTable(entries: table)
    }()
}
