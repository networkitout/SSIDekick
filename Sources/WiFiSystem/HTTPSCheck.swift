import Foundation
import Security
import WiFiCore

/// The data of every root certificate in the system's default anchor set (the Apple root store), read afresh on
/// each call.
func systemAnchorData() -> Set<Data> {
    var array: CFArray?
    guard SecTrustCopyAnchorCertificates(&array) == errSecSuccess,
          let certificates = array as? [SecCertificate] else { return [] }
    return Set(certificates.map { SecCertificateCopyData($0) as Data })
}

/// How a chain that `SecTrustEvaluateWithError` judged is trusted, given the system's anchor set. A chain that
/// passed is `.direct` when its root is one of `anchors`, else `.decryptable`. With no anchors to compare against (the
/// root store could not be read) or no root, nothing can be said: `.noAnswer`, never `.decryptable`.
func classifyChain(trustPassed: Bool, rootData: Data?, rootName: String?, anchors: Set<Data>) -> HTTPSState {
    guard trustPassed else { return .rejected }
    guard let rootData, !anchors.isEmpty else { return .noAnswer }
    return classifyTLS(trustPassed: true, rootIsSystemAnchor: anchors.contains(rootData), rootName: rootName)
}

/// Opens a TLS connection to `url` and reports how its certificate chain is trusted: through a system root
/// (`.direct`), through a root someone added (`.decryptable`), not at all (`.rejected`), or no TLS answer
/// (`.noAnswer`). The connection is cancelled at the trust challenge, so no body is downloaded.
func httpsCheck(url: URL, timeout: TimeInterval) async -> HTTPSState {
    let recorder = TrustRecorder()
    let session = URLSession(configuration: lockedDownConfiguration(timeout: timeout), delegate: recorder,
                             delegateQueue: nil)
    defer { session.invalidateAndCancel() }
    var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: timeout)
    request.httpShouldHandleCookies = false
    // URLSession calls a task's completion handler exactly once, so the continuation resumes exactly once.
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        session.dataTask(with: request) { _, _, _ in continuation.resume() }.resume()
    }
    return recorder.result ?? .noAnswer
}

/// Evaluates the server trust challenge, records the classification, then cancels the connection.
private final class TrustRecorder: NSObject, URLSessionDelegate {
    private let lock = NSLock()
    private var recorded: HTTPSState?

    var result: HTTPSState? {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        let passed = SecTrustEvaluateWithError(trust, nil)
        var rootData: Data?
        var rootName: String?
        var anchors: Set<Data> = []
        if passed, let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let root = chain.last {
            rootData = SecCertificateCopyData(root) as Data
            rootName = SecCertificateCopySubjectSummary(root) as String?
            anchors = systemAnchorData()
        }
        let state = classifyChain(trustPassed: passed, rootData: rootData, rootName: rootName, anchors: anchors)
        lock.lock()
        if recorded == nil { recorded = state }
        lock.unlock()
        completionHandler(.cancelAuthenticationChallenge, nil)
    }
}
