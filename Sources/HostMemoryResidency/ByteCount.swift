import Foundation

/// A non-negative byte quantity whose arithmetic saturates instead of trapping.
///
/// Memory arithmetic in a budget layer runs on adversarial input. Catalogs are
/// authored by feature teams, device limits are read from the OS, and pressure
/// policy can arrive from a remote config nobody validated. In Swift, `+`, `*`,
/// `-` on `Int` all trap on overflow and `Int(someDouble)` traps on NaN, on
/// infinity and on anything outside `Int.min ... Int.max`.
///
/// A trap inside a memory-budget check is strictly worse than a wrong budget:
/// it kills the exact process the budget exists to keep alive. `ByteCount`
/// therefore has no trapping path at all — every conversion and every operator
/// clamps into `0 ... Int.max`.
///
/// `Int` is deliberately the storage type and `Int.max` deliberately the
/// ceiling, rather than a hardcoded 64-bit literal, so the type stays correct
/// on any word size.
public struct ByteCount: Sendable, Hashable, Comparable, Codable {

    /// Zero bytes.
    public static let zero = ByteCount(rawValue: 0)

    /// The saturation ceiling, derived from `Int.max` rather than a literal.
    public static let max = ByteCount(rawValue: Int.max)

    /// The byte value, always in `0 ... Int.max`.
    public let rawValue: Int

    /// Clamps any `Int` into the representable range. Negative inputs become
    /// zero rather than being rejected: a caller subtracting a measured
    /// baseline from a limit expects "no headroom", not a thrown error.
    public init(rawValue: Int) {
        self.rawValue = Swift.max(0, rawValue)
    }

    public init(bytes: Int) {
        self.init(rawValue: bytes)
    }

    public init(kilobytes: Int) {
        self.init(rawValue: ByteCount.saturatingMultiply(kilobytes, 1_024))
    }

    public init(megabytes: Int) {
        self.init(rawValue: ByteCount.saturatingMultiply(megabytes, 1_048_576))
    }

    /// Converts a `Double` without any trapping path.
    ///
    /// All three of `Double`'s trapping cases are reachable here in practice:
    /// NaN from `0.0 / 0.0` when a caller computes a ratio against an empty
    /// catalog, `+infinity` from dividing a positive by zero, and out-of-range
    /// from scaling a large limit by a misconfigured multiplier.
    public init(approximately value: Double) {
        guard value.isFinite else {
            // NaN is not > 0, so NaN lands on zero — the conservative answer
            // for a memory budget.
            self.init(rawValue: value > 0 ? Int.max : 0)
            return
        }
        guard value > 0 else {
            self.init(rawValue: 0)
            return
        }
        // `Double(Int.max)` rounds up to exactly 2^63, so `>=` covers the
        // boundary and everything below it converts exactly.
        if value >= Double(Int.max) {
            self.init(rawValue: Int.max)
        } else {
            self.init(rawValue: Int(value))
        }
    }

    /// Decoding routes through the clamping initialiser.
    ///
    /// Synthesized `Decodable` would assign `rawValue` directly and hand back a
    /// negative `ByteCount` for `{"rawValue": -1}` — quietly falsifying the
    /// "always in `0 ... Int.max`" invariant everything downstream relies on.
    /// A budget arriving from a remote config is exactly the input this type
    /// exists to survive.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(rawValue: try container.decode(Int.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public static func < (lhs: ByteCount, rhs: ByteCount) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// Saturating addition. Never traps, never wraps.
    public static func + (lhs: ByteCount, rhs: ByteCount) -> ByteCount {
        ByteCount(rawValue: saturatingAdd(lhs.rawValue, rhs.rawValue))
    }

    /// Saturating subtraction, clamped at zero.
    ///
    /// This is the operator that makes `headroom = limit - baseline` safe when
    /// a process has already blown past its limit, which is exactly when the
    /// budget layer is most needed and least allowed to crash.
    public static func - (lhs: ByteCount, rhs: ByteCount) -> ByteCount {
        ByteCount(rawValue: saturatingSubtract(lhs.rawValue, rhs.rawValue))
    }

    /// Saturating multiplication by a non-negative scalar.
    public static func * (lhs: ByteCount, rhs: Int) -> ByteCount {
        ByteCount(rawValue: saturatingMultiply(lhs.rawValue, Swift.max(0, rhs)))
    }

