#if DEBUG
import Foundation
import CoreMedia
import CoreVideo
import VideoToolbox
import OSLog
import CinemaxKit

/// Diagnostic probe for the tvOS A15 stutter (étape 3 du handoff) — NOT shipped
/// (DEBUG only). libVLC's videotoolbox decoder dies at
/// `VTDecompressionSessionCreate` with OSStatus -4 (`unimpErr`) on the
/// Apple TV, falling back to software `avcodec` for 4K HEVC HDR10.
///
/// v3 — the faithful v2 replication succeeded with a *synthetic* Main10 hvcC,
/// so the delta must be the actual stream parameters. This version also
/// tests libVLC's forced output chromas (10-bit x420 / BGRA — decoder.c
/// `GetBestChroma`) and, when a session is stored, downloads the head of the
/// real MKV, extracts the video track's CodecPrivate (the film's verbatim
/// hvcC, which libVLC passes as-is per `CopyDecoderExtradataHEVC`) and
/// replays the creation with it.
///
/// Results go to stderr (captured by `devicectl … launch --console`) and to
/// OSLog subsystem `com.cinemax`, category `VTProbe`.
@MainActor
enum VTDecodeProbe {
    private static var hasRun = false

    /// hvcC from a VideoToolbox-encoded 3840×2160 HEVC Main10 HDR10 stream.
    private static let hvccHex = "010220000000b0000000000099f000fcfdfafa00000b03a00001001840010c01ffff022000000300b0000003000003009915c090a100010024420101022000000300b00000030000030099a001e020021c4d8815ee45954d4244024020a2000100084401c02cb8d45364"

    /// « 72 heures » — the stuttering item on movies.nivadax.net.
    private static let probeItemId = "62b1ec2f04c968b6d91ebf59007d6309"

    private static let x420 = kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange

    static func runOnce() {
        guard !hasRun else { return }
        hasRun = true
        Task { await runProbe() }
    }

    private static func runProbe() async {
        let log = Logger(subsystem: "com.cinemax", category: "VTProbe")
        emit(log, "VTProbe v3 ▸ start (\(osDescription())) hwHEVC=\(VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC))")

        guard let synth = Data(hexString: hvccHex) else { return }
        run(log, "synthétique fidèle          ", hvcc: synth, forcedFormat: nil)
        run(log, "synthétique + chroma x420   ", hvcc: synth, forcedFormat: x420)
        run(log, "synthétique + chroma BGRA   ", hvcc: synth, forcedFormat: kCVPixelFormatType_32BGRA)

        if let real = await fetchRealHvcc(log) {
            emit(log, "VTProbe v3 ▸ hvcC réel (\(real.count) o) : \(real.prefix(48).map { String(format: "%02x", $0) }.joined())…")
            run(log, "RÉEL fidèle                 ", hvcc: real, forcedFormat: nil)
            run(log, "RÉEL + chroma x420          ", hvcc: real, forcedFormat: x420)
            run(log, "RÉEL + chroma BGRA          ", hvcc: real, forcedFormat: kCVPixelFormatType_32BGRA)
        } else {
            emit(log, "VTProbe v3 ▸ hvcC réel indisponible (pas de session ou parse KO)")
        }
        emit(log, "VTProbe v3 ▸ done")
    }

    private static func run(_ log: Logger, _ label: String, hvcc: Data, forcedFormat: OSType?) {
        let status = createSession(hvcc: hvcc, forcedFormat: forcedFormat)
        emit(log, "VTProbe v3 ▸ \(label) → \(describe(status))")
    }

    // MARK: - Faithful session creation (decoder.c StartVideoToolbox)

    private static func createSession(hvcc: Data, forcedFormat: OSType?) -> OSStatus {
        var ext: [CFString: Any] = [
            kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms: ["hvcC": hvcc],
            kCVImageBufferChromaLocationTopFieldKey: kCVImageBufferChromaLocation_Left,
            kCVImageBufferChromaLocationBottomFieldKey: kCVImageBufferChromaLocation_Left,
            kCVImageBufferPixelAspectRatioKey: [
                kCVImageBufferPixelAspectRatioHorizontalSpacingKey: 1,
                kCVImageBufferPixelAspectRatioVerticalSpacingKey: 1,
            ],
        ]
        ext[kCVImageBufferYCbCrMatrixKey] = kCVImageBufferYCbCrMatrix_ITU_R_2020
        ext[kCVImageBufferColorPrimariesKey] = kCVImageBufferColorPrimaries_ITU_R_2020
        ext[kCVImageBufferTransferFunctionKey] = kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ

        var formatDesc: CMVideoFormatDescription?
        let fmtStatus = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: kCMVideoCodecType_HEVC,
            width: 3840,
            height: 2160,
            extensions: ext as CFDictionary,
            formatDescriptionOut: &formatDesc
        )
        guard fmtStatus == noErr, let formatDesc else { return fmtStatus }

