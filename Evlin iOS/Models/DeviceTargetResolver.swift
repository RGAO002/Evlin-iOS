import Foundation

enum DeviceTargetResolver {
    static func selectedChildDeviceID(
        tappedDeviceUUID: UUID?,
        pairedChildDeviceID: String
    ) -> UUID? {
        tappedDeviceUUID ?? UUID(uuidString: pairedChildDeviceID)
    }
}
