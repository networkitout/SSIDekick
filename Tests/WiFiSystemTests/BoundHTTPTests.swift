import Foundation
import Network
import Testing
import WiFiCore
@testable import WiFiSystem

/// The parsing helper of the Wi-Fi captive check, and the bound fetch against a loopback listener only.
@Suite struct BoundHTTPTests {
    private func data(_ text: String) -> Data { Data(text.utf8) }

    @Test func parsesStatusAndBody() {
        let ok = parseHTTPResponse(data("HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\n<HTML>Success</HTML>"))
        #expect(ok?.status == 200)
        #expect(ok?.body == "<HTML>Success</HTML>")
        let redirect = parseHTTPResponse(data("HTTP/1.0 302 Found\r\nLocation: http://portal.test/\r\n\r\n"))
        #expect(redirect?.status == 302)
        #expect(redirect?.body == "")
        let bareLF = parseHTTPResponse(data("HTTP/1.1 200 OK\nX-A: b\n\nSuccess"))
        #expect(bareLF?.status == 200)
        #expect(bareLF?.body == "Success")
        // Cut off before the blank line (the 4 KB cap): the status still reads, the body is empty.
        let headersOnly = parseHTTPResponse(data("HTTP/1.1 200 OK\r\nContent-Length: 70\r\n"))
        #expect(headersOnly?.status == 200)
        #expect(headersOnly?.body == "")
    }

    @Test func rejectsWhatIsNotAStatusLine() {
        for text in ["", "hello", "HTTP/1.1", "HTTP/1.1 abc OK\r\n\r\n", "HTTP/1.1 99 Low\r\n\r\n",
                     "HTTP/1.1 2000 Long\r\n\r\n", "HTTP/1.1 +20 Sign\r\n\r\n", "SSH-2.0-x\r\n", "HTTP/2 200\r\n\r\n"] {
            #expect(parseHTTPResponse(data(text)) == nil, "\(text)")
        }
    }

    @Test func classifiesRawResponses() {
        #expect(classifyCaptiveResponse(nil) == .offline)
        #expect(classifyCaptiveResponse(Data()) == .offline)
        #expect(classifyCaptiveResponse(data("HTTP/1.1 200 OK\r\n\r\n<HTML><BODY>Success</BODY></HTML>")) == .online)
        #expect(classifyCaptiveResponse(data("HTTP/1.1 200 OK\r\n\r\n<html>Sign in</html>")) == .captivePortal)
        #expect(classifyCaptiveResponse(data("HTTP/1.1 302 Found\r\nLocation: http://portal.test/\r\n\r\n"))
            == .captivePortal)
        // An answer that is not HTTP is still an answer from something on the path: a portal, not offline.
        #expect(classifyCaptiveResponse(data("garbage")) == .captivePortal)
    }

    @Test(.timeLimit(.minutes(1)))
    func fetchesOverTheNamedInterface() async throws {
        let server = try #require(await LoopbackHTTPServer.start(
            response: "HTTP/1.1 200 OK\r\nContent-Length: 34\r\n\r\n<HTML><BODY>Success</BODY></HTML>\n"))
        defer { server.stop() }
        let response = await boundHTTPGet(host: "127.0.0.1", port: server.port, path: "/hotspot-detect.html",
                                          interfaceName: "lo0", interfaceType: .loopback, timeout: 5)
        #expect(classifyCaptiveResponse(response) == .online)
        let request = server.request
        #expect(request.hasPrefix("GET /hotspot-detect.html HTTP/1.1\r\n"))
        #expect(request.contains("\r\nHost: 127.0.0.1:\(server.port)\r\n"))
        #expect(request.contains("\r\nConnection: close\r\n"))
        #expect(request.hasSuffix("\r\n\r\n"))
    }

    @Test(.timeLimit(.minutes(1)))
    func capsTheResponseAt4KB() async throws {
        let body = String(repeating: "x", count: 10_000)
        let server = try #require(await LoopbackHTTPServer.start(response: "HTTP/1.1 200 OK\r\n\r\n" + body,
                                                                 closeAfterSending: false))
        defer { server.stop() }
        let start = Date()
        let response = await boundHTTPGet(host: "127.0.0.1", port: server.port, path: "/",
                                          interfaceName: "lo0", interfaceType: .loopback, timeout: 5)
        #expect(response?.count == 4096)
        #expect(Date().timeIntervalSince(start) < 4)   // stopped at the cap, not at the timeout
        #expect(classifyCaptiveResponse(response) == .captivePortal)
    }

    @Test(.timeLimit(.minutes(1)))
    func refusedConnectionIsNoResponse() async {
        // Nothing listens on port 1.
        let response = await boundHTTPGet(host: "127.0.0.1", port: 1, path: "/",
                                          interfaceName: "lo0", interfaceType: .loopback, timeout: 3)
        #expect(response == nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func unknownInterfaceIsNoResponse() async {
        let response = await boundHTTPGet(host: "127.0.0.1", port: 1, path: "/",
                                          interfaceName: "nosuchif0", interfaceType: .loopback, timeout: 3)
        #expect(response == nil)
    }
}

/// A one-shot TCP server on 127.0.0.1 at a free port: it reads one request, records it and sends `response`.
private final class LoopbackHTTPServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "LoopbackHTTPServer")
    private let lock = NSLock()
    private var received = Data()
    private var connections: [NWConnection] = []
    private(set) var port: UInt16 = 0

    var request: String { lock.withLock { String(decoding: received, as: UTF8.self) } }

    private init(listener: NWListener) { self.listener = listener }

    static func start(response: String, closeAfterSending: Bool = true) async -> LoopbackHTTPServer? {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        guard let listener = try? NWListener(using: parameters) else { return nil }
        let server = LoopbackHTTPServer(listener: listener)
        listener.newConnectionHandler = { connection in
            server.lock.withLock { server.connections.append(connection) }
            connection.start(queue: server.queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, _, _ in
                if let data { server.lock.withLock { server.received.append(data) } }
                connection.send(content: Data(response.utf8), contentContext: .finalMessage,
                                isComplete: closeAfterSending, completion: .contentProcessed { _ in
                    if closeAfterSending { connection.cancel() }
                })
            }
        }
        let ready: Bool = await withCheckedContinuation { continuation in
            let once = OnceFlag()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: if once.claim() { continuation.resume(returning: true) }
                case .failed, .cancelled: if once.claim() { continuation.resume(returning: false) }
                default: break
                }
            }
            listener.start(queue: server.queue)
        }
        guard ready, let port = listener.port?.rawValue else {
            listener.cancel()
            return nil
        }
        server.port = port
        return server
    }

    func stop() {
        listener.cancel()
        for connection in lock.withLock({ connections }) { connection.cancel() }
    }
}

private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false
    func claim() -> Bool { lock.withLock { defer { claimed = true }; return !claimed } }
}
