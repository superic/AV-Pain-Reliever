import SwiftUI
import AppKit
import AVPainReliever

/// Stable identifier used to open and dismiss the wizard window.
let addProfileWindowID = "add-profile"

@main
struct AVPainRelieverApp: SwiftUI.App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // Both `label` and `content` MUST be Views that take the
        // AppDelegate as @ObservedObject — referencing
        // appDelegate.currentProfileTitle directly inside the Scene's
        // body does NOT re-render the MenuBarExtra label when the
        // @Published property changes. View-level dependency tracking
        // is what makes the live update work.
        MenuBarExtra {
            MenuContentView(delegate: appDelegate)
            // Hidden helpers — observe AppDelegate flags and open the
            // matching window. Live inside MenuBarExtra so SwiftUI's
            // openWindow environment is available; menu items render
            // fine alongside.
            WelcomeOpener(delegate: appDelegate)
            AddProfileOpener(delegate: appDelegate)
        } label: {
            MenuLabelView(delegate: appDelegate, settings: appDelegate.settings)
        }
        .menuBarExtraStyle(.menu)

        Window("Add Profile", id: addProfileWindowID) {
            AddProfileWindowContent(delegate: appDelegate)
        }
        .windowResizability(.contentSize)

        // macOS's dedicated Settings scene — renders with the
        // System-Settings-style toolbar tab chrome (white-container
        // segmented control) that a generic Window scene doesn't
        // produce for LSUIElement apps. Triggered programmatically
        // via NSApp.sendAction(showSettingsWindow:) below; ⌘, on
        // the menu item invokes the same path.
        Settings {
            SettingsView(delegate: appDelegate, settings: appDelegate.settings)
        }

        Window("About", id: aboutWindowID) {
            AboutWindowContent(delegate: appDelegate)
        }
        .windowResizability(.contentSize)

        Window("Welcome", id: welcomeWindowID) {
            WelcomeWindowContent(delegate: appDelegate)
        }
        .windowResizability(.contentSize)
    }
}

/// Invisible view inside the menu scene whose only job is to react to
/// `appDelegate.shouldShowWelcome` and open the welcome window via the
/// SwiftUI environment. Keeping the openWindow trigger inside a real
/// View is the cleanest way to bridge AppDelegate (no environment
/// access) → SwiftUI's openWindow API.
private struct WelcomeOpener: View {
    @ObservedObject var delegate: AppDelegate
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onChange(of: delegate.shouldShowWelcome) { _, show in
                if show {
                    openWindow(id: welcomeWindowID)
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
    }
}

/// Sibling of `WelcomeOpener`: routes the AppDelegate's
/// `shouldOpenAddProfileWindow` flag (set by the unknown-location
/// notification's "Open Wizard" action) through SwiftUI's
/// `openWindow`, then resets the flag so the next click re-fires.
private struct AddProfileOpener: View {
    @ObservedObject var delegate: AppDelegate
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onChange(of: delegate.shouldOpenAddProfileWindow) { _, shouldOpen in
                guard shouldOpen else { return }
                delegate.beginAddingProfile()
                openWindow(id: addProfileWindowID)
                NSApp.activate(ignoringOtherApps: true)
                delegate.shouldOpenAddProfileWindow = false
            }
    }
}

private struct WelcomeWindowContent: View {
    @ObservedObject var delegate: AppDelegate
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        WelcomeView(
            onAddProfile: {
                delegate.dismissWelcome()
                delegate.beginAddingProfile()
                openWindow(id: addProfileWindowID)
                NSApp.activate(ignoringOtherApps: true)
                dismissWindow(id: welcomeWindowID)
            },
            onSkip: {
                delegate.dismissWelcome()
                dismissWindow(id: welcomeWindowID)
            }
        )
        // Mirrors the AboutWindowContent pattern: the open-token forces
        // SwiftUI to tear down + rebuild WelcomeView every time the
        // window is re-shown, resetting the confetti `@State` so the
        // burst plays fresh on each open.
        .id(delegate.welcomeOpenToken)
    }
}

