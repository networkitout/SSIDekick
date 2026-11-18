import Foundation
import Security
import Testing
import WiFiCore
@testable import WiFiSystem

@Suite struct HTTPSCheckTests {
    /// The data of every certificate with trust settings in `domain`; none (errSecNoTrustSettings) is empty.
    private func trustSettingsData(_ domain: SecTrustSettingsDomain) -> Set<Data> {
        var array: CFArray?
        let status = SecTrustSettingsCopyCertificates(domain, &array)
        if status == errSecNoTrustSettings { return [] }
        #expect(status == errSecSuccess)
        let certificates = (array as? [SecCertificate]) ?? []
        return Set(certificates.map { SecCertificateCopyData($0) as Data })
    }

    @Test func anchorsAreTheSystemStore() {
        let anchors = systemAnchorData()
        #expect(anchors.count > 100)
        let system = trustSettingsData(.system)
        #expect(anchors.isSubset(of: system))
        #expect(anchors.isDisjoint(with: trustSettingsData(.user)))
        #expect(anchors.isDisjoint(with: trustSettingsData(.admin)))
    }

    /// Only loopback: nothing listens on port 1, so the connection is refused and no challenge is seen.
    @Test func noRouteIsNoAnswer() async {
        let state = await httpsCheck(url: URL(string: "https://127.0.0.1:1/")!, timeout: 2)
        #expect(state == .noAnswer)
    }
    @Test func chainAgainstAnchors() {
        let root = Data([1, 2, 3])
        let other = Data([4, 5, 6])
        #expect(classifyChain(trustPassed: true, rootData: root, rootName: "R", anchors: [root, other]) == .direct)
        #expect(classifyChain(trustPassed: true, rootData: root, rootName: "R", anchors: [other])
            == .decryptable(root: "R"))
        #expect(classifyChain(trustPassed: false, rootData: root, rootName: "R", anchors: [root]) == .rejected)
        #expect(classifyChain(trustPassed: true, rootData: nil, rootName: nil, anchors: [root]) == .noAnswer)
    }

    /// An unreadable root store says nothing about the chain: never "can be decrypted".
    @Test func emptyAnchorSetIsNoAnswer() {
        let root = Data([1, 2, 3])
        #expect(classifyChain(trustPassed: true, rootData: root, rootName: "R", anchors: []) == .noAnswer)
        #expect(classifyChain(trustPassed: false, rootData: root, rootName: "R", anchors: []) == .rejected)
    }
}
