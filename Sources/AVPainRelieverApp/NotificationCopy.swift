import Foundation

/// Picks a friendly notification title for a given profile slug.
///
/// Default behavior is "use the pretty-cased name" — that's the safe,
/// trustworthy macOS default. Common slug families (home, work, café)
/// get 2-4 warmer alternates rotated deterministically by day-of-year
/// so the toast varies between days but doesn't whiplash within a
/// single dock-undock cycle.
///
/// The randomness is *deterministic on day-of-year* on purpose: across
/// a single workday, every dock event for the same location gives the
/// same title. Tomorrow it might rotate to a different one. This keeps
/// the personality from feeling glitchy or attention-grabbing.
enum NotificationCopy {
    /// Pretty title for the toast that announces a profile change.
    /// `body` should stay constant ("Audio + camera switched") — the
    /// title is where personality lives.
    static func title(forSlug slug: String, dayOfYear: Int) -> String {
        let pretty = PrettyName.format(slug)
        let alternates = alternates(forSlug: slug.lowercased(), pretty: pretty)
        guard !alternates.isEmpty else { return pretty }
        let index = abs(dayOfYear) % alternates.count
        return alternates[index]
    }

    /// Convenience using today's day-of-year. Falls back to the pretty
    /// name if the calendar can't produce a day-of-year (shouldn't
    /// happen on macOS).
    static func title(forSlug slug: String) -> String {
        let calendar = Calendar(identifier: .gregorian)
        let day = calendar.ordinality(of: .day, in: .year, for: Date()) ?? 0
        return title(forSlug: slug, dayOfYear: day)
    }

    /// Title for the "your profiles.toml was corrupt; we renamed it"
    /// toast. Operational, not playful: the user needs to know what
    /// happened so they can recover.
    static let configCorruptedTitle = "Couldn't read profiles.toml"

    /// Body for the same toast. Names the renamed copy so a user who
    /// dismisses the toast before clicking Show in Finder still has a
    /// filename to grep for.
    static func configCorruptedBody(filename: String) -> String {
        "Saved the broken copy as \(filename) right next to it. Started fresh from defaults."
    }

    /// Title for the worst-case branch: parse failed AND we couldn't
    /// move the file aside (filesystem error, read-only parent).
    /// Engine runs with an empty profile list until the user resolves
    /// it.
    static let configUnrecoverableTitle = "Couldn't recover profiles.toml"

    /// Body for the worst-case branch. Points at the Advanced menu's
    /// Save Logs for Support entry.
    static let configUnrecoverableBody = "Use Advanced > Save Logs for Support and send us the log."

    /// Title for the automatic-restart notice (issue #120). Names the
    /// app: the user is about to watch it quit and come back, and the
    /// notification is an external surface where the brand is the
    /// point (see `Theme.Copy.appName`).
    static let cameraSelfRestartTitle = "Restarting AV Pain Reliever"

    /// Body for the same notice. Says what broke in plain terms, that
    /// the fix is already running, and that the camera selection in
    /// other apps survives it — the user's next thought is "do I have
    /// to re-pick anything in Zoom?"
    static let cameraSelfRestartBody = "macOS hid the virtual camera from this app. Reopening to pick it back up — nothing to re-select in your video apps."

    /// Body text for the "new location detected" toast — warmer than
    /// the bare "N USB devices attached" version, while still telling
    /// the user the next concrete action they can take.
    static func unknownLocationBody(deviceCount: Int) -> String {
        switch deviceCount {
        case 0:
            return "Open the menu to set it up."
        case 1:
            return "1 USB device joined the party. Open the menu to teach me this spot."
        default:
            return "\(deviceCount) USB devices joined the party. Open the menu to teach me this spot."
        }
    }

    private static func alternates(forSlug slug: String, pretty: String) -> [String] {
        if slug.hasPrefix("home") {
            return [pretty, "Home, sweet home", "Welcome back home", "Home base"]
        }
        if slug.hasPrefix("work") || slug.contains("office") {
            return [pretty, "Work mode", "At the office", "Hello, work"]
        }
        if slug.contains("cafe") || slug.contains("coffee") {
            return [pretty, "Coffee shop vibes", "Café mode"]
        }
        if slug.hasPrefix("studio") {
            return [pretty, "Studio time", "Tracking now"]
        }
        if slug == "laptop" || slug.hasPrefix("laptop") || slug.hasPrefix("undocked") {
            return [pretty, "Untethered", "Laptop life"]
        }
        if slug.hasPrefix("conference") || slug.contains("meeting") {
            return [pretty, "Meeting mode", "Conference room"]
        }
        return [pretty]
    }
}
