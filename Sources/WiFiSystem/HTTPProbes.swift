import Darwin
import Foundation
import WiFiCore

/// Captive check result: 200 with "Success" is online, any other response a portal, no response offline.
func classifyCaptive(status: Int?, body: String?) -> InternetStatus {
    guard let status else { return .offline }
    if status == 200, body?.contains("Success") == true { return .online }
    return .captivePortal
}

/// The trimmed text if it is a numeric IPv4 or IPv6 address, else nil.
func validatedIP(_ text: String) -> String? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    var v4 = in_addr()
    var v6 = in6_addr()
    if inet_pton(AF_INET, trimmed, &v4) == 1 || inet_pton(AF_INET6, trimmed, &v6) == 1 { return trimmed }
    return nil
}

/// The two HTTP probes, over an ephemeral session with no cache or cookies that never follows redirects.
final class HTTPProbes {
    static let captiveURL = URL(string: "http://captive.apple.com/hotspot-detect.html")!
    static let publicIPURL = URL(string: "https://api.ipify.org")!
    private static let timeout: TimeInterval = 5

    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.timeoutIntervalForRequest = Self.timeout
        configuration.timeoutIntervalForResource = Self.timeout
        session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
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
