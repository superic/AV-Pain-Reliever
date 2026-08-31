import SwiftUI
import AppKit

/// AV Pain Reliever's small brand surface — kept narrow on purpose.
///
/// An earlier iteration carried a saturated CLI-style palette
/// (magenta primary, cyan highlight); the user reverted that
/// direction (2026-05-02): the app should look like a plain native
/// macOS utility, no custom accent colors. So this namespace exposes
/// a small set of semantic system colors — success / warn / error
/// for status pills and banner-style errors. Everything else
/// (headers, captions, links, button tints) uses SwiftUI's defaults —
/// `.primary` for body text, `.secondary` for hints, the system
/// accent for prominent buttons.
///
/// `Theme.Symbol` and `Theme.Copy` stay as before — those are
/// product identifiers, not stylistic choices.
enum Theme {
    enum Color {
        /// Save-success affordance, "switched" checkmarks. Maps to
        /// the macOS system green so it tracks the OS appearance.
        static let success = SwiftUI.Color.green
        /// Soft warnings — yellow status pills ("Not connected",
        /// "Suggested: untick"). System orange reads as "caution"
        /// without screaming the way a saturated yellow does.
        static let warn = SwiftUI.Color.orange
        /// Fatal errors — banner backgrounds + the inline triangle
        /// icon. System red, same as Apple's own destructive action
        /// styling.
        static let error = SwiftUI.Color.red
    }

    enum Symbol {
        /// Wizard section icons — keep in lockstep with the section
        /// titles in `AddProfileView`.
        static let nameSection = "tag.fill"
        // Was `cable.connector` — that glyph reads as a stick figure
        // at small sizes (the USB-A connector silhouette is genuinely
        // person-shaped). `externaldrive.connected.to.line.below` is
        // unambiguously "peripheral connected to host" and reads cleanly
        // at caption size.
        static let usbSection = "externaldrive.connected.to.line.below"
        static let audioSection = "speaker.wave.2.fill"
        static let cameraSection = "camera.fill"

        /// Warning thumbnail for operational notifications (config
        /// corruption, unrecoverable load failures).
        static let warning = "exclamationmark.triangle"

        /// Settings → Camera live-preview section header.
        static let livePreviewSection = "eye"
        /// Placeholder glyph in the live-preview card when there's no
        /// session to render (virtual camera off, extension missing,
        /// camera access denied).
        static let previewUnavailable = "video.slash"
    }

    enum Copy {
        /// Tagline shown under the welcome greeting. Keep voice warm,
        /// not corporate; the user-facing personality lives here.
        static let tagline = "Your audio and camera, dialed in automatically."
        /// The app's display name. Use sparingly in user-facing copy
        /// — see the rule below before adding a new reference.
        ///
        /// **Self-naming rule for user-facing strings:**
        /// - **Inside a Settings tab, sheet, alert, or any in-app
        ///   surface** → don't name the app; the frame already
        ///   implies it. *"Enable virtual camera"* not *"Enable
        ///   AV Pain Reliever as a virtual camera."*
        /// - **In a button label that performs an action ON the app
        ///   itself** (Restart, Quit) → name it; "Restart" alone
        ///   could read as "restart macOS" — explicit target wins.
        /// - **When telling the user to do something in ANOTHER
        ///   app** ("Pick X in Zoom") → name it (in quotes); the
        ///   user needs to recognize the exact string in the other
        ///   app's picker.
        /// - **About / Welcome / menu bar / login items /
        ///   notifications** → name it; these are external or
        ///   system-level surfaces where the brand is the point.
        static let appName = "AV Pain Reliever"
    }
}
