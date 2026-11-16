import Foundation
import WiFiCore

/// Reads the hardware address from `arp -n <ip>` output; nil for incomplete or missing entries.
func parseARP(_ output: String) -> MACAddress? {
    for line in output.split(separator: "\n") {
        guard let at = line.range(of: " at ") else { continue }
        guard let token = line[at.upperBound...].split(separator: " ").first else { continue }
        if let address = MACAddress(String(token)) { return address }
    }
    return nil
}

/// Looks neighbours up in the system ARP table by running `/usr/sbin/arp -n <ip>`.
public final class ARPNeighborTable: NeighborSource {
    private static let timeout: TimeInterval = 2

    public init() {}

    public func hardwareAddress(forIPv4 ip: String) async -> MACAddress? {
        // Only a literal IPv4 address ever reaches the process arguments.
        guard ipv4Address(ip) != nil else { return nil }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: Self.lookUp(ip))
            }
        }
    }

    private static func lookUp(_ ip: String) -> MACAddress? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/arp")
        process.arguments = ["-n", ip]
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
        return parseARP(String(decoding: data, as: UTF8.self))
    }
}
