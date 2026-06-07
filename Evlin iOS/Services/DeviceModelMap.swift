import Foundation

/// Maps a raw machine identifier (e.g. "iPhone16,1") to a friendly marketing
/// name (e.g. "iPhone 15 Pro"). Unmapped identifiers fall back to the raw id
/// so the backend can backfill names via a future app update (spec §1.7).
enum DeviceModelMap {
    /// Curated subset; extend as new hardware ships. The raw id is always a
    /// safe fallback for anything not listed.
    static let names: [String: String] = [
        "iPhone14,4": "iPhone 13 mini",
        "iPhone14,5": "iPhone 13",
        "iPhone14,2": "iPhone 13 Pro",
        "iPhone14,3": "iPhone 13 Pro Max",
        "iPhone14,7": "iPhone 14",
        "iPhone14,8": "iPhone 14 Plus",
        "iPhone15,2": "iPhone 14 Pro",
        "iPhone15,3": "iPhone 14 Pro Max",
        "iPhone15,4": "iPhone 15",
        "iPhone15,5": "iPhone 15 Plus",
        "iPhone16,1": "iPhone 15 Pro",
        "iPhone16,2": "iPhone 15 Pro Max",
        "iPhone17,3": "iPhone 16",
        "iPhone17,4": "iPhone 16 Plus",
        "iPhone17,1": "iPhone 16 Pro",
        "iPhone17,2": "iPhone 16 Pro Max",
        "i386": "Simulator",
        "x86_64": "Simulator",
        "arm64": "Simulator",
    ]

    /// Friendly name for a raw machine id; raw id verbatim when unmapped.
    static func friendlyName(for rawId: String) -> String {
        names[rawId] ?? rawId
    }
}
