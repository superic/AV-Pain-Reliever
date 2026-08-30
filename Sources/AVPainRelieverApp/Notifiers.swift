import Foundation
import AppKit
import UserNotifications

/// Identifies which action-button label to attach to a notification.
/// UN's action API requires categories registered up-front (you can't
/// set a button title per-call), so callers pick one of the pre-
/// registered cases instead of passing free text.
public enum NotificationAction {
    /// "Open Wizard" - jumps into the Add Profile flow. Used by the
    /// unknown-location toast.
    case openWizard
    /// "Show in Finder" - reveals a URL in Finder. Used by the
    /// config-corrupted toast to surface the moved-aside file.
    case showInFinder
}

/// Surface a transient banner-style notification to the user. The
/// engine never instantiates a notifier; the app target picks the
/// bundled vs unbundled backend, and tests inject a recording mock.
public protocol Notifier {
    /// Post a notification with an optional thumbnail icon and inline
    /// action button.
    ///
    /// `iconSymbol` is an optional SF Symbol name; when supplied,
    /// backends that support it render the symbol as a thumbnail
    /// attached to the notification. Backends that can't surface a
    /// thumbnail simply post the title + body unchanged.
    ///
    /// `action` and `onAction` are paired. `action` picks the button
    /// label from the pre-registered set; `onAction` fires when the
    /// user clicks the button. Backends that can't render action
    /// buttons (AppleScript fallback) drop both. Pass `nil` for both
    /// to post a plain toast.
    ///
    /// `completion` fires on the main thread once the backend has
    /// handed the notification off to the system — accepted, rejected,
    /// or dropped because the backend can't post at all. It is *not* a
    /// promise the banner was displayed (a user who denied
    /// authorization gets no banner and no error). Callers that are
    /// about to quit the app use it so they don't race their own
    /// termination; everyone else passes nil.
    func notify(
        title: String,
        body: String?,
        iconSymbol: String?,
        action: NotificationAction?,
        onAction: (() -> Void)?,
        completion: (() -> Void)?
    )
}

extension Notifier {
    /// Convenience for action-less, icon-less notifications.
    public func notify(title: String, body: String?) {
        notify(title: title, body: body, iconSymbol: nil, action: nil, onAction: nil, completion: nil)
    }

    /// Convenience for a notification with just an icon thumbnail.
    public func notify(title: String, body: String?, iconSymbol: String?) {
        notify(title: title, body: body, iconSymbol: iconSymbol, action: nil, onAction: nil, completion: nil)
    }

    /// Convenience for the fire-and-forget action case — the spelling
    /// every call site except the pre-quit notice uses.
    public func notify(
        title: String,
        body: String?,
        iconSymbol: String?,
        action: NotificationAction?,
        onAction: (() -> Void)?
    ) {
        notify(
            title: title, body: body, iconSymbol: iconSymbol,
            action: action, onAction: onAction, completion: nil
        )
    }
}

/// Production notifier inside a signed `.app` bundle. Uses
/// `UNUserNotificationCenter` so notifications post under the app's
/// own identity — they show our `Resources/AppIcon.icns` instead of
/// Script Editor's plug, and clicking dismisses cleanly without
/// dragging the user into a file picker the way `osascript`-posted
/// notifications do.
///
/// Authorization is requested at init (best-effort; if the user
/// denies, our `notify` calls become silent no-ops). The
/// `Settings → Send notifications` toggle still gates whether we
/// even *try* to post — denying both layers is intentional.
public final class UserNotificationsNotifier: NSObject, Notifier, UNUserNotificationCenterDelegate {
    /// Pre-registered action categories. UN requires categories
    /// up-front; you can't set a button title per-call. Each case in
    /// `NotificationAction` maps to one of these category IDs.
    private static let openWizardCategoryID = "av-pain-reliever.openWizard"
    private static let showInFinderCategoryID = "av-pain-reliever.showInFinder"
    private static let openWizardActionID = "av-pain-reliever.action.openWizard"
    private static let showInFinderActionID = "av-pain-reliever.action.showInFinder"