private struct MenuLabelView: View {
    @ObservedObject var delegate: AppDelegate
    @ObservedObject var settings: SettingsStore

    var body: some View {
        if delegate.atUnknownLocation {
            // The fallback profile name (typically "Laptop") would
            // imply "I'm undocked" — but the user is at a new dock
            // we don't recognise. Make that visible so they don't
            // assume the app is misbehaving. The "New location"
            // text is shown unconditionally because it's the only
            // signal we have for this state — the question-mark
            // icon alone reads as "is the app broken?"
            Image(systemName: "questionmark.circle")
            Text("New location")
        } else {
            Image(systemName: menuBarIcon)
            if settings.showProfileNameInMenuBar {
                Text(delegate.currentProfileTitle)
            }
        }
    }

    /// Resolved SF Symbol for the menu bar. Defaults to the user's
    /// pick from Settings → General → "Menu bar icon" (initially the
    /// product's `pills.fill` brand glyph). When the user opts in via
    /// Settings → General and an active profile is known, swaps in
    /// that profile's effective icon (user override → slug
    /// auto-mapper → fallback pin), matching what the "Switch to"
    /// submenu and Profiles list render.
    private var menuBarIcon: String {
        guard
            settings.showProfileIconInMenuBar,
            let slug = delegate.activeProfileSlug,
            let profile = delegate.availableProfiles.first(where: { $0.name == slug })
        else {
            return settings.menuBarIconSymbol
        }
        return ProfileIcon.effectiveSymbol(for: slug, override: profile.icon)
    }
}

