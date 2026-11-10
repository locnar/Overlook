import Foundation

/// A video quality preset, as the KVM's own web UI defines it (firmware 1.10.0).
///
/// The raw value is the device's `stream_quality` config value. The web UI's enum also has
/// Auto (5), which sends `h264_bitrate=0`. Overlook does not offer Auto, so 5 has no case here:
/// a device stored as Auto shows Custom, and Overlook never sends a zero bitrate.
enum QualityPreset: Int, CaseIterable {
    case low = 0
    case medium = 1
    case high = 2
    case ultraHigh = 3
    case lossless = 4

    /// The picker label, as the web UI spells it.
    var label: String {
        switch self {
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        case .ultraHigh: return "Ultra-high"
        case .lossless: return "Lossless"
        }
    }

    /// The H.264 bitrate the web UI sends for this preset, in kbit/s.
    var h264Bitrate: Int {
        switch self {
        case .low: return 500
        case .medium: return 2000
        case .high: return 5000
        case .ultraHigh: return 8000
        case .lossless: return 20000
        }
    }

    /// The H.264 GOP the web UI sends for this preset when the EDID is not 4K.
    var h264Gop: Int {
        switch self {
        case .low, .medium: return 30
        case .high, .ultraHigh, .lossless: return 60
        }
    }

    /// The `stream_quality` value stored after applying this preset.
    var streamQuality: Int { rawValue }

    /// The query `/api/streamer/set_params` gets for `preset`: only `h264_bitrate` and
    /// `h264_gop`, as the web UI sends. On a 4K EDID the web UI halves the GOP (30 → 15,
    /// 60 → 30) and leaves the bitrate as it is.
    static func params(for preset: QualityPreset, is4K: Bool) -> [String: String] {
        let gop = is4K ? preset.h264Gop / 2 : preset.h264Gop
        return [
            "h264_bitrate": String(preset.h264Bitrate),
            "h264_gop": String(gop),
        ]
    }

    /// The EDID catalog ids the web UI treats as 4K. `E3840x2160RM4PE` is not in Overlook's
    /// catalog today; it is listed so the check holds if that entry is added.
    static let fourKEdidIDs: Set<String> = ["E3840x2160", "E3840x2160RM4PE"]

    /// Whether the EDID with catalog id `edidCatalogID` is 4K. Nil (EDID not loaded yet, or
    /// matching no catalog entry) is not 4K.
    static func is4K(edidCatalogID: String?) -> Bool {
        guard let edidCatalogID else { return false }
        return fourKEdidIDs.contains(edidCatalogID)
    }
}
