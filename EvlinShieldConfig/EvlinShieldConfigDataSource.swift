// EvlinShieldConfig/EvlinShieldConfigDataSource.swift
//
// Evlin's branded lock screen. When iOS renders a shield over an app Evlin has
// locked, it calls this extension's configuration(shielding:) and shows what we
// return here.
//
// IMPORTANT — this is a FIXED system layout. ShieldConfiguration only lets us
// set: a background blur style, ONE background colour, an icon, a title, a
// subtitle, and up to two buttons. There is NO support for gradients, custom
// fonts, custom layout, or background images. So the "Evlin green" look is a
// green-TINTED frosted glass (system blur + a translucent Evlin-green wash),
// the Evlin app icon, and an Evlin-green primary button.
//
// (This file used to be the "E1 probe" harvest extension that rendered raw
//  diagnostics into the shield. That was a test harness — nothing in the
//  production app depends on it, only the Debug-only ShieldHarvestProbeView —
//  so it has been replaced with the real branded shield.)
import ManagedSettings
import ManagedSettingsUI
import UIKit

final class EvlinShieldConfigDataSource: ShieldConfigurationDataSource {

    /// Evlin brand forest green — matches `Color.evSecondary` (0x2E7D32) in the
    /// main app.
    private static let evlinGreen = UIColor(
        red: 0x2E / 255.0, green: 0x7D / 255.0, blue: 0x32 / 255.0, alpha: 1.0
    )

    override func configuration(shielding application: Application) -> ShieldConfiguration {
        evlinShield()
    }

    override func configuration(
        shielding application: Application,
        in category: ActivityCategory
    ) -> ShieldConfiguration {
        evlinShield()
    }

    override func configuration(shielding webDomain: WebDomain) -> ShieldConfiguration {
        evlinShield()
    }

    override func configuration(
        shielding webDomain: WebDomain,
        in category: ActivityCategory
    ) -> ShieldConfiguration {
        evlinShield()
    }

    // MARK: - Branded shield

    private func evlinShield() -> ShieldConfiguration {
        ShieldConfiguration(
            // Green-tinted frosted glass: a dark system blur base with a
            // translucent Evlin-green wash on top. Alpha < 1 keeps the glassy
            // translucency; raise it toward 1.0 for a more solid green.
            backgroundBlurStyle: .systemThinMaterialDark,
            backgroundColor: Self.evlinGreen.withAlphaComponent(0.60),
            icon: Self.evlinIcon(),
            title: ShieldConfiguration.Label(
                text: "Pssst… break time!",
                color: .white
            ),
            // Evlin's mascot talks straight TO the kid — playful, first person,
            // simple — and stays neutral on the reason (a lock isn't always about
            // unfinished tasks; it may be a reflection or a parent-initiated
            // lock), so it points the kid back to Evlin instead of asserting why.
            // The leading "\n" buys a title↔subtitle gap — ShieldConfiguration
            // has no spacing API. (Reason-specific copy can come later via App
            // Group.)
            subtitle: ShieldConfiguration.Label(
                text: "\nI’ve tucked this app in for a quick nap. Open Evlin and let’s see what’s next!",
                color: UIColor.white.withAlphaComponent(0.85)
            ),
            primaryButtonLabel: ShieldConfiguration.Label(text: "Got it", color: .white),
            primaryButtonBackgroundColor: Self.evlinGreen,
            // Placeholder only: the button shows, but the request flow isn't
            // wired yet (that needs a separate ShieldAction extension target —
            // see investigation notes). Tapping it currently does nothing
            // beyond the system default.
            secondaryButtonLabel: ShieldConfiguration.Label(
                text: "Ask for more time on this app",
                color: .white
            )
        )
    }

    /// The Evlin mascot, handed across from the main app via the shared App
    /// Group (the extension can't read the main app's asset catalog, and only
    /// App Group UserDefaults is reliable inside this extension). Published by
    /// `EvlinShieldIconPublisher.publish()` on app launch, pre-padded with a
    /// transparent strip below so it sits a little above the title. Returns nil
    /// until the app has run once — iOS then shows its default glyph, so the
    /// green frosted glass + copy still render.
    private static func evlinIcon() -> UIImage? {
        guard
            let defaults = UserDefaults(suiteName: "group.com.evlin.ios"),
            let data = defaults.data(forKey: "evlin.shield.icon")
        else { return nil }
        // Published at scale 1 / 144px; reload at scale 2 so it renders ~72pt.
        return UIImage(data: data, scale: 2.0)
    }
}