        var attrs: [CFString: Any] = [
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferOpenGLESCompatibilityKey: true,
            kCVPixelBufferWidthKey: 3840,
            kCVPixelBufferHeightKey: 2160,
            kCVPixelBufferBytesPerRowAlignmentKey: 16,
        ]
        if let forcedFormat {
            attrs[kCVPixelBufferPixelFormatTypeKey] = Int(forcedFormat)
        }

        var session: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: formatDesc,
            decoderSpecification: ext as CFDictionary,
            imageBufferAttributes: attrs as CFDictionary,
            outputCallback: nil,
            decompressionSessionOut: &session
        )
        if let session {
            VTDecompressionSessionInvalidate(session)
        }
        return status
    }

    // MARK: - Real hvcC from the MKV head

    private static func fetchRealHvcc(_ log: Logger) async -> Data? {
        let keychain = KeychainService()
        guard let serverURL = keychain.getServerURL(),
              let token = keychain.getAccessToken() else { return nil }
        // appendingPathComponent keeps a sub-path-hosted server's base path.
        let endpoint = serverURL
            .appendingPathComponent("Videos")
            .appendingPathComponent(probeItemId)
            .appendingPathComponent("stream")
        var comps = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        comps?.queryItems = [
            URLQueryItem(name: "static", value: "true"),
            URLQueryItem(name: "api_key", value: token),
        ]
        guard let url = comps?.url else { return nil }
        var request = URLRequest(url: url)
        request.setValue("bytes=0-4194303", forHTTPHeaderField: "Range")
        request.timeoutInterval = 20
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        let session = URLSession(configuration: config)
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            emit(log, "VTProbe v3 ▸ fetch MKV head KO")
            return nil
        }
        emit(log, "VTProbe v3 ▸ MKV head \(data.count) o")
        // Dump for host-side analysis (devicectl device copy from).
        // Caches, not Documents: tvOS only allows writes to Caches/tmp.
        if let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
            do {
                try data.write(to: caches.appendingPathComponent("mkvhead.bin"))
                emit(log, "VTProbe v3 ▸ head dumpé dans Library/Caches/mkvhead.bin")
            } catch {
                emit(log, "VTProbe v3 ▸ dump KO: \(error.localizedDescription)")
            }
        }
        return extractCodecPrivate(from: data)
    }

    /// Scans the EBML for a CodecPrivate element (ID 0x63A2) whose payload
    /// looks like an hvcC (configurationVersion 1, plausible size). Crude but
    /// sufficient: the video track is the only element matching the shape.
    static func extractCodecPrivate(from data: Data) -> Data? {
        let bytes = [UInt8](data)
        var i = 0
        while i < bytes.count - 4 {
            if bytes[i] == 0x63, bytes[i + 1] == 0xA2 {
                // ≥ 20: a bare hvcC header with zero parameter-set arrays is
                // exactly 23 bytes — and that shape IS the bug under test.
                if let (size, lenLen) = readVint(bytes, at: i + 2),
                   size >= 20, size <= 8192,
                   i + 2 + lenLen + size <= bytes.count {
                    let payload = Array(bytes[(i + 2 + lenLen)..<(i + 2 + lenLen + size)])
                    if payload[0] == 0x01, (payload[1] & 0x1F) <= 3 {
                        return Data(payload)
                    }
                }
            }
            i += 1
        }
        return nil
    }

    private static func readVint(_ bytes: [UInt8], at index: Int) -> (value: Int, length: Int)? {
        guard index < bytes.count else { return nil }
        let first = bytes[index]
        guard first != 0 else { return nil }
        let length = first.leadingZeroBitCount + 1
        guard length <= 8, index + length <= bytes.count else { return nil }
        var value = Int(first & (0xFF >> UInt8(length)))
        for k in 1..<length {
            value = (value << 8) | Int(bytes[index + k])
        }
        return (value, length)
    }

    // MARK: - Plumbing

    private static func describe(_ status: OSStatus) -> String {
        switch status {
        case noErr: return "noErr ✅"
        case -4: return "-4 unimpErr ❌ (the libVLC failure)"
        case -8971: return "-8971 codecExtensionNotFoundErr"
        case kVTParameterErr: return "\(status) kVTParameterErr"
        case kVTCouldNotFindVideoDecoderErr: return "\(status) kVTCouldNotFindVideoDecoderErr"
        case kVTVideoDecoderNotAvailableNowErr: return "\(status) kVTVideoDecoderNotAvailableNowErr"
        case kVTPixelTransferNotSupportedErr: return "\(status) kVTPixelTransferNotSupportedErr"
        default: return "\(status)"
        }
    }

    private static func osDescription() -> String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        #if os(tvOS)
        let os = "tvOS"
        #else
        let os = "iOS"
        #endif
        return "\(os) \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    private static func emit(_ log: Logger, _ line: String) {
        log.notice("\(line, privacy: .public)")
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }
}

private extension Data {
    init?(hexString: String) {
        guard hexString.count.isMultiple(of: 2) else { return nil }
        var data = Data(capacity: hexString.count / 2)
        var index = hexString.startIndex
        while index < hexString.endIndex {
            let next = hexString.index(index, offsetBy: 2)
            guard let byte = UInt8(hexString[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        self = data
    }
}
#endif
