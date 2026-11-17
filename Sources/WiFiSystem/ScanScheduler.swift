import Foundation

/// Decides when automatic scans run. Requests coalesce and wait `debounce` seconds; an automatic scan never starts
/// sooner than `spacing` seconds after the previous scan finished (it is postponed, not dropped); a request that
/// arrives while a scan runs asks for exactly one more scan afterwards. Pure state: the Engine owns the timer.
struct ScanScheduler {
    static let debounce: TimeInterval = 2
    static let spacing: TimeInterval = 10

    private(set) var isScanning = false
    private var requestedAt: Date?
    private var rerunWanted = false
    private var lastFinished: Date?

    var isPending: Bool { requestedAt != nil }

    /// When the pending automatic scan may start; nil when none is pending.
    var dueDate: Date? {
        guard let requestedAt else { return nil }
        let debounced = requestedAt + Self.debounce
        guard let lastFinished else { return debounced }
        return max(debounced, lastFinished + Self.spacing)
    }

    /// Returns true when this request created a new pending scan, which then needs a timer.
    mutating func request(now: Date) -> Bool {
        if isScanning {
            rerunWanted = true
            return false
        }
        guard requestedAt == nil else { return false }
        requestedAt = now
        return true
    }

    /// Drops the pending scan (for example because Wi-Fi is not connected when it falls due).
    mutating func cancelPending() {
        requestedAt = nil
    }

    /// A scan starts; it satisfies any pending request.
    mutating func begin() {
        isScanning = true
        requestedAt = nil
    }

    /// The scan finished. Returns true when a rerun is now pending.
    mutating func finish(now: Date) -> Bool {
        isScanning = false
        lastFinished = now
        guard rerunWanted else { return false }
        rerunWanted = false
        requestedAt = now
        return true
    }
}
