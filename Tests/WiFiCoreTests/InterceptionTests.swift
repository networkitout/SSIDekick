import Foundation
import Testing
import WiFiCore

@Suite struct InterceptionTests {
    static let cf = ["1.1.1.1", "1.0.0.1"]
    static let goog = ["8.8.8.8", "8.8.4.4"]

    func known(google: DNSLookup = .answered(goog), cloudflare: DNSLookup = .answered(cf))
        -> [(name: String, lookup: DNSLookup)] {
        [("one.one.one.one", cloudflare), ("dns.google", google)]
    }

    func classify(google: DNSLookup = .answered(goog), cloudflare: DNSLookup = .answered(cf),
                  madeUp: DNSLookup = .nameError, handSet: Bool = false) -> DNSAnswersState {
        classifyDNS(known: known(google: google, cloudflare: cloudflare), madeUp: madeUp,
                    handSetPrivateServer: handSet)
    }

    @Test func ok() { #expect(classify() == .asExpected) }

    @Test func blockAddressesAreFiltered() {
        #expect(classify(google: .answered(["0.0.0.0"])) == .filtered)
        #expect(classify(google: .answered(["127.0.0.1"])) == .filtered)
        #expect(classify(google: .answered(["146.112.61.106"])) == .filtered)
    }

    @Test func negativeAnswersAreFiltered() {
        #expect(classify(google: .nameError) == .filtered)
        #expect(classify(google: .refused) == .filtered)
        #expect(classify(google: .answered([])) == .filtered)
    }

    @Test func privateAnswerIsTampered() {
        #expect(classify(google: .answered(["172.19.0.1"]))
            == .tampered(name: "dns.google", address: "172.19.0.1", expected: Self.goog))
    }

