import FamilyControls
import SwiftUI

/// Kid-home banner for the silent killer: iOS can revoke Screen Time
/// (FamilyControls) authorization out from under a running install —
/// reinstalls, Apple ID churn, or plain iOS whim (observed repeatedly on real
/// hardware, 2026-08-05). Schedules survive the revocation, so every probe
/// stays green while not a single minute can ever be counted or locked. This
/// banner is the user-facing half of the fix (the watchdog's
/// `authorization_revoked` report-only red is the telemetry half): it names
/// the problem and re-requests authorization in place.
struct ScreenTimeOffBanner: View {
    @State private var requesting = false
    /// Parent view re-checks authorization on scene activation; this local
    /// flag just collapses the banner immediately after a successful grant.
    @State private var granted = false

    var body: some View {
        if granted { EmptyView() } else { banner }
    }

    private var banner: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "hourglass.badge.exclamationmark")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.red)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 4) {
                Text("Screen Time access is off")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.primary)
                Text("Evlin can't count screen time or unlock apps until access is turned back on.")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button {
                    Task { await reRequest() }
                } label: {
                    Text(requesting ? "Requesting…" : "Turn back on")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.red)
                }
                .disabled(requesting)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.red.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.red.opacity(0.25), lineWidth: 1)
        )
        .padding(.horizontal, 16)
    }

    private func reRequest() async {
        requesting = true
        defer { requesting = false }
        // Route through the same helper onboarding and settings use, so the
        // member type (`max` → .child, `std` → .individual) can never drift
        // from them. Re-reading the key here once cost the wrong default:
        // this view had its own `"protectionMode"`/`"standard"` pair, which
        // matches nothing the app writes, so a Max family would have been
        // re-prompted with the Standard grant.
        await ScreenTimeManager.shared.requestScreenTimeAuthorization()
        granted = AuthorizationCenter.shared.authorizationStatus == .approved
    }
}
