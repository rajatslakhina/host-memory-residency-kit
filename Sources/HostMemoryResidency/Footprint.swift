import Foundation

/// Measures what the process is actually using right now.
///
/// Injected rather than called directly, for two reasons that matter more than
/// testability: the real measurement is platform-specific and unavailable on
/// Linux CI, and a budget layer that cannot be driven to an arbitrary footprint
/// in a test cannot have its refusal paths exercised at all.
public protocol FootprintProbe: Sendable {
    func currentFootprint() async -> ByteCount
}

/// A probe whose value the caller sets. The test double, and the honest choice
/// for a demo that wants to show what a 900 MB device does without needing one.
public actor MutableFootprintProbe: FootprintProbe {
    private var value: ByteCount

    public init(_ value: ByteCount = .zero) {
        self.value = value
    }

    public func set(_ newValue: ByteCount) {
        value = newValue
    }

    public func currentFootprint() async -> ByteCount { value }
}

#if canImport(Darwin)
import Darwin

/// Reads the process's real phys_footprint — the number jetsam actually judges.
///
/// Deliberately `phys_footprint` rather than `resident_size`. Resident size
/// omits compressed and swapped-out pages, so it under-reports exactly the
/// memory a process under pressure has most of, and a budget built on it is
/// optimistic in precisely the wrong direction.
public struct MachFootprintProbe: FootprintProbe {

    public init() {}

    public func currentFootprint() async -> ByteCount {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebound, &count)
            }
        }
        guard status == KERN_SUCCESS else { return .zero }
        // `Int(clamping:)` rather than `Int(_:)`: phys_footprint is a UInt64 and
        // the plain initialiser traps on a value above Int.max.
        return ByteCount(rawValue: Int(clamping: info.phys_footprint))
    }
}

/// The probe a shipping app should use on Apple platforms.
public typealias DefaultFootprintProbe = MachFootprintProbe
#else
/// On platforms with no supported measurement, the default probe reports zero
/// and the budget layer runs entirely on its modelled numbers. Stated rather
/// than silently swallowed, because "the probe returned zero" and "this process
/// is using nothing" must not look the same to a reader of this code.
public typealias DefaultFootprintProbe = MutableFootprintProbe
#endif

/// Tracks the measured footprint plus every reservation currently in flight.
///
/// **This is a `struct`, and that is a correctness decision rather than a style
/// one.** The obvious shape for this type is an actor. An actor would be wrong,
/// because the caller has to `await` it — and that `await` lands squarely
/// between "work out whether the plan fits" and "record that it did". Actors
/// are reentrant: a suspension inside a critical section is not a critical
/// section. Two admissions would each observe the pre-reservation total, each
/// conclude they fit, and each commit.
///
/// As a value type owned by `ResidencyCoordinator`, every method here runs
/// synchronously inside that actor's isolation, so check-and-reserve is
/// genuinely atomic with respect to other admissions.
public struct ReservationLedger: Sendable {

    /// A claim on bytes that are not yet allocated but are about to be.
    public struct Reservation: Sendable, Hashable, Identifiable {
        public let id: UUID
        public let peak: ByteCount
        /// Monotonic sequence number. Lets a caller tell a live reservation
        /// from a recycled one after a revocation.
        public let epoch: UInt64
    }

    /// Last measured total footprint, including any tracked component that is
    /// already resident.
    public private(set) var measuredBaseline: ByteCount = .zero

    private var outstanding: [UUID: ByteCount] = [:]
    private var epoch: UInt64 = 0

    /// Highest projected total this ledger has ever authorised. Useful in a
    /// report, and deliberately not reset by `release`.
    public private(set) var highWaterMark: ByteCount = .zero

    public init() {}

    /// Bytes claimed by reservations that have not been released.
    public var outstandingBytes: ByteCount {
        ByteCount.sum(outstanding.values)
    }

    public var reservationCount: Int { outstanding.count }

    public mutating func setMeasuredBaseline(_ value: ByteCount) {
        measuredBaseline = value
    }

    /// Reserves `peak` additional bytes if the projected total stays within
    /// `ceiling`. Returns `nil` when it does not fit — refusal, not truncation.
    ///
    /// No `await` appears anywhere in this method. That is the invariant the
    /// type exists to hold.
    public mutating func reserve(peak: ByteCount, ceiling: ByteCount) -> Reservation? {
        let projected = measuredBaseline + outstandingBytes + peak
        guard projected <= ceiling else { return nil }

        epoch &+= 1
        let reservation = Reservation(id: UUID(), peak: peak, epoch: epoch)
        outstanding[reservation.id] = peak
        highWaterMark = ByteCount.maximum(highWaterMark, projected)
        return reservation
    }

    /// Releases a reservation. Returns `false` if it was already released or
    /// was never issued by this ledger — a double release is a caller bug worth
    /// surfacing, not something to absorb.
    @discardableResult
    public mutating func release(_ reservation: Reservation) -> Bool {
        outstanding.removeValue(forKey: reservation.id) != nil
    }

    /// Drops every outstanding reservation. Used when a plan is abandoned
    /// wholesale, e.g. a scene tearing down mid-activation.
    public mutating func revokeAll() {
        outstanding.removeAll(keepingCapacity: true)
    }
}
