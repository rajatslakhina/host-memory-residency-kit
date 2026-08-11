import Foundation

/// One completed plan, compared against what actually happened.
public struct AuditSample: Sendable, Hashable {
    public let host: HostClass
    public let purpose: HostPurpose
    public let activationModel: ActivationModel
    /// What the planner said the peak would be.
    public let reservedPeak: ByteCount
    /// What the peak actually was.
    public let observedPeak: ByteCount

    public init(
        host: HostClass,
        purpose: HostPurpose,
        activationModel: ActivationModel,
        reservedPeak: ByteCount,
        observedPeak: ByteCount
    ) {
        self.host = host
        self.purpose = purpose
        self.activationModel = activationModel
        self.reservedPeak = reservedPeak
        self.observedPeak = observedPeak
    }

    /// The model promised less than reality delivered.
    public var underPredicted: Bool { observedPeak > reservedPeak }

    /// Signed-magnitude error, always non-negative.
    public var errorBytes: ByteCount {
        underPredicted ? observedPeak - reservedPeak : reservedPeak - observedPeak
    }

    /// Under-prediction as a percentage of what was reserved. Zero when the
    /// model over-predicted.
    public var underPredictionPercent: Int {
        guard underPredicted else { return 0 }
        return (observedPeak - reservedPeak).percent(of: reservedPeak)
    }
}

/// The result of holding the model to account.
public enum AuditVerdict: Sendable, Hashable, CustomStringConvertible {
    case insufficientData(samples: Int, required: Int)
    case pass(samples: Int, worstUnderPredictionPercent: Int)
    case fail(samples: Int, worstUnderPredictionPercent: Int, tolerancePercent: Int)

    public var isPass: Bool {
        if case .pass = self { return true }
        return false
    }

    public var description: String {
        switch self {
        case .insufficientData(let samples, let required):
            return "insufficient data: \(samples)/\(required) samples"
        case .pass(let samples, let worst):
            return "pass: \(samples) samples, worst under-prediction \(worst)%"
        case .fail(let samples, let worst, let tolerance):
            return "FAIL: \(samples) samples, worst under-prediction \(worst)% exceeds \(tolerance)%"
        }
    }
}

/// Compares modelled peaks against measured ones and turns the difference into
/// a gate.
///
/// The framing that matters: **a budget model that under-predicts is worse than
/// no budget model at all.** With no model, a team is cautious. With a model
/// that reads "this plan peaks at 38 MB" when it really peaks at 61 MB, a team
/// confidently ships work into a process that will be killed, and the crash
/// reports arrive with no memory warning attached because jetsam does not send
/// one. Over-prediction merely wastes headroom; under-prediction manufactures
/// false confidence, so the two are graded asymmetrically and only
/// under-prediction can fail the gate.
public struct BudgetAudit: Sendable {

    /// Bounded on purpose. This runs inside a widget extension with a 48 MB
    /// ceiling; an audit log that grows with traffic is a memory leak shipped
    /// inside a memory-budget library.
    public let capacity: Int

    private var ring: [AuditSample] = []
    private var nextSlot: Int = 0

    /// Counters that survive ring eviction, so a burst of under-predictions
    /// cannot be erased simply by pushing enough good samples afterwards.
    public private(set) var totalSamples: Int = 0
    public private(set) var underPredictionCount: Int = 0
    public private(set) var worstUnderPredictionPercent: Int = 0

    public init(capacity: Int = 64) {
        // At least one slot: a zero or negative capacity would otherwise make
        // `record` a silent no-op and the gate permanently blind.
        self.capacity = Swift.max(1, capacity)
    }

    /// Most recent samples, oldest first.
    public var samples: [AuditSample] {
        guard ring.count == capacity else { return ring }
        // Rotate the ring back into chronological order.
        return Array(ring[nextSlot...] + ring[..<nextSlot])
    }

    public mutating func record(_ sample: AuditSample) {
        if ring.count < capacity {
            ring.append(sample)
            nextSlot = ring.count % capacity
        } else {
            ring[nextSlot] = sample
            nextSlot = (nextSlot + 1) % capacity
        }

        totalSamples &+= 1
        if sample.underPredicted {
            underPredictionCount &+= 1
            worstUnderPredictionPercent = Swift.max(
                worstUnderPredictionPercent,
                sample.underPredictionPercent
            )
        }
    }

    /// Fails when the worst observed under-prediction exceeds `tolerancePercent`.
    ///
    /// `minimumSamples` exists so a single unlucky measurement on a cold start
    /// cannot red a CI run, and so the gate reports honestly that it does not
    /// yet know rather than passing by default.
    public func verdict(tolerancePercent: Int = 0, minimumSamples: Int = 1) -> AuditVerdict {
        let required = Swift.max(1, minimumSamples)
        guard totalSamples >= required else {
            return .insufficientData(samples: totalSamples, required: required)
        }
        let tolerance = Swift.max(0, tolerancePercent)
        if worstUnderPredictionPercent > tolerance {
            return .fail(
                samples: totalSamples,
                worstUnderPredictionPercent: worstUnderPredictionPercent,
                tolerancePercent: tolerance
            )
        }
        return .pass(samples: totalSamples, worstUnderPredictionPercent: worstUnderPredictionPercent)
    }

    public mutating func reset() {
        ring.removeAll(keepingCapacity: true)
        nextSlot = 0
        totalSamples = 0
        underPredictionCount = 0
        worstUnderPredictionPercent = 0
    }
}
