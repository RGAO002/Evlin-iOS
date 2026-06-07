import Foundation
import UIKit

/// Reads this device's hardware identity for the `/family/device/register`
/// and `/family/create`/`/family/pair` seams (spec §1.7). Field names match
/// the backend Device columns verbatim.
struct DeviceInfoPayload: Codable, Equatable {
    let device_model: String       // friendly: "iPhone 15 Pro"
    let device_model_id: String    // raw: "iPhone16,1"
    let platform: String           // "ios"
    let os_version: String         // "18.4"
}

enum DeviceInfoProvider {
    /// Raw machine identifier. On the Simulator, prefer the host-injected
    /// SIMULATOR_MODEL_IDENTIFIER (the simulated device), else the utsname
    /// machine (which is the Mac arch under the simulator).
    static func rawModelIdentifier() -> String {
        if let sim = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"],
           !sim.isEmpty {
            return sim
        }
        var systemInfo = utsname()
        uname(&systemInfo)
        let mirror = Mirror(reflecting: systemInfo.machine)
        let id = mirror.children.reduce(into: "") { acc, element in
            guard let value = element.value as? Int8, value != 0 else { return }
            acc.append(Character(UnicodeScalar(UInt8(value))))
        }
        return id
    }

    static func current() -> DeviceInfoPayload {
        let rawId = rawModelIdentifier()
        return DeviceInfoPayload(
            device_model: DeviceModelMap.friendlyName(for: rawId),
            device_model_id: rawId,
            platform: "ios",
            os_version: UIDevice.current.systemVersion
        )
    }
}
