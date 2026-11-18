import Foundation
import Network

/// GETs `path` from `host`:`port` over plain TCP on the interface named `interfaceName` (looked up among the
/// interfaces of `interfaceType`), never another route, and returns the raw response bytes: at most `maxBytes`,
/// ending where the server closed, the cap was reached or `timeout` ran out. nil when nothing arrived: the interface
/// is not there, the connection was refused or had no route, or no byte came in time.
func boundHTTPGet(host: String, port: UInt16, path: String, interfaceName: String,
                  interfaceType: NWInterface.InterfaceType, timeout: TimeInterval,
                  maxBytes: Int = 4096) async -> Data? {
    let start = Date()
    guard let interface = await networkInterface(named: interfaceName, type: interfaceType,
                                                 timeout: min(1, timeout)),
          let nwPort = NWEndpoint.Port(rawValue: port) else { return nil }
    let parameters = NWParameters.tcp
    parameters.requiredInterface = interface
    parameters.preferNoProxies = true
    let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: parameters)
    let hostHeader = port == 80 ? host : "\(host):\(port)"
    let request = Data("GET \(path) HTTP/1.1\r\nHost: \(hostHeader)\r\nConnection: close\r\n\r\n".utf8)
    let remaining = max(0, timeout - Date().timeIntervalSince(start))
    return await BoundFetch(connection: connection, request: request, maxBytes: maxBytes).run(timeout: remaining)
}

/// The interface named `name` among the interfaces of `type` the system offers now; nil when it is not among them
/// or no path arrives within `timeout` seconds.
func networkInterface(named name: String, type: NWInterface.InterfaceType,
                      timeout: TimeInterval) async -> NWInterface? {
    let monitor = NWPathMonitor(requiredInterfaceType: type)
    let queue = DispatchQueue(label: "WiFiSystem.networkInterface")
    let once = Once<NWInterface?>()
    return await withCheckedContinuation { continuation in
        once.arm(continuation) { monitor.cancel() }
        monitor.pathUpdateHandler = { path in
            once.finish(path.availableInterfaces.first { $0.name == name })
        }
        monitor.start(queue: queue)
        queue.asyncAfter(deadline: .now() + timeout) { once.finish(nil) }
    }
}

/// Resumes a continuation exactly once, whichever callback comes first, and runs `cleanup` just before.
private final class Once<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Never>?
    private var cleanup: (() -> Void)?

    func arm(_ continuation: CheckedContinuation<Value, Never>, cleanup: @escaping () -> Void) {
        lock.withLock {
            self.continuation = continuation
            self.cleanup = cleanup
        }
    }

    func finish(_ value: Value) {
        let taken = lock.withLock { () -> (CheckedContinuation<Value, Never>, (() -> Void)?)? in
            guard let continuation else { return nil }
            defer {
                self.continuation = nil
                self.cleanup = nil
            }
            return (continuation, cleanup)
        }
        guard let taken else { return }
        taken.1?()
        taken.0.resume(returning: value)
    }
}

/// One request over one connection. Every callback runs on `queue`; the first of done, failure, cap and timeout
/// cancels the connection and resumes the caller, once.
private final class BoundFetch: @unchecked Sendable {
    private let connection: NWConnection
    private let request: Data
    private let maxBytes: Int
    private let queue = DispatchQueue(label: "WiFiSystem.boundHTTPGet")
    private let once = Once<Data?>()
    /// Only touched on `queue`.
    private var received = Data()

    init(connection: NWConnection, request: Data, maxBytes: Int) {
        self.connection = connection
        self.request = request
        self.maxBytes = maxBytes
    }

    func run(timeout: TimeInterval) async -> Data? {
        await withCheckedContinuation { continuation in
            let connection = self.connection
            once.arm(continuation) {
                connection.stateUpdateHandler = nil
                connection.cancel()
            }
            queue.async { [self] in
                connection.stateUpdateHandler = { [self] state in handle(state) }
                connection.start(queue: queue)
                queue.asyncAfter(deadline: .now() + timeout) { [self] in finish() }
            }
        }
    }

    private func handle(_ state: NWConnection.State) {
        switch state {
        case .ready:
            connection.send(content: request, completion: .contentProcessed { [self] error in
                if error != nil { finish() } else { receive() }
            })
        case .waiting, .failed, .cancelled:
            // Waiting: refused or no route on this interface right now. The check does not wait for one.
            finish()
        case .setup, .preparing:
            break
        @unknown default:
            break
        }
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: maxBytes - received.count) {
            [self] data, _, isComplete, error in
            if let data { received.append(data.prefix(maxBytes - received.count)) }
            if isComplete || error != nil || received.count >= maxBytes { finish() } else { receive() }
        }
    }

    /// Runs on `queue`, so `received` is read where it is written.
    private func finish() {
        once.finish(received.isEmpty ? nil : received)
    }
}
