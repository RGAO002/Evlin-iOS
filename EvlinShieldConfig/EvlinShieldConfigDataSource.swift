// EvlinShieldConfig/EvlinShieldConfigDataSource.swift
//
// E1 probe — ShieldConfiguration "harvest" extension.
//
// When iOS renders a shield over an app, it calls this extension's
// configuration(shielding:) on a SPECIFIC Application. Inside this extension
// process, `application.localizedDisplayName` (and possibly `.bundleIdentifier`)
// are NON-NIL — unlike the main app / picker where they're nil. This extension
// ALSO appears able to write the App Group (shield extensions are DAM-class, not
// DAR-class — forum 786195). So this is the one place that BOTH resolves the
// name AND can export it.
//
// We write the harvested {name, bundleID, hasToken} to THREE channels so the
// main-app ShieldHarvestProbeView can see which (if any) crossed:
//   - App Group UserDefaults  key: evlin.shieldconfig.harvest
//   - App Group file          shieldconfig-harvest.json
//   - Keychain shared group   account: evlin.shieldconfig.harvest
//
// Pass criterion: main app reads back a record whose name == the app you opened.
import ManagedSettings
import ManagedSettingsUI
import UIKit
import Foundation
import Security

// No @main: this extension is NSExtension-based. The system instantiates the
// principal class named in Info.plist (NSExtensionPrincipalClass), like the DAM
// extension — not via a main() entry point (that's only for ExtensionKit/DAR).
final class EvlinShieldConfigDataSource: ShieldConfigurationDataSource {
    private let appGroup = "group.com.evlin.ios"
    private let keychainGroup = "D9FM36P37F.com.evlin.darbridge"

    override func configuration(shielding application: Application) -> ShieldConfiguration {
        probeShield(application, context: "app")
    }

    override func configuration(
        shielding application: Application,
        in category: ActivityCategory
    ) -> ShieldConfiguration {
        probeShield(application, context: "app-in-category")
    }

    /// Resolve the app's identity IN-EXTENSION, harvest it to the export channels,
    /// AND render it into the shield itself — so the shield screen visually shows
    /// whether the name/bundleID resolved here (W1), separately from whether the
    /// App-Group export worked (W2, checked in the main app).
    private func probeShield(_ application: Application, context: String) -> ShieldConfiguration {
        let name = application.localizedDisplayName ?? "<nil>"
        let bundle = application.bundleIdentifier ?? "<nil>"
        // Harvest returns the WRITE-STATUS of each export channel, rendered into
        // the shield subtitle (the one channel we know works) so we can tell
        // WHY export fails: entitlement-not-active vs sandbox-blocked vs isolated.
        let status = harvest(application, name: name, bundle: bundle, context: context)
        return ShieldConfiguration(
            backgroundBlurStyle: .systemMaterial,
            backgroundColor: nil,
            icon: nil,
            title: ShieldConfiguration.Label(text: "Evlin E1 probe", color: .label),
            subtitle: ShieldConfiguration.Label(
                text: "\(name) / \(bundle)\n\(status)",
                color: .secondaryLabel
            ),
            primaryButtonLabel: ShieldConfiguration.Label(text: "OK", color: .white),
            primaryButtonBackgroundColor: nil,
            secondaryButtonLabel: nil
        )
    }

    override func configuration(shielding webDomain: WebDomain) -> ShieldConfiguration {
        ShieldConfiguration()
    }

    override func configuration(
        shielding webDomain: WebDomain,
        in category: ActivityCategory
    ) -> ShieldConfiguration {
        ShieldConfiguration()
    }

    // MARK: - Harvest

    @discardableResult
    private func harvest(_ application: Application, name: String, bundle: String, context: String) -> String {
        let ts = ISO8601DateFormatter().string(from: Date())
        let record = "{\"ts\":\"\(ts)\",\"ctx\":\"\(context)\",\"name\":\"\(name)\",\"bundle\":\"\(bundle)\"}"
        NSLog("[Evlin/ShieldConfig] harvest %@", record)

        var parts: [String] = []

        // (1) App Group UserDefaults — write then read back IN-PROCESS. nil-suite
        // means the App Group entitlement isn't active. rt-ok means the suite is
        // functional here (cross-process is then tested by the main app read).
        if let defaults = UserDefaults(suiteName: appGroup) {
            defaults.set(record, forKey: "evlin.shieldconfig.harvest")
            defaults.set("fired \(ts)", forKey: "evlin.shieldconfig.diag")
            let back = defaults.string(forKey: "evlin.shieldconfig.harvest")
            parts.append("UD=" + (back == record ? "rtok" : "rtfail"))
        } else {
            parts.append("UD=nilSuite")
        }

        // (2) App Group file — "permission denied" here = DAR-style sandbox block.
        if let container = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroup) {
            let url = container.appendingPathComponent("shieldconfig-harvest.json")
            do {
                try Data(record.utf8).write(to: url, options: .atomic)
                parts.append("file=ok")
            } catch {
                parts.append("file=" + String(error.localizedDescription.prefix(18)))
            }
        } else {
            parts.append("file=nilCont")
        }

        // (3) Keychain shared access group — -34018 = entitlement missing; 0 = ok.
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: "evlin.shieldconfig.harvest",
            kSecAttrAccessGroup as String: keychainGroup,
        ]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = Data(record.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        parts.append("KC=\(SecItemAdd(add as CFDictionary, nil))")

        return parts.joined(separator: " ")
    }
}