    @Test func handSetServerIsFilteredByYourServer() {
        #expect(classify(google: .answered(["172.19.0.1"]), handSet: true)
            == .filteredByYourServer(name: "dns.google", address: "172.19.0.1"))
    }

    @Test func mixedAnswersAreTampered() {
        #expect(classify(google: .answered(["8.8.8.8", "172.19.0.1"]))
            == .tampered(name: "dns.google", address: "172.19.0.1", expected: Self.goog))
        #expect(classify(google: .answered(["0.0.0.0", "172.19.0.1"]))
            == .tampered(name: "dns.google", address: "172.19.0.1", expected: Self.goog))
    }

    @Test func madeUpNameRewritten() {
        #expect(classify(madeUp: .answered(["10.20.0.80"])) == .rewritten(address: "10.20.0.80"))
        #expect(classify(google: .nameError, madeUp: .answered(["10.20.0.80"]))
            == .rewritten(address: "10.20.0.80"))
    }

    @Test func tamperedBeatsRewritten() {
        #expect(classify(google: .answered(["172.19.0.1"]), madeUp: .answered(["10.20.0.80"]))
            == .tampered(name: "dns.google", address: "172.19.0.1", expected: Self.goog))
    }

    @Test func firstTamperedWins() {
        let s = classify(google: .answered(["172.19.0.1"]), cloudflare: .answered(["10.9.9.9"]))
        #expect(s == .tampered(name: "one.one.one.one", address: "10.9.9.9", expected: Self.cf))
    }

    @Test func failuresAreUnknown() {
        #expect(classify(google: .failed, cloudflare: .failed, madeUp: .failed) == .noAnswer)
        #expect(classify(google: .failed, cloudflare: .failed, madeUp: .refused) == .noAnswer)
        #expect(classify(google: .failed, madeUp: .failed) == .asExpected)
    }

    @Test func privateAddresses() {
        for ip in ["10.0.0.1", "172.16.0.1", "172.31.255.1", "192.168.1.2", "169.254.3.4",
                   "127.0.0.1", "fd00::1", "fe80::1%en0", "::1"] {
            #expect(isPrivateAddress(ip), "\(ip)")
        }
        for ip in ["172.32.0.1", "1.1.1.1", "8.8.8.8", "2606:4700::1111", "not an ip"] {
            #expect(!isPrivateAddress(ip), "\(ip)")
        }
    }

    @Test func addressBoundaries() {
        #expect(!isPrivateAddress("172.15.255.255"))
        #expect(isPrivateAddress("fc00::1"))
        #expect(!isPrivateAddress("fec0::1"))
        #expect(isPrivateAddress("127.255.255.255"))
        #expect(!isBlockAnswer("146.112.60.255"))
        #expect(isBlockAnswer("146.112.61.255"))
        #expect(isBlockAnswer("127.255.255.255"))
        #expect(!isBlockAnswer("172.15.255.255"))
    }

    @Test func handSetServerWithBlockAnswerIsFiltered() {
        #expect(classify(google: .answered(["0.0.0.0"]), handSet: true) == .filtered)
        #expect(classify(google: .answered(["146.112.61.106"]), handSet: true) == .filtered)
    }

    @Test func blockAnswers() {
        for ip in ["0.0.0.0", "127.0.0.53", "146.112.61.110"] { #expect(isBlockAnswer(ip), "\(ip)") }
        for ip in ["146.112.62.1", "192.168.1.2"] { #expect(!isBlockAnswer(ip), "\(ip)") }
    }

    @Test func madeUpNameShape() {
        let a = madeUpName(), b = madeUpName()
        #expect(a.range(of: #"^[a-z]{12}\.example\.com$"#, options: .regularExpression) != nil)
        #expect(a != b)
    }

    @Test func tls() {
        #expect(classifyTLS(trustPassed: nil, rootIsSystemAnchor: false, rootName: nil) == .noAnswer)
        #expect(classifyTLS(trustPassed: false, rootIsSystemAnchor: true, rootName: "x") == .rejected)
        #expect(classifyTLS(trustPassed: true, rootIsSystemAnchor: true, rootName: "ISRG") == .direct)
        #expect(classifyTLS(trustPassed: true, rootIsSystemAnchor: false, rootName: "Zscaler Root CA")
            == .decryptable(root: "Zscaler Root CA"))
        #expect(classifyTLS(trustPassed: true, rootIsSystemAnchor: false, rootName: nil)
            == .decryptable(root: "unknown"))
    }

    @Test func textsAndLevels() {
        #expect(dnsAnswersText(.asExpected) == "as expected")
        #expect(dnsAnswersLevel(.asExpected) == .good)
        #expect(dnsAnswersText(.rewritten(address: "1.2.3.4")) == "rewritten · made-up names resolve to 1.2.3.4")
        #expect(dnsAnswersLevel(.rewritten(address: "1.2.3.4")) == .fair)
        #expect(dnsAnswersText(.filtered) == "filtered · public DNS names blocked")
        #expect(dnsAnswersLevel(.filtered) == .fair)
        let fy = DNSAnswersState.filteredByYourServer(name: "dns.google", address: "172.19.0.1")
        #expect(dnsAnswersText(fy) == "filtered by your DNS server · dns.google → 172.19.0.1")
        #expect(dnsAnswersLevel(fy) == .fair)
        let t = DNSAnswersState.tampered(name: "dns.google", address: "172.19.0.1", expected: Self.goog)
        #expect(dnsAnswersText(t) == "tampered · dns.google → 172.19.0.1")
        #expect(dnsAnswersLevel(t) == .poor)
        #expect(dnsAnswersText(.notChecked) == "not checked")
        #expect(dnsAnswersText(.off) == "off")
        #expect(dnsAnswersText(.noAnswer) == "no answer")
        for s in [DNSAnswersState.notChecked, .off, .noAnswer] { #expect(dnsAnswersLevel(s) == .unknown) }

        #expect(httpsText(.direct) == "direct · Apple-trusted root")
        #expect(httpsLevel(.direct) == .good)
        #expect(httpsText(.decryptable(root: "Zscaler Root CA")) == "can be decrypted · root \"Zscaler Root CA\"")
        #expect(httpsLevel(.decryptable(root: "r")) == .fair)
        #expect(httpsText(.rejected) == "certificate rejected")
        #expect(httpsLevel(.rejected) == .poor)
        #expect(httpsText(.notChecked) == "not checked")
        #expect(httpsText(.off) == "off")
        #expect(httpsText(.noAnswer) == "no answer")
        for s in [HTTPSState.notChecked, .off, .noAnswer] { #expect(httpsLevel(s) == .unknown) }
    }

    @Test func noReassuringWords() {
        let dns: [DNSAnswersState] = [.notChecked, .off, .noAnswer, .asExpected, .filtered,
            .filteredByYourServer(name: "n", address: "a"), .rewritten(address: "a"),
            .tampered(name: "n", address: "a", expected: [])]
        let https: [HTTPSState] = [.notChecked, .off, .noAnswer, .direct, .decryptable(root: "r"), .rejected]
        let texts = dns.map(dnsAnswersText) + https.map(httpsText)
        for t in texts {
            for w in ["safe", "secure", "verified"] { #expect(!t.lowercased().contains(w), "\(t)") }
        }
    }
}
