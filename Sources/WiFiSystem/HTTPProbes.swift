import Darwin
import Foundation
import WiFiCore

/// Captive check result: 200 with "Success" is online, any other response a portal, no response offline.
func classifyCaptive(status: Int?, body: String?) -> InternetStatus {
    guard let status else { return .offline }
    if status == 200, body?.contains("Success") == true { return .online }
    return .captivePortal
}

/// The status code and body of a raw HTTP/1.x response, read from its status line and whatever follows the first
/// blank line (empty when the bytes stop before it). nil when the bytes do not start with an HTTP/1.x status line.
func parseHTTPResponse(_ data: Data) -> (status: Int, body: String)? {
    let bytes = [UInt8](data)
    guard let lineEnd = bytes.firstIndex(of: 0x0A) else { return nil }
    var line = bytes[..<lineEnd]
    if line.last == 0x0D { line = line.dropLast() }
    let parts = line.split(separator: 0x20, maxSplits: 2, omittingEmptySubsequences: false)
    guard parts.count >= 2, parts[0].starts(with: Array("HTTP/1.".utf8)), parts[1].count == 3,
          parts[1].allSatisfy({ (0x30...0x39).contains($0) }),
          let status = Int(String(decoding: parts[1], as: UTF8.self)), (100...599).contains(status) else { return nil }
    // The blank line ends the headers; bare LF line ends are read too. Whichever comes first wins.
    let blankLines = [bytes.firstRange(of: [0x0D, 0x0A, 0x0D, 0x0A]), bytes.firstRange(of: [0x0A, 0x0A])]
        .compactMap { $0 }
    guard let headerEnd = blankLines.min(by: { $0.lowerBound < $1.lowerBound }) else { return (status, "") }
    return (status, String(decoding: bytes[headerEnd.upperBound...], as: UTF8.self))
}

/// The captive check's reading of raw response bytes: none is offline, anything that is not 200 with "Success"
/// (including bytes that are not HTTP at all) is a portal.
func classifyCaptiveResponse(_ data: Data?) -> InternetStatus {
    guard let data, !data.isEmpty else { return .offline }
    guard let response = parseHTTPResponse(data) else { return .captivePortal }
    return classifyCaptive(status: response.status, body: response.body)
}

/// The trimmed text if it is a numeric IPv4 or IPv6 address, else nil.
func validatedIP(_ text: String) -> String? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    var v4 = in_addr()
    var v6 = in6_addr()
    if inet_pton(AF_INET, trimmed, &v4) == 1 || inet_pton(AF_INET6, trimmed, &v6) == 1 { return trimmed }
    return nil
}

/// An ephemeral session configuration with no cache and no cookies, timing out after `timeout` seconds.
func lockedDownConfiguration(timeout: TimeInterval) -> URLSessionConfiguration {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
    configuration.urlCache = nil
    configuration.httpCookieStorage = nil
    configuration.httpShouldSetCookies = false
    configuration.httpCookieAcceptPolicy = .never
    configuration.timeoutIntervalForRequest = timeout
    configuration.timeoutIntervalForResource = timeout
    return configuration
}

/// The two HTTP probes, over an ephemeral session with no cache or cookies that never follows redirects.
final class HTTPProbes {
    static let captiveURL = URL(string: "http://captive.apple.com/hotspot-detect.html")!
    static let publicIPURL = URL(string: "https://api.ipify.org")!
    private static let timeout: TimeInterval = 5

    private let session: URLSession

    init() {
        session = URLSession(configuration: lockedDownConfiguration(timeout: Self.timeout), delegate: NoRedirects(),
                             delegateQueue: nil)
    }

    deinit {
        session.invalidateAndCancel()
    }

    /// Internet status and, when online, the request's round trip in milliseconds.
    func captiveCheck() async -> (status: InternetStatus, latencyMs: Double?) {
        let start = monotonicNanos()
        guard let (status, body) = await fetch(Self.captiveURL) else { return (.offline, nil) }
        let latency = Double(monotonicNanos() - start) / 1_000_000
        let result = classifyCaptive(status: status, body: String(decoding: body, as: UTF8.self))
        return (result, result == .online ? latency : nil)
    }

    func publicIP() async -> String? {
        guard let (status, body) = await fetch(Self.publicIPURL), (200..<300).contains(status) else { return nil }
        return validatedIP(String(decoding: body, as: UTF8.self))
    }

    private func fetch(_ url: URL) async -> (status: Int, body: Data)? {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
                                 timeoutInterval: Self.timeout)
        request.httpShouldHandleCookies = false
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse else { return nil }
        return (http.statusCode, data)
    }
}

/// Hands back the 3xx response itself instead of following it.
private final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
