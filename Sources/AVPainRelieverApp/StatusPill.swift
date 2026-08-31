import SwiftUI

/// Compact tinted capsule used for at-a-glance status badges
/// across the app: "Active" on the running profile row,
/// "Debug override" on the virtual-camera status row,
/// "Not connected" / "Travels with you" / "Important: <category>"
/// on wizard device rows.
///
/// White text on a saturated tint reads cleanly in both light
/// and dark mode. Earlier wizard pills used `.black` text on a
/// 0.85-opacity tint; that contrast degraded in dark mode where
/// the tint dimmed toward the background. Settling on a single
/// idiom (full-opacity tint, white text) keeps the pills legible
/// in both appearances and removes the visual drift between the
/// settings pills and the wizard pills.
struct StatusPill: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tint, in: Capsule())
    }
}

/// The 8pt tinted dot that leads a one-line status sentence — the
/// virtual-camera extension state row and the live-preview feed row
/// both use it. Extracted so the two rows can't drift apart in size
/// or shape.
struct StatusDot: View {
    let tint: Color

    var body: some View {
        Circle()
            .fill(tint)
            .frame(width: 8, height: 8)
    }
}
