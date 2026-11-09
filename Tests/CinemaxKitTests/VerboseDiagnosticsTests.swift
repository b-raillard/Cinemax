import Testing
import Foundation
@testable import Cinemax

/// Verrouille les formes des lignes que les builds Debug / TestFlight
/// ajoutent au journal (`VerboseDiagnostics`). Elles sont lues et cherchées au
/// `grep` dans les documents envoyés au serveur : une clé qui change de nom
/// casse la lecture d'un rapport sans que rien ne le signale.
@Suite("Diagnostics détaillés (Debug / TestFlight)")
struct VerboseDiagnosticsTests {

    // MARK: - Chemin réseau

    @Test("Le chemin réseau nomme l'interface réellement empruntée en premier")
    func pathNamesTheInterfaceInUse() {
        let summary = VerboseDiagnostics.PathFacts(
            status: "satisfied", interfaces: ["wifi", "cellular"],
            isExpensive: false, isConstrained: false,
            supportsIPv4: true, supportsIPv6: true, supportsDNS: true,
            unsatisfiedReason: nil
        ).summary
        #expect(summary == "satisfied via=wifi interfaces=wifi,cellular expensive=no constrained=no ipv4=yes ipv6=yes dns=yes")
    }

    @Test("L'aide au Wi-Fi se lit : la 4G passe devant un Wi-Fi encore listé")
    func wifiAssistIsVisible() {
        let summary = VerboseDiagnostics.PathFacts(
            status: "satisfied", interfaces: ["cellular", "wifi"],
            isExpensive: true, isConstrained: false,
            supportsIPv4: true, supportsIPv6: false, supportsDNS: true,
            unsatisfiedReason: nil
        ).summary
        #expect(summary.contains("via=cellular"))
        #expect(summary.contains("expensive=yes"))
        #expect(summary.contains("ipv6=no"))
    }

    @Test("Un réseau perdu dit pourquoi, et qu'il n'y a plus d'interface")
    func lostPathStatesItsReason() {
        let summary = VerboseDiagnostics.PathFacts(
            status: "unsatisfied", interfaces: [],
            isExpensive: false, isConstrained: false,
            supportsIPv4: false, supportsIPv6: false, supportsDNS: false,
            unsatisfiedReason: "notAvailable"
        ).summary
        #expect(summary.hasPrefix("unsatisfied reason=notAvailable via=none interfaces=none"))
    }

    // MARK: - Échantillon du flux

    @Test("L'échantillon du flux donne les octets lus depuis le précédent")
    func feedLineCarriesTheDelta() {
        let line = VerboseDiagnostics.FeedSample(
            positionSeconds: 230, state: "playing", route: "relay",
            readBytes: 1_500_000, previousReadBytes: 1_000_000,
            inputBitrate: 1.26, displayedPictures: 3736, lostPictures: 2
        ).line
        #expect(line == "CINEMAX-FEED ▸ pos=230s state=playing route=relay read=1500000 delta=+500000 inputBitrate=1.3 displayed=3736 lost=2")
    }

    @Test("Un flux à l'arrêt se lit comme un delta nul, une réouverture comme une remise à zéro")
    func feedLineSilenceAndReset() {
        let silent = VerboseDiagnostics.FeedSample(
            positionSeconds: 10, state: "playing", route: "direct",
            readBytes: 42, previousReadBytes: 42,
            inputBitrate: 0, displayedPictures: 1, lostPictures: 0
        ).line
        #expect(silent.contains("delta=+0"))
        let reopened = VerboseDiagnostics.FeedSample(
            positionSeconds: 10, state: "opening", route: "relay",
            readBytes: 10, previousReadBytes: 42,
            inputBitrate: nil, displayedPictures: nil, lostPictures: nil
        ).line
        #expect(reopened.contains("delta=reset"))
        #expect(reopened.contains("inputBitrate=?"))
        let first = VerboseDiagnostics.FeedSample(
            positionSeconds: 0, state: "opening", route: "direct",
            readBytes: nil, previousReadBytes: nil,
            inputBitrate: nil, displayedPictures: nil, lostPictures: nil
        ).line
        #expect(first.contains("read=? delta=?"))
    }

    // MARK: - Trames HTTP/2 de libVLC

    @Test("Les trames de contrôle HTTP/2 passent, celles qui portent le flux non")
    func onlyControlFramesAreKept() {
        let rst = "in RST_STREAM (0x03) frame of 4 bytes, flags 0x00, stream 43"
        let goaway = "in GOAWAY (0x07) frame of 8 bytes, flags 0x00, global"
        let headers = "in HEADERS (0x01) frame of 120 bytes, flags 0x04, stream 45"
        #expect(VerboseDiagnostics.libVLCFrameLine(rst) == rst)
        #expect(VerboseDiagnostics.libVLCFrameLine(goaway) == goaway)
        #expect(VerboseDiagnostics.libVLCFrameLine(headers) == headers)
        #expect(VerboseDiagnostics.libVLCFrameLine("in DATA (0x00) frame of 16384 bytes, flags 0x00, stream 43") == nil)
        #expect(VerboseDiagnostics.libVLCFrameLine("out WINDOW_UPDATE (0x08) frame of 4 bytes, flags 0x00, global") == nil)
    }