    /// Open-action handler keyed by request UUID. We hold each
    /// closure until the corresponding notification is dismissed or
    /// acted on; expired entries get pruned via Notification
    /// Center's didReceive callback.
    private var actionHandlers: [String: () -> Void] = [:]
    private let handlersQueue = DispatchQueue(label: "com.ericwillis.avpainreliever.notifier.handlers")

    public override init() {
        super.init()
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        // Request alert + sound. We don't ask for badge — the app is
        // a menu-bar agent and has no Dock tile to badge.
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in
            // Outcome is best-effort; failures and denials are
            // surfaced through the toggle being a no-op rather
            // than logged. The system's own Notification Center
            // settings UI is the place to fix this.
        }
        // Register one category per `NotificationAction` case. UN
        // requires categories up-front and won't accept per-call
        // button titles; the call site picks a category by enum case.
        let openWizard = UNNotificationCategory(
            identifier: Self.openWizardCategoryID,
            actions: [UNNotificationAction(
                identifier: Self.openWizardActionID,
                title: "Open Wizard",
                options: [.foreground]
            )],
            intentIdentifiers: [],
            options: []
        )
        let showInFinder = UNNotificationCategory(
            identifier: Self.showInFinderCategoryID,
            actions: [UNNotificationAction(
                identifier: Self.showInFinderActionID,
                title: "Show in Finder",
                options: [.foreground]
            )],
            intentIdentifiers: [],
            options: []
        )
        center.setNotificationCategories([openWizard, showInFinder])
    }

    public func notify(
        title: String,
        body: String?,
        iconSymbol: String?,
        action: NotificationAction?,
        onAction: (() -> Void)?,
        completion: (() -> Void)?
    ) {
        let content = UNMutableNotificationContent()
        content.title = title
        if let body { content.body = body }
        content.sound = .default

        // Pick the pre-registered category matching the requested
        // action. UN doesn't accept per-call button labels.
        if let action {
            switch action {
            case .openWizard:
                content.categoryIdentifier = Self.openWizardCategoryID
            case .showInFinder:
                content.categoryIdentifier = Self.showInFinderCategoryID
            }
        }

        // When the caller supplied an SF Symbol name, render it to a
        // temp PNG and attach it. macOS shows the attachment as a
        // thumbnail next to the title — gives the toast a per-profile
        // visual signal alongside the standard app icon. UN moves the
        // file into its own storage on `add(...)`, so we don't have
        // to clean up the temp path ourselves.
        if let iconSymbol, let url = Self.renderIconAttachment(symbol: iconSymbol) {
            if let attachment = try? UNNotificationAttachment(
                identifier: "icon",
                url: url,
                options: nil
            ) {
                content.attachments = [attachment]
            }
        }

        let identifier = UUID().uuidString
        if let onAction {
            handlersQueue.sync { actionHandlers[identifier] = onAction }
        }

        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: nil  // fire immediately
        )
        UNUserNotificationCenter.current().add(request) { [weak self] error in
            if error != nil {
                // Drop the stashed handler so we don't leak it forever.
                self?.handlersQueue.sync { _ = self?.actionHandlers.removeValue(forKey: identifier) }
            }
            // UN delivers this on a private queue; callers (a pre-quit
            // relaunch, notably) expect main. Fires for the rejected
            // case too — the point is "the system has our request, or
            // never will", not "a banner appeared".
            guard let completion else { return }
            DispatchQueue.main.async(execute: completion)
        }
    }

    /// Render an SF Symbol on a charcoal circular background to a
    /// temp PNG file and return its URL. Sized 256×256 — macOS
    /// downscales for the actual notification thumbnail. Returns nil
    /// on the unhappy path (symbol not found, encode/write failure);
    /// callers fall back to a plain notification.
    private static func renderIconAttachment(symbol: String) -> URL? {
        let size = NSSize(width: 256, height: 256)
        let image = NSImage(size: size)
        image.lockFocus()

        // Charcoal disc — same hue family as the new app icon's
        // background gradient stop, so the thumbnail reads as part of
        // the same visual system.
        NSColor(red: 0.180, green: 0.188, blue: 0.204, alpha: 1.0).set()
        NSBezierPath(ovalIn: NSRect(origin: .zero, size: size)).fill()

        // White SF Symbol centred at ~50% of canvas.
        let config = NSImage.SymbolConfiguration(pointSize: 130, weight: .semibold)
        if let template = NSImage(
            systemSymbolName: symbol,
            accessibilityDescription: nil
        )?.withSymbolConfiguration(config) {
            // SF Symbols come as template (alpha-mask) images. Tint by
            // filling a fresh image with white, then `destinationIn`
            // through the symbol mask to get a proper white symbol.
            let tinted = NSImage(size: template.size)
            tinted.lockFocus()
            NSColor.white.set()
            NSRect(origin: .zero, size: template.size).fill()
            template.draw(
                in: NSRect(origin: .zero, size: template.size),
                from: .zero,
                operation: .destinationIn,
                fraction: 1.0
            )
            tinted.unlockFocus()

            let origin = NSPoint(
                x: (size.width - tinted.size.width) / 2,
                y: (size.height - tinted.size.height) / 2
            )
            tinted.draw(
                at: origin,
                from: .zero,
                operation: .sourceOver,
                fraction: 1.0
            )
        }

        image.unlockFocus()

        guard
            let tiff = image.tiffRepresentation,
            let rep = NSBitmapImageRep(data: tiff),
            let png = rep.representation(using: .png, properties: [:])
        else {
            return nil
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("av-notify-icon-\(UUID().uuidString).png")
        do {
            try png.write(to: url)
            return url
        } catch {
            return nil
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler:
            @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // Show banner + play sound while the app is foregrounded.
        // Without this delegate method, foreground notifications
        // are silently swallowed by the system.
        completionHandler([.banner, .sound])
    }

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let identifier = response.notification.request.identifier
        let handler = handlersQueue.sync { actionHandlers.removeValue(forKey: identifier) }
        let isActionTap = response.actionIdentifier == Self.openWizardActionID
            || response.actionIdentifier == Self.showInFinderActionID
        if isActionTap, let handler {
            // Hop to main since handlers typically touch SwiftUI or
            // NSWorkspace. UN delivers on a private queue.
            DispatchQueue.main.async {
                handler()
            }
        }
        // For default tap (UNNotificationDefaultActionIdentifier) and
        // dismiss (UNNotificationDismissActionIdentifier), do nothing
        // — the OS will activate the app for default-action, which
        // for our LSUIElement agent is a no-op surface.
        completionHandler()
    }
}