    /// Scales by `numerator / denominator` using integer arithmetic.
    ///
    /// Integer rather than floating point on purpose: a percentage applied to a
    /// budget must be reproducible across runs and platforms, and `Double`
    /// rounding at gigabyte magnitudes is not.
    ///
    /// A zero or negative denominator returns `.zero` rather than dividing —
    /// `/` by zero traps in Swift, and a division trap inside a budget check is
    /// the failure mode this whole type exists to remove.
    public func scaled(numerator: Int, denominator: Int) -> ByteCount {
        guard denominator > 0, numerator > 0 else { return .zero }
        // Divide first when it is lossless-enough to avoid the overflow, then
        // multiply; fall back to saturating multiply for small values.
        let quotient = rawValue / denominator
        let remainder = rawValue % denominator
        let whole = ByteCount.saturatingMultiply(quotient, numerator)
        let partial = ByteCount.saturatingMultiply(remainder, numerator) / denominator
        return ByteCount(rawValue: ByteCount.saturatingAdd(whole, partial))
    }

    /// This count as a percentage of `base`, without a trapping division.
    ///
    /// A zero base is a real input — a host with no headroom at all — so it
    /// returns `Int.max` for any non-zero numerator ("infinitely over") rather
    /// than dividing by zero.
    public func percent(of base: ByteCount) -> Int {
        guard base.rawValue > 0 else { return rawValue > 0 ? Int.max : 0 }
        return ByteCount.saturatingMultiply(rawValue, 100) / base.rawValue
    }

    /// The larger of two counts.
    public static func maximum(_ lhs: ByteCount, _ rhs: ByteCount) -> ByteCount {
        lhs.rawValue >= rhs.rawValue ? lhs : rhs
    }

    /// Sums a sequence with saturation. Used wherever a catalog of unknown size
    /// is folded, so a pathological catalog cannot trap the planner.
    public static func sum<S: Sequence>(_ counts: S) -> ByteCount where S.Element == ByteCount {
        counts.reduce(ByteCount.zero, +)
    }

    // MARK: - Saturating integer primitives

    static func saturatingAdd(_ a: Int, _ b: Int) -> Int {
        let (sum, overflow) = a.addingReportingOverflow(b)
        guard overflow else { return sum }
        return a > 0 ? Int.max : Int.min
    }

    static func saturatingSubtract(_ a: Int, _ b: Int) -> Int {
        let (difference, overflow) = a.subtractingReportingOverflow(b)
        guard overflow else { return difference }
        return a > 0 ? Int.max : Int.min
    }

    /// Saturating multiply. Also covers `Int.min * -1`, which is the one
    /// multiplication that overflows without either operand being large.
    static func saturatingMultiply(_ a: Int, _ b: Int) -> Int {
        let (product, overflow) = a.multipliedReportingOverflow(by: b)
        guard overflow else { return product }
        return (a > 0) == (b > 0) ? Int.max : Int.min
    }

    /// Compares `lhs.value / lhs.weight` against `rhs.value / rhs.weight`
    /// without dividing, so a zero weight cannot trap and integer truncation
    /// cannot make two different ratios compare equal.
    ///
    /// Used to order evictions by bytes reclaimed per unit of rebuild cost.
    /// Weights are clamped to at least 1 here as well as at the call site,
    /// because this is reachable from anywhere in the module.
    static func ratioIsGreater(
        value lhsValue: ByteCount, weight lhsWeight: Int,
        than rhsValue: ByteCount, weight rhsWeight: Int
    ) -> Bool {
        let left = saturatingMultiply(lhsValue.rawValue, Swift.max(1, rhsWeight))
        let right = saturatingMultiply(rhsValue.rawValue, Swift.max(1, lhsWeight))
        return left > right
    }
}

extension ByteCount: CustomStringConvertible {
    public var description: String {
        let mib = 1_048_576
        if rawValue >= mib {
            let whole = rawValue / mib
            let tenths = (rawValue % mib) * 10 / mib
            return "\(whole).\(tenths) MB"
        }
        if rawValue >= 1_024 {
            return "\(rawValue / 1_024) KB"
        }
        return "\(rawValue) B"
    }
}