    @Test("Un autre message qui contient « frame of » n'est pas pris pour une trame")
    func otherFrameMessagesAreIgnored() {
        #expect(VerboseDiagnostics.libVLCFrameLine("Note: ID3v2 APIC frame of size 10") == nil)
        #expect(VerboseDiagnostics.libVLCFrameLine("using video decoder module \"videotoolbox\"") == nil)
    }

    // MARK: - Requêtes du relais

    @Test("Une requête du relais dit son protocole, ses adresses et son premier octet")
    func transactionLineShape() {
        let line = VerboseDiagnostics.UpstreamTransaction(
            status: 206, protocolName: "h3", remote: "104.21.1.1:443", local: "192.168.1.42",
            isReused: true, isCellular: false, isExpensive: false, isConstrained: false,
            timeToFirstByteMs: 95, durationMs: 12034, bodyBytes: 5_000_000, error: nil
        ).line
        #expect(line == "upstream status=206 proto=h3 remote=104.21.1.1:443 local=192.168.1.42 reused=yes cellular=no expensive=no constrained=no ttfb=95ms duration=12034ms bytes=5000000")
        let failed = VerboseDiagnostics.UpstreamTransaction(
            status: nil, protocolName: nil, remote: nil, local: nil,
            isReused: false, isCellular: true, isExpensive: true, isConstrained: false,
            timeToFirstByteMs: nil, durationMs: 15000, bodyBytes: 0, error: "-1005"
        ).line
        #expect(failed.hasPrefix("upstream status=none proto=? remote=? local=?"))
        #expect(failed.hasSuffix("bytes=0 error=-1005"))
    }

    @Test("L'adresse locale ne sort jamais en clair : seul son réseau est gardé")
    func localAddressIsReducedToItsNetwork() {
        #expect(VerboseDiagnostics.localAddressClass("192.168.1.42") == "192.168.1.0/24")
        #expect(VerboseDiagnostics.localAddressClass("10.12.200.7") == "10.12.200.0/24")
        #expect(VerboseDiagnostics.localAddressClass("172.20.3.4") == "172.20.3.0/24")
        #expect(VerboseDiagnostics.localAddressClass("100.72.1.9") == "cgnat")
        #expect(VerboseDiagnostics.localAddressClass("86.245.10.3") == "public-ipv4")
        #expect(VerboseDiagnostics.localAddressClass("2a01:cb00:1234::5") == "public-ipv6")
        #expect(VerboseDiagnostics.localAddressClass("fd12:3456::1") == "ula-ipv6")
        #expect(VerboseDiagnostics.localAddressClass("fe80::1c2b") == "link-local-ipv6")
        #expect(VerboseDiagnostics.localAddressClass(nil) == nil)
    }

    // MARK: - Envoi au passage en arrière-plan

    @Test("Quitter l'app après une panne de ce lancement renvoie la suite")
    func recentFaultTriggersTheFollowUp() {
        let now = Date(timeIntervalSince1970: 10_000)
        let history = ["feed-stall-relay": now.addingTimeInterval(-270)]
        #expect(DiagnosticsUploader.hadRecentFault(history: history, now: now, window: 600))
    }

    @Test("Sans panne récente — ou avec la seule suite — rien ne part")
    func noRecentFaultSendsNothing() {
        let now = Date(timeIntervalSince1970: 10_000)
        #expect(!DiagnosticsUploader.hadRecentFault(history: [:], now: now, window: 600))
        let old = ["open-timeout": now.addingTimeInterval(-601)]
        #expect(!DiagnosticsUploader.hadRecentFault(history: old, now: now, window: 600))
        let onlyFollowUp = [DiagnosticsUploader.afterFaultReason: now.addingTimeInterval(-10)]
        #expect(!DiagnosticsUploader.hadRecentFault(history: onlyFollowUp, now: now, window: 600))
    }

    // MARK: - En-tête

    @Test("L'environnement et le réseau ferment l'en-tête, sans déplacer aucune ligne")
    func verboseHeaderLinesComeLast() {
        var facts = DiagnosticsFacts.current(serverVersion: "12.2.0", engine: "vlc", lastPlayback: nil, reason: "open-timeout")
        let plain = DiagnosticsReport.header(facts)
        facts.buildEnvironment = "sandbox"
        facts.network = "satisfied via=wifi"
        let verbose = DiagnosticsReport.header(facts)
        #expect(Array(verbose.prefix(plain.count)) == plain)
        #expect(verbose.suffix(2) == ["build_environment: sandbox", "network: satisfied via=wifi"])
    }
}