private struct MenuContentView: View {
    @ObservedObject var delegate: AppDelegate
    @Environment(\.openWindow) private var openWindow
    /// macOS 14+ way to programmatically open the SwiftUI Settings
    /// scene. The AppKit-selector approach (showSettingsWindow:)
    /// silently no-ops for LSUIElement apps because there's no
    /// responder chain to route the action through.
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        // No persistent header. The active profile name is already
        // visible on the menu bar pill itself, the Switch to submenu
        // marks the active row with a checkmark, and audio/camera
        // detail lives in Settings → Profiles. Removing the header
        // keeps the menu focused on actions and avoids fighting the
        // disabled-NSMenuItem dim treatment that comes with non-
        // interactive items in NSMenu.
        bodyActions
    }

    @ViewBuilder
    private var bodyActions: some View {
        if delegate.atUnknownLocation {
            // Visually prominent affordance — same destination as
            // Add Profile… below, but framed as the obvious next
            // step. The wizard pre-selects all currently-attached
            // devices anyway, so the user just needs to pick a name
            // and hit Save.
            //
            // Label kept short ("Set Up Location…" not "Set Up THIS
            // Location…") because SwiftUI's MenuBarExtra(.menu) sizes
            // the underlying NSMenu on first render and doesn't widen
            // when conditional items appear later — a longer string
            // ended up middle-truncated as "Set Up...ocation…" once
            // the rest of the menu had been measured without it.
            Button {
                delegate.beginAddingProfile()
                openWindow(id: addProfileWindowID)
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Label("Set Up Location…", systemImage: "plus.circle.fill")
            }
            // Escape hatch: this device combination isn't a place
            // the user wants profiles for (a friend's desk, a
            // hotel dock). Records the fingerprint so subsequent
            // plug-ins don't re-prompt; un-ignore lives in
            // Settings → Profiles.
            Button {
                delegate.ignoreCurrentUnknownLocation()
            } label: {
                Label("Not a Location", systemImage: "xmark.circle")
            }
            Divider()
        }

        if !delegate.availableProfiles.isEmpty {
            Menu {
                ForEach(delegate.availableProfiles, id: \.name) { profile in
                    profileMenuEntry(profile)
                }
                Divider()
                Button {
                    // Pre-select the Profiles tab before opening so
                    // the user lands on the list directly. The reset
                    // to General fires on the next *close*, so this
                    // override survives the open about to happen.
                    delegate.settingsTab = .profiles
                    openSettings()
                    NSApp.activate(ignoringOtherApps: true)
                } label: {
                    Label("Edit Profiles…", systemImage: "list.bullet.rectangle")
                }
            } label: {
                Label("Switch to", systemImage: "arrow.left.arrow.right")
            }
            Divider()
        }

        Button {
            delegate.beginAddingProfile()
            openWindow(id: addProfileWindowID)
            // Accessory apps (LSUIElement-style) don't auto-activate
            // when a window opens — the new window appears behind
            // whatever was focused. Force-activate so the wizard is
            // immediately usable without an extra click.
            NSApp.activate(ignoringOtherApps: true)
        } label: {
            Label("Add Profile…", systemImage: "plus")
        }
        .keyboardShortcut("n")

        Divider()

        Button {
            // Bump the About scene's open-token before showing it so
            // the view tree rebuilds and the confetti burst replays.
            delegate.willOpenAbout()
            openWindow(id: aboutWindowID)
            NSApp.activate(ignoringOtherApps: true)
        } label: {
            Label("About", systemImage: "info.circle")
        }

        Button {
            openSettings()
            NSApp.activate(ignoringOtherApps: true)
        } label: {
            Label("Settings…", systemImage: "gearshape")
        }
        .keyboardShortcut(",")

        // Power-user / diagnostic actions live under Advanced so the
        // top-level menu stays focused on the things people actually
        // use day-to-day (Switch / Add / Settings). The earlier
        // "Re-evaluate Now" and "Reload Config" entries lived here
        // too — both are gone: USB events drive evaluation
        // automatically, and `ProfileConfigWatcher` reloads the
        // engine on any out-of-band edit to `profiles.toml`.
        Menu {
            Button {
                delegate.checkForUpdates()
            } label: {
                Label("Check for Updates…", systemImage: "arrow.down.circle")
            }
            Button {
                // Surface the os.Logger stream by opening Console.app.
                // The log stream filter for our subsystem can be applied
                // there manually; deep-linking to a filtered view requires
                // a private URL scheme we don't want to bake in.
                let consoleURL = URL(fileURLWithPath: "/System/Applications/Utilities/Console.app")
                NSWorkspace.shared.openApplication(at: consoleURL, configuration: .init())
            } label: {
                Label("Reveal Log in Console", systemImage: "terminal")
            }
            Button {
                LogExporter.saveLogsWithPrompt()
            } label: {
                Label("Save Logs for Support…", systemImage: "square.and.arrow.up.on.square")
            }
        } label: {
            Label("Advanced", systemImage: "wrench.and.screwdriver")
        }

        Divider()

        Button("Quit") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    /// Each profile entry inside the "Switch to" submenu. Clicking
    /// switches immediately — single-click is the right interaction
    /// for "switch to". Edit/Delete live in Settings → Profiles.
    ///
    /// Layout: leading SF Symbol icon (the profile's chosen icon, or
    /// the slug-driven auto-pick if none is set), then the pretty
    /// name. The active profile renders bold — the macOS-native cue
    /// for "this is the current selection" (see System Settings
    /// sidebar, Calendar's left rail). No checkmark: with a real
    /// icon column, the bold weight + icon is enough signal, and
    /// dropping the checkmark frees a column without losing clarity.
    @ViewBuilder
    private func profileMenuEntry(_ profile: Profile) -> some View {
        let pretty = PrettyName.format(profile.name)
        let isActive = profile.name == delegate.activeProfileSlug
        let iconSymbol = ProfileIcon.effectiveSymbol(
            for: profile.name,
            override: profile.icon
        )
        Button {
            // Click switches to the profile immediately. Editing
            // lives in Settings → Profiles (and the menu's
            // `Edit Profiles…` shortcut routes there directly).
            delegate.applyManually(profile)
        } label: {
            // Per-profile SF Symbol in NSMenu's image column; the
            // AttributedString in the title carries the per-run
            // weight (semibold when active) that NSMenuItem honours
            // via `attributedTitle`.
            Label {
                Text(menuLabel(pretty: pretty, isActive: isActive))
            } icon: {
                Image(systemName: iconSymbol)
            }
        }
    }

    /// Build the AttributedString shown in a "Switch to" submenu row.
    /// Just the profile name, semibold when active. The audio + camera
    /// summary used to live here on a sub-line, but moved up to the
    /// main menu's header for the active profile — duplicating it on
    /// every Switch to row was redundant once the header carried it.
    /// Alignment with `Edit Profiles…` is handled by the menu's image
    /// column (see `profileMenuEntry`).
    private func menuLabel(
        pretty: String,
        isActive: Bool
    ) -> AttributedString {
        var label = AttributedString(pretty)
        if isActive {
            label.font = .body.weight(.semibold)
        }
        return label
    }

}

