import Foundation
import SystemConfiguration

/// Maps one network service's state dictionaries to a `NetworkConfig`. Missing keys give empty values.
/// `setupDNS` is the service's `Setup:` DNS entry: servers listed there were set by hand.
func networkConfig(fromService ipv4: [String: Any]?, ipv6: [String: Any]?, dns: [String: Any]?,
                   setupDNS: [String: Any]? = nil) -> NetworkConfig {
    let handSet = setupDNS?["ServerAddresses"] as? [String] ?? []
    return NetworkConfig(gatewayIP: ipv4?["Router"] as? String,
                         dnsServers: dns?["ServerAddresses"] as? [String] ?? [],
                         ipv4: ipv4?["Addresses"] as? [String] ?? [],
                         ipv6: ipv6?["Addresses"] as? [String] ?? [],
                         dnsServersSetByHand: !handSet.isEmpty)
}

/// Reads the IP configuration of one interface's network service from the system configuration store.
/// Only the service's own DNS entry is read (never the global resolver state), so a VPN does not change the answer.
public final class SystemNetworkConfig: NetworkConfigSource {
    private let interfaceName: String
    private let observer = ChangeObserver()
    private let queue = DispatchQueue(label: "local.wifiutil.network-config")
    private var store: SCDynamicStore?

    private static let watchedPattern = "State:/Network/Service/.*/(IPv4|IPv6|DNS)"
    private static let serviceIPv4Pattern = "State:/Network/Service/[^/]+/IPv4"

    public init(interfaceName: String) {
        self.interfaceName = interfaceName

        // The store retains the observer through the context, so a callback already queued when this object is
        // deinitialised still finds a live observer.
        var context = SCDynamicStoreContext(
            version: 0,
            info: Unmanaged.passUnretained(observer).toOpaque(),
            retain: { info in
                _ = Unmanaged<ChangeObserver>.fromOpaque(info).retain()
                return info
            },
            release: { info in Unmanaged<ChangeObserver>.fromOpaque(info).release() },
            copyDescription: nil
        )
        let callback: SCDynamicStoreCallBack = { _, _, info in
            guard let info else { return }
            Unmanaged<ChangeObserver>.fromOpaque(info).takeUnretainedValue().notify()
        }
        guard let store = SCDynamicStoreCreate(nil, "local.wifiutil.WiFiUtil" as CFString, callback, &context) else {
            return
        }
        SCDynamicStoreSetNotificationKeys(store, nil, [Self.watchedPattern] as CFArray)
        SCDynamicStoreSetDispatchQueue(store, queue)
        self.store = store
    }

    deinit {
        if let store {
            SCDynamicStoreSetNotificationKeys(store, nil, nil)
            SCDynamicStoreSetDispatchQueue(store, nil)
        }
        observer.finishAll()
    }

    public func current() -> NetworkConfig {
        guard let store, let serviceID = serviceID(in: store) else {
            return networkConfig(fromService: nil, ipv6: nil, dns: nil)
        }
        func entity(_ name: String, domain: String = "State") -> [String: Any]? {
            SCDynamicStoreCopyValue(store, "\(domain):/Network/Service/\(serviceID)/\(name)" as CFString)
                as? [String: Any]
        }
        return networkConfig(fromService: entity("IPv4"), ipv6: entity("IPv6"), dns: entity("DNS"),
                             setupDNS: entity("DNS", domain: "Setup"))
    }

    public var changes: AsyncStream<Void> {
        // Only "something changed" matters, so a burst of store notifications collapses into one pending element.
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in observer.add(continuation) }
    }

    /// The first service (in sorted key order, so repeated reads agree) whose IPv4 state names this interface.
    private func serviceID(in store: SCDynamicStore) -> String? {
        guard let keys = SCDynamicStoreCopyKeyList(store, Self.serviceIPv4Pattern as CFString) as? [String] else {
            return nil
        }
        for key in keys.sorted() {
            guard let value = SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any],
                  value["InterfaceName"] as? String == interfaceName else { continue }
            let parts = key.split(separator: "/")
            // "State:", "Network", "Service", <id>, "IPv4"
            if parts.count == 5 { return String(parts[3]) }
        }
        return nil
    }
}

/// Fans one store notification out to every `changes` subscriber.
private final class ChangeObserver {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<Void>.Continuation] = [:]

    func add(_ continuation: AsyncStream<Void>.Continuation) {
        let id = UUID()
        continuation.onTermination = { [weak self] _ in self?.remove(id) }
        lock.withLock { continuations[id] = continuation }
    }

    func notify() {
        for continuation in lock.withLock({ Array(continuations.values) }) { continuation.yield() }
    }

    func finishAll() {
        let all = lock.withLock {
            let all = Array(continuations.values)
            continuations.removeAll()
            return all
        }
        for continuation in all { continuation.finish() }
    }

    private func remove(_ id: UUID) {
        _ = lock.withLock { continuations.removeValue(forKey: id) }
    }
}
