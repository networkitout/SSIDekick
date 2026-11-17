import Foundation
import WiFiCore

/// True for a BSD interface name such as "en0": lowercase letters then digits.
func isValidInterfaceName(_ name: String) -> Bool {
    // ^[a-z]+[0-9]+$
    let letters = name.prefix { ("a"..."z").contains($0) }
    let digits = name.dropFirst(letters.count)
    return !letters.isEmpty && !digits.isEmpty && digits.allSatisfy { ("0"..."9").contains($0) }
}

/// Reads the hardware address from `arp -n -i <interface> <ip>` output; nil for incomplete or missing entries.
/// Lines for any other interface are ignored.
func parseARP(_ output: String, interface: String) -> MACAddress? {
    for line in output.split(separator: "\n") {
        guard let on = line.range(of: " on "),
              line[on.upperBound...].split(separator: " ").first == Substring(interface) else { continue }
        guard let at = line.range(of: " at ") else { continue }
        guard let token = line[at.upperBound...].split(separator: " ").first else { continue }
        if let address = MACAddress(String(token)) { return address }
    }
    return nil
}

/// Looks neighbours up in the system ARP table by running `/usr/sbin/arp -n -i <interface> <ip>`.
public final class ARPNeighborTable: NeighborSource {
    private static let timeout: TimeInterval = 2
    private let interfaceName: String

    public init(interfaceName: String) {
        self.interfaceName = interfaceName
    }

    public func hardwareAddress(forIPv4 ip: String) async -> MACAddress? {
        // Only a literal IPv4 address and a plain interface name ever reach the process arguments.
        guard ipv4Address(ip) != nil, isValidInterfaceName(interfaceName) else { return nil }
        let interface = interfaceName
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: Self.lookUp(ip, interface: interface))
            }
        }
    }

    private static func lookUp(_ ip: String, interface: String) -> MACAddress? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/arp")
        process.arguments = ["-n", "-i", interface, ip]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }

        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: watchdog)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()
        try? output.fileHandleForReading.close()

        guard process.terminationReason == .exit else { return nil }
        return parseARP(String(decoding: data, as: UTF8.self), interface: interface)
    }
}