/// `swift run` dev fallback notifier that shells out to `osascript`
/// to display a notification. Works without a bundle identifier —
/// `osascript` posts as itself, which the user has already approved
/// (or will be prompted to approve once) for notifications.
///
/// `UNUserNotificationCenter` (the production path in
/// `UserNotificationsNotifier` above) requires a bundle id, so it
/// rejects unbundled processes outright. AppDelegate picks this
/// implementation when `Bundle.main.bundleIdentifier` is nil — i.e.
/// the `swift run AVPainRelieverApp` dev-loop case. The signed
/// `.app` always uses `UserNotificationsNotifier`. Action buttons,
/// custom icons, and `onAction` callbacks aren't supported here —
/// `osascript` only renders title + body.
public struct AppleScriptNotifier: Notifier {
    public init() {}

    public func notify(
        title: String,
        body: String?,
        iconSymbol: String?,
        action: NotificationAction?,
        onAction: (() -> Void)?,
        completion: (() -> Void)?
    ) {
        // osascript notifications can't render an action button or a
        // custom thumbnail. Ignore those extras and post a plain toast.
        _ = (iconSymbol, action, onAction)
        notifyPlain(title: title, body: body)
        // `notifyPlain` waits on the osascript process, so by here the
        // system has it (or the shell-out failed and never will).
        completion?()
    }

    private func notifyPlain(title: String, body: String?) {
        // AppleScript `display notification` requires a non-empty
        // body string; the title is the second clause. If callers
        // pass body=nil we surface just the title in the body slot.
        let bodyText = body ?? title
        let titleClause = " with title \"\(escape(title))\""
        let script = "display notification \"\(escape(bodyText))\"\(titleClause)"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        // Discard stdout/stderr — notifications are best-effort, we
        // don't want the engine to log a noisy warning when osascript
        // fails (sometimes it does on boot when WindowServer isn't
        // ready yet).
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            // Swallow — see comment above.
        }
    }

    private func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