/// Wrapper view inside the About Window scene. Mirrors the wizard
/// pattern below: takes the AppDelegate as `@ObservedObject` so the
/// Scene-level `.id(token)` actually picks up new tokens. Reading
/// `appDelegate.aboutOpenToken` directly inside the Scene body does
/// NOT work — `@NSApplicationDelegateAdaptor` at the App level
/// doesn't make the Scene re-evaluate on `@Published` changes; only
/// a View with `@ObservedObject` does.
private struct AboutWindowContent: View {
    @ObservedObject var delegate: AppDelegate

    var body: some View {
        AboutView(delegate: delegate)
            .id(delegate.aboutOpenToken)
    }
}

/// Wrapper view inside the Add-Profile Window scene. Watches the
/// AppDelegate's `wizardOpenToken` and stamps it as a SwiftUI `.id`
/// on the child form. When the token changes (i.e. the user opens
/// the wizard for a new Add or Edit session), SwiftUI tears down the
/// prior subtree — including its `@StateObject` view model — and
/// builds a fresh one with the current `addProfileDependencies()`.
///
/// Without the `.id` dance, SwiftUI's StateObject lifetime is tied
/// to the surrounding view's identity, which the Window scene
/// preserves across open/dismiss cycles. The result was that the
/// second wizard open (e.g. Edit after Add, or Add after Edit)
/// reused the prior session's view model and silently ignored the
/// new `editing:` argument.
private struct AddProfileWindowContent: View {
    @ObservedObject var delegate: AppDelegate
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        WizardForm(
            delegate: delegate,
            onDismiss: { dismissWindow(id: addProfileWindowID) }
        )
        .id(delegate.wizardOpenToken)
        .dialogWindowChrome()
    }
}

/// Inner wizard view — owns the `AddProfileViewModel` as a
/// `@StateObject`. Recreated by SwiftUI whenever its parent
/// re-stamps the `.id` with a new wizard-session token.
private struct WizardForm: View {
    @ObservedObject var delegate: AppDelegate
    let onDismiss: () -> Void
    @StateObject private var viewModel: AddProfileViewModel

    init(delegate: AppDelegate, onDismiss: @escaping () -> Void) {
        self.delegate = delegate
        self.onDismiss = onDismiss
        let deps = delegate.addProfileDependencies()
        _viewModel = StateObject(wrappedValue: AddProfileViewModel(
            watcher: deps.watcher,
            audioController: deps.audioController,
            cameraController: deps.cameraController,
            configURL: deps.configURL,
            editing: deps.editing,
            existingProfileSlugs: deps.existingProfileSlugs,
            otherProfiles: deps.otherProfiles,
            virtualCameraEnabled: deps.virtualCameraEnabled,
            settings: deps.settings,
            onSaved: deps.onSaved
        ))
    }

    var body: some View {
        AddProfileView(viewModel: viewModel, dismiss: onDismiss)
            // The wizard reads `cameras` once at init time. If the
            // user opens the wizard while the Camera Extension is
            // still activating (or before the host has TCC-grant
            // settled), the embedded virtual camera is missing from
            // the picker. Re-pull the device lists when the
            // activator transitions to `.on` so a wizard already on
            // screen catches up without the user having to click
            // Refresh.
            .onReceive(delegate.virtualCameraActivator.$state) { state in
                if case .on = state { viewModel.refresh() }
            }
    }
}
