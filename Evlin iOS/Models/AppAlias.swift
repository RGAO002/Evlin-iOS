import Foundation

// MARK: - AppAlias DTOs (Task F1)
//
// These decode the backend GET /parent/app-aliases response.
// All snake_case JSON fields are mapped via explicit CodingKeys,
// matching the convention used throughout APIClient.swift.

/// A child device that can receive lock commands for a given app.
struct LockableDevice: Codable, Identifiable, Hashable {
    let childDeviceID: UUID
    let childName: String
    let deviceLabel: String

    /// Satisfies `Identifiable` — uniquely identifies this device row.
    var id: UUID { childDeviceID }

    enum CodingKeys: String, CodingKey {
        case childDeviceID = "child_device_id"
        case childName = "child_name"
        case deviceLabel = "device_label"
    }
}

/// One app row in the parent's app-alias feed.
struct AppAliasRow: Codable, Identifiable, Hashable {
    /// The Family App Dictionary entry ID — nil if the app is unconfirmed.
    let familyAppID: UUID?
    let bundleID: String
    let canonicalName: String
    let artworkURL: URL?
    let aliases: [String]
    let blockable: Bool
    let lockableDevices: [LockableDevice]

    /// Satisfies `Identifiable` — bundle ID is stable and unique per app.
    var id: String { bundleID }

    /// True when at least one child device can receive a lock command for this app.
    var lockable: Bool { !lockableDevices.isEmpty }

    enum CodingKeys: String, CodingKey {
        case familyAppID = "family_app_id"
        case bundleID = "bundle_id"
        case canonicalName = "canonical_name"
        case artworkURL = "artwork_url"
        case aliases
        case blockable
        case lockableDevices = "lockable_devices"
    }
}

/// Top-level response from GET /parent/app-aliases.
struct AppAliasFeedResponse: Codable {
    let familyID: UUID
    let apps: [AppAliasRow]

    enum CodingKeys: String, CodingKey {
        case familyID = "family_id"
        case apps
    }
}
