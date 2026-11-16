import CoreLocation
import Foundation

/// Location Services authorisation through `CLLocationManager`. Create it on the main thread: the manager delivers
/// its callbacks on the run loop of the thread that created it.
public final class LocationAuthorizer: NSObject, LocationAuthorizing {
    private let manager = CLLocationManager()
    private let lock = NSLock()
    private var continuation: AsyncStream<Void>.Continuation?

    public override init() {
        super.init()
        manager.delegate = self
    }

    deinit {
        manager.delegate = nil
        lock.withLock { continuation }?.finish()
    }

    public var isAuthorized: Bool {
        // On macOS `.authorized` has the same value as `.authorizedAlways`.
        manager.authorizationStatus == .authorizedAlways
    }

    public var isDetermined: Bool { manager.authorizationStatus != .notDetermined }

    public func request() { manager.requestWhenInUseAuthorization() }

    /// One consumer at a time: reading this again finishes the previous stream and returns a new one.
    public var changes: AsyncStream<Void> {
        let (stream, newContinuation) = AsyncStream<Void>.makeStream()
        let previous = lock.withLock {
            let previous = continuation
            continuation = newContinuation
            return previous
        }
        previous?.finish()
        return stream
    }
}

extension LocationAuthorizer: CLLocationManagerDelegate {
    public func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        lock.withLock { continuation }?.yield()
    }
}
