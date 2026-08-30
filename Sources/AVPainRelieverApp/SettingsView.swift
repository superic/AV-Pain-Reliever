import SwiftUI
import AppKit
import AVPainReliever

/// Stable identifiers for the Settings tabs. Bound to the TabView's
/// selection so callers (e.g. the menu's "Edit Profiles…" item) can
/// pre-select a tab before opening the window. Reset to `.general`
/// every time the Settings window closes (see `onDisappear` below),
/// so a fresh open always starts on General unless a caller
/// explicitly pre-selected another tab.
enum SettingsTab: Hashable {
    case general
    case profiles
    case camera
    case stats
}

/// The Settings scene has four tabs: General (toggles + slider),
/// Profiles (list with edit/delete), Camera (virtual camera
/// install/enable + status), and Stats (opt-in local usage
/// counters). Deliberately *no* mention of any third-party tool —
/// the app must read as its own product.
///
/// Hosted inside SwiftUI's dedicated `Settings { ... }` scene rather
/// than a generic `Window` scene so the TabView gets the System-
/// Settings-style toolbar tab chrome (white-container segmented
/// control). A generic Window scene rendered the bare-tabs-in-
/// titlebar variant under LSUIElement, which read as styling drift.
struct SettingsView: View {
    @ObservedObject var delegate: AppDelegate
    @ObservedObject var settings: SettingsStore

    var body: some View {
        TabView(selection: $delegate.settingsTab) {
            GeneralSettingsTab(settings: settings, delegate: delegate)
                .tabItem {
                    Label("General", systemImage: "gearshape")
                }
                .tag(SettingsTab.general)

            ProfilesSettingsTab(delegate: delegate, settings: settings)
                .tabItem {
                    Label("Profiles", systemImage: "list.bullet.rectangle")
                }
                .tag(SettingsTab.profiles)

            CameraSettingsTab(
                settings: settings,
                activator: delegate.virtualCameraActivator
            )
                .tabItem {
                    Label("Camera", systemImage: "camera")
                }
                .tag(SettingsTab.camera)

            StatsSettingsTab(settings: settings, delegate: delegate)
                .tabItem {
                    Label("Stats", systemImage: "chart.bar.fill")
                }
                .tag(SettingsTab.stats)
        }
        .frame(width: 480, height: 380)
        .centeredOnScreen()
        // Reset to General on close so the next open starts at the
        // first tab. Apple's own System Settings does the same. The
        // menu's "Edit Profiles…" override still works: that path
        // mutates `settingsTab = .profiles` right before opening,
        // and `.onDisappear` only fires when the previous session
        // closed — so the override survives the next open.
        .onDisappear {
            delegate.settingsTab = .general
        }
    }
}

/// Camera tab — opt-in toggle for the virtual camera that lets
/// Zoom / Slack / Teams pick up the active profile's source camera
/// (those apps ignore the system's `userPreferredCamera`).
/// Installing requires user approval through System Settings, so
/// the section explains what's about to happen and surfaces a
/// status row that mirrors the activator's state machine.
private struct CameraSettingsTab: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var activator: VirtualCameraActivator
    // Intercept-before-apply: when the user toggles OFF, hold the
    // confirmation up before flipping the underlying setting.
    // Rolling back a deactivation after the fact would push the
    // activator into .requiresRelaunch (macOS doesn't actually stop
    // the extension on `deactivationRequest`, so a re-enable in the
    // same session can't recover cleanly). Confirm-first avoids
    // ever entering that bad state on a misclick.
    @State private var pendingVirtualCameraDisable = false

    var body: some View {
        Form {
            Section {
                Toggle(
                    "Enable virtual camera",
                    isOn: virtualCameraToggleBinding
                )
                .disabled(activator.isEnvOverride)

                statusRow

                if case .requiresRelaunch = activator.state {
                    Button("Restart AV Pain Reliever") {
                        activator.relaunch()
                    }
                    .buttonStyle(.borderedProminent)
                } else if showsApprovalAffordance {
                    Button("Open Login Items & Extensions…") {
                        openExtensionsSettings()
                    }
                }

                // Form footer hint rendered as the last row in the
                // section body — `footer:` is constrained on
                // macOS 14, locked convention per project memory.
                Text(explanationText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Label("Virtual camera", systemImage: "camera.metering.center.weighted")
            }
        }
        .groupedFormChrome()
        .alert(
            "Turn off the virtual camera?",
            isPresented: $pendingVirtualCameraDisable
        ) {
            Button("Cancel", role: .cancel) {}
            Button("Turn Off") {
                settings.virtualCameraEnabled = false
            }
        } message: {
            Text("Zoom, Slack, Teams, and other apps with their own camera picker will stop following your profile changes. They'll stay on whichever camera you last selected inside each app. You can turn this back on later.")
        }
    }

    /// Custom binding for the toggle that intercepts the off
    /// transition. Reads pass through to `settings.virtualCameraEnabled`.
    /// Writes that flip ON apply directly. Writes that flip OFF
    /// raise the confirm-disable alert without touching the setting
    /// — the alert's "Turn Off" action does the actual write.
    private var virtualCameraToggleBinding: Binding<Bool> {
        Binding(
            get: { settings.virtualCameraEnabled },
            set: { newValue in
                if !newValue && settings.virtualCameraEnabled {
                    pendingVirtualCameraDisable = true
                } else {
                    settings.virtualCameraEnabled = newValue
                }
            }
        )
    }

    /// Live status row — colored dot + human-readable label that
    /// repaints on every activator state transition.
    private var statusRow: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text(statusLabel)
                .font(.callout)
            Spacer()
            if activator.isEnvOverride {
                StatusPill(text: "Debug override", tint: Theme.Color.warn)
            }
        }
        .padding(.vertical, 2)
    }

    private var statusColor: Color {
        switch activator.state {
        case .on: return Theme.Color.success
        case .activating, .needsApproval: return Theme.Color.warn
        case .failed, .requiresRelaunch, .requiresReboot: return Theme.Color.error
        case .off: return .secondary
        }
    }

    private var statusLabel: String {
        switch activator.state {
        case .off: return "Off"
        case .activating: return "Activating…"
        case .needsApproval: return "Approval needed"
        case .on: return "Active"
        case .failed(let msg): return "Failed: \(msg)"
        case .requiresRelaunch: return "Restart required"
        case .requiresReboot: return "Re-enable required"
        }
    }

    private var showsApprovalAffordance: Bool {
        switch activator.state {
        case .needsApproval, .failed: return true
        default: return false
        }
    }

    private var explanationText: String {
        if activator.isEnvOverride {
            return "The AVPR_ACTIVATE_VIRTUAL_CAMERA debug override is active for this launch. The toggle is locked until you relaunch without it."
        }
        switch activator.state {
        case .off:
            return "When on, Zoom, Slack, Teams, and other apps that have their own camera picker can choose 'AV Pain Reliever' to follow the active profile's source camera."
        case .activating:
            return "Submitting the activation request to macOS. If a system prompt appears, approve it in System Settings."
        case .needsApproval:
            return "macOS is waiting for you to approve the Camera Extension. Open System Settings → General → Login Items & Extensions → Camera Extensions."
        case .on:
            return "Pick 'AV Pain Reliever' in Zoom, Slack, or any app's camera picker. The active profile's source camera flows through it."
        case .failed:
            return "Activation didn't complete. Open System Settings → General → Login Items & Extensions to check the extension's state, then toggle this off and on to retry."
        case .requiresRelaunch:
            return "macOS holds the virtual camera in a stale state after toggling off and back on inside one session. Restart the app to re-enable it cleanly."
        case .requiresReboot:
            return "A previous version of the camera extension is still queued for removal, which can keep the new one hidden. Toggle this off and back on to re-register it, then restart the app if prompted. If the camera still doesn't appear, restart your Mac."
        }
    }

    private func openExtensionsSettings() {
        // Apple's documented x-apple URL for the extensions page.
        // Falls back to the general System Settings app on older
        // macOS versions where the deep link isn't recognized —
        // still gets the user one click closer than nothing.
        let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")
            ?? URL(string: "x-apple.systempreferences:")!
        NSWorkspace.shared.open(url)
    }
}

private struct GeneralSettingsTab: View {
    @ObservedObject var settings: SettingsStore
    /// Source of the in-use audio/camera names that Forget Remembered
    /// Devices preserves. Read at click time so a user who edits a
    /// profile and then immediately clicks Forget gets the up-to-date
    /// reference set without us re-observing every profile change.
    @ObservedObject var delegate: AppDelegate
    @State private var showingMenuBarIconPicker = false
    @State private var forgetRememberedConfirmationVisible = false

    var body: some View {
        Form {
            Section {
                Toggle("Launch at login", isOn: $settings.launchAtLogin)
                Toggle("Send notifications when profiles change", isOn: $settings.notificationsEnabled)
                Toggle("Show current profile in the menu bar", isOn: $settings.showProfileNameInMenuBar)
                Toggle("Show current profile icon in the menu bar", isOn: $settings.showProfileIconInMenuBar)
                // Picker row + a conditional caption explaining why
                // the picker greys out when the profile-icon toggle
                // above is on. Caption shows only in the disabled
                // state so the cause-and-effect is unambiguous: the
                // moment you flip the toggle, the explanation
                // appears next to the disabled control.
                VStack(alignment: .leading, spacing: 6) {
                    LabeledContent("Menu bar icon") {
                        Button {
                            showingMenuBarIconPicker = true
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: settings.menuBarIconSymbol)
                                    .font(.body)
                                Image(systemName: "chevron.down")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.bordered)
                        .popover(isPresented: $showingMenuBarIconPicker, arrowEdge: .bottom) {
                            MenuBarSymbolPicker(
                                selection: $settings.menuBarIconSymbol,
                                onPick: { showingMenuBarIconPicker = false }
                            )
                        }
                    }
                    if settings.showProfileIconInMenuBar {
                        Text("Active profile icon overrides this above.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .disabled(settings.showProfileIconInMenuBar)
            } header: {
                Label("Behavior", systemImage: "wand.and.stars")
            }

            Section {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Debounce window")
                        Spacer()
                        Text(String(format: "%.1f s", settings.debounceInterval))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $settings.debounceInterval, in: 0.5...5.0, step: 0.1)
                    Text("Wait this long after USB activity before re-evaluating. Higher values handle slow docks; lower values feel snappier. Default: 1.5 s.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            } header: {
                Label("Detection", systemImage: Theme.Symbol.usbSection)
            }

            if settings.hasRememberedDevices {
                Section {
                    Button(role: .destructive) {
                        forgetRememberedConfirmationVisible = true
                    } label: {
                        Text("Forget unused devices…")
                            .foregroundStyle(Theme.Color.error)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Text("The Add Profile wizard remembers every audio device and camera it's seen, so you can edit a profile's selections even when its dock isn't plugged in. Wipe the ones that aren't used by any saved profile. Devices a profile depends on stay in the list.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } header: {
                    Label("Remembered devices", systemImage: "tray.full")
                }
            }

            Section {
                Toggle("Receive dev updates", isOn: $settings.devUpdates)
                Text("Opt in to small in-flight features. Dev releases ship more often than the stable line and usually carry one or two finished tweaks at a time. Off by default.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Toggle("Receive experimental updates", isOn: $settings.experimentalUpdates)
                Text("Opt in to moonshot builds. Experimental releases may include unfinished features and break things. Off by default. Independent of the dev toggle above; flip either, both, or neither.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Label("Updates", systemImage: "arrow.down.circle")
            }
        }
        .groupedFormChrome()
        .alert(
            "Forget unused devices?",
            isPresented: $forgetRememberedConfirmationVisible
        ) {
            Button("Forget", role: .destructive) {
                settings.forgetRememberedDevices(
                    currentProfiles: delegate.availableProfiles
                )
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Audio and camera names that aren't used by any saved profile will be dropped. Anything a profile depends on stays so the wizard can still show it when you're away from that location.")
        }
    }
}

private struct ProfilesSettingsTab: View {
    @ObservedObject var delegate: AppDelegate
    @ObservedObject var settings: SettingsStore
    @Environment(\.openWindow) private var openWindow
    // Native SwiftUI .alert() for delete confirmation — matches the
    // Stats tab's "Reset stats?" pattern. Was an NSAlert on
    // AppDelegate that always rendered with the app icon badge.
    @State private var profilePendingDeletion: Profile?

    var body: some View {
        Group {
            if delegate.availableProfiles.isEmpty && settings.ignoredLocations.isEmpty {
                emptyState
            } else {
                // Form(.grouped) instead of List: matches the General /
                // Stats tab's rounded-card chrome, prominent
                // bold-icon + bold-text Section headers, and consistent
                // row metrics. Apple's own System Settings renders
                // list-style content (Login Items, Wi-Fi networks,
                // Extensions) inside the same grouped-Form chrome, so
                // the Profiles tab now reads as part of the same
                // settings surface instead of drifting into List's
                // sidebar-style aesthetic.
                Form {
                    if !delegate.availableProfiles.isEmpty {
                        Section {
                            ForEach(delegate.availableProfiles, id: \.name) { profile in
                                ProfileRow(
                                    profile: profile,
                                    isActive: profile.name == delegate.activeProfileSlug,
                                    onEdit: {
                                        delegate.beginEditingProfile(profile)
                                        openWindow(id: addProfileWindowID)
                                        NSApp.activate(ignoringOtherApps: true)
                                    },
                                    onDelete: { profilePendingDeletion = profile }
                                )
                            }
                        } header: {
                            Label("Profiles", systemImage: "list.bullet.rectangle")
                        }
                    }
                    if !settings.ignoredLocations.isEmpty {
                        // Surface "Not a Location" dismissals so the
                        // user can audit and undo them. Sorted by
                        // most-recent first so a fresh dismissal is
                        // visible at the top.
                        //
                        // Helper text rendered as the last row inside
                        // the Section body (not in `footer:`) per the
                        // macOS 14 Form-footer-doesn't-wrap workaround.
                        Section {
                            ForEach(
                                settings.ignoredLocations.sorted { $0.dismissedAt > $1.dismissedAt }
                            ) { ignored in
                                IgnoredLocationRow(
                                    ignored: ignored,
                                    onUnignore: { delegate.unignoreLocation(key: ignored.key) }
                                )
                            }
                            Text("Device combinations you've dismissed as not a real place. Remove one to re-enable the “Set Up Location…” prompt the next time it's attached.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        } header: {
                            Label("Ignored Locations", systemImage: "bell.slash")
                        }
                    }
                }
                .groupedFormChrome()
            }
        }
        .alert(
            "Delete “\(PrettyName.format(profilePendingDeletion?.name ?? ""))”?",
            isPresented: .isPresent($profilePendingDeletion),
            presenting: profilePendingDeletion
        ) { profile in
            // Cancel first → bound to .cancelAction (Return key) → safe
            // accidental press. Delete second, .destructive → red text
            // and requires a deliberate click.
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                delegate.deleteProfile(profile)
            }
        } message: { _ in
            Text("This profile won't switch your audio + camera defaults when its USB devices are attached. You can always recapture it later.")
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            // Native macOS bottom-bar pattern (Mail sidebar, Reminders,
            // System Settings → Network). The `.bar` material gives the
            // translucent footer chrome with an automatic separator;
            // the borderless `+` icon matches Apple's "add a row to
            // this list" affordance everywhere it appears in their
            // own apps. Suppressed in empty state — the hero CTA
            // already covers add-a-profile, doubling up reads as
            // visual noise.
            if !delegate.availableProfiles.isEmpty {
                HStack(spacing: 8) {
                    Button {
                        delegate.beginAddingProfile()
                        openWindow(id: addProfileWindowID)
                        NSApp.activate(ignoringOtherApps: true)
                    } label: {
                        Image(systemName: "plus")
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(.borderless)
                    .help("Add Profile")
                    Spacer()
                    Text("\(delegate.availableProfiles.count) profile\(delegate.availableProfiles.count == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(.bar)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 18) {
            Spacer()
            // Hero icon — uses the app icon (rather than a generic
            // tray) so the empty state still feels like the
            // product, not a generic-iOS-style placeholder.
            Image(nsImage: AppIcon.image)
                .resizable()
                .interpolation(.high)
                .frame(width: 76, height: 76)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .shadow(color: .black.opacity(0.15), radius: 10, y: 4)
            VStack(spacing: 4) {
                Text("Set up your first location")
                    .font(.title3.weight(.semibold))
                Text("Plug in your dock or peripherals, then capture them as a profile. Your audio + camera defaults will switch automatically when you dock there again.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 32)
            }
            Button {
                delegate.beginAddingProfile()
                openWindow(id: addProfileWindowID)
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Text("Add Profile…")
                    .padding(.horizontal, 12)
                    .padding(.vertical, 2)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ProfileRow: View {
    let profile: Profile
    let isActive: Bool
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            // Leading icon mirrors the Switch To submenu: profile's
            // user-picked icon when set, slug-driven auto-mapper
            // fallback when not.
            Image(systemName: ProfileIcon.effectiveSymbol(
                for: profile.name,
                override: profile.icon
            ))
                .font(.title3)
                .foregroundStyle(isActive ? .primary : .secondary)
                .frame(width: 28)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(PrettyName.format(profile.name))
                        .font(.body.weight(.medium))
                    if isActive {
                        StatusPill(text: "Active", tint: Theme.Color.success)
                    }
                }
                // Vertical device list — each device on its own row
                // with an icon-aligned column. Apple's pattern in
                // System Settings → Bluetooth / Network / Internet
                // Accounts. Replaces the earlier inline
                // "icon + name • icon + name • …" caption that wrapped
                // unpredictably when device names were long, splitting
                // an SF Symbol from its label across lines.
                ForEach(deviceRows) { row in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: row.icon)
                            .frame(width: 14, alignment: .center)
                        Text(row.label)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            Spacer()
            // Icon-only inline actions — keeps the profile name +
            // summary in the visual centre of each row instead of
            // fighting two text-bearing buttons for space. Sizing
            // and accessibility are handled inside `IconButton` so
            // both renders match dimensions regardless of which
            // SF Symbol each carries.
            IconButton(
                systemImage: "pencil",
                accessibilityLabel: "Edit profile",
                action: onEdit
            )
            IconButton(
                systemImage: "trash",
                accessibilityLabel: "Delete profile",
                role: .destructive,
                action: onDelete
            )
        }
        .padding(.vertical, 6)
    }

    /// One row in the per-profile device summary list.
    private struct DeviceRow: Identifiable {
        let icon: String
        let label: String
        var id: String { "\(icon)|\(label)" }
    }

    /// Devices to surface under the profile name, in display order:
    /// microphone, speaker, camera, then USB fingerprint summary.
    /// USB row uses `Theme.Symbol.usbSection` for both the count case
    /// and the "always matches when undocked" case — the differentiator
    /// is the label, not the glyph.
    private var deviceRows: [DeviceRow] {
        var rows: [DeviceRow] = []
        if let mic = profile.audioInput {
            rows.append(DeviceRow(icon: "mic", label: mic))
        }
        if let out = profile.audioOutput {
            rows.append(DeviceRow(icon: "speaker.wave.2", label: out))
        }
        if let cam = profile.camera {
            rows.append(DeviceRow(icon: "camera", label: cam))
        }
        if profile.fingerprint.isEmpty {
            rows.append(DeviceRow(icon: Theme.Symbol.usbSection, label: "Always matches when undocked"))
        } else {
            let count = profile.fingerprint.count
            rows.append(DeviceRow(icon: Theme.Symbol.usbSection, label: "\(count) USB device\(count == 1 ? "" : "s")"))
        }
        return rows
    }
}

/// One row in the Profiles tab's "Ignored Locations" section.
/// Mirrors `ProfileRow`'s leading-icon + vertical-device-list layout
/// so the two lists visually relate — same row height, same
/// secondary-text styling, same trailing icon-only action button.
private struct IgnoredLocationRow: View {
    let ignored: IgnoredLocation
    let onUnignore: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            // questionmark.circle mirrors the menu-bar icon shown
            // when the engine is *at* an unknown location — visual
            // consistency between "we don't know this place" and
            // "you told us not to ask about this place." `xmark.circle`
            // here read as an actionable remove-button next to the
            // text, which fought the actual remove control on the
            // trailing edge.
            Image(systemName: "questionmark.circle")
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 28)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                Text(headline)
                    .font(.body.weight(.medium))
                ForEach(ignored.devices, id: \.self) { device in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: Theme.Symbol.usbSection)
                            .frame(width: 14, alignment: .center)
                        Text(device.displayName)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Text("Dismissed \(relativeDismissedAt)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            // Trash icon to match `ProfileRow`'s delete affordance —
            // the user's mental model is "remove this entry from
            // the ignored list." Not marked `.destructive` because
            // the side-effect (re-enabling the prompt next time
            // these devices are attached) is benign; red would
            // overstate the consequence.
            IconButton(
                systemImage: "trash",
                accessibilityLabel: "Remove from ignored list",
                action: onUnignore
            )
        }
        .padding(.vertical, 6)
    }

    /// Title line. Prefers the friendliest single device name available
    /// when there's only one device in the fingerprint — e.g. "iPhone"
    /// — so the user instantly recognises the row. Falls back to a
    /// device-count summary for multi-device combinations.
    private var headline: String {
        if ignored.devices.count == 1, let only = ignored.devices.first {
            return only.displayName
        }
        return "\(ignored.devices.count) devices"
    }

    private var relativeDismissedAt: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: ignored.dismissedAt, relativeTo: Date())
    }
}

/// Stats tab — local usage tracking behind an opt-in toggle. Ships
/// off; the Tracking section collapses to just the toggle + helper
/// text on a fresh install, avoiding "what is this stuff?" friction
/// before the user has chosen to keep notes. Renamed from "Advanced"
/// to avoid colliding with the menu bar's existing Advanced submenu
/// — and the tab only houses stats today, so the on-the-nose name
/// reads better.
private struct StatsSettingsTab: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var delegate: AppDelegate
    @State private var resetConfirmationVisible = false
    /// Driven by an `.onChange` on the tracking toggle. Fires when
    /// the user disables tracking AND there's data to wipe — gives
    /// them a one-click "also reset?" affordance instead of forcing
    /// them to remember the separate Reset button.
    @State private var disableResetPromptVisible = false

    var body: some View {
        Form {
            Section {
                Toggle("Track usage stats locally", isOn: $settings.statsTrackingEnabled)
                Text("Counts only — what profile switched, when, and how often. No meeting content, no durations, no telemetry. Stays on this Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                if settings.statsTrackingEnabled {
                    statsRows
                }
            } header: {
                Label("Tracking", systemImage: "switch.2")
            }

            if settings.statsTrackingEnabled, !rankedProfiles.isEmpty {
                Section {
                    ForEach(rankedProfiles, id: \.0) { slug, count in
                        LabeledContent(PrettyName.format(slug), value: "\(count)")
                    }
                } header: {
                    Label("Switches by location", systemImage: "list.number")
                }
            }

            if settings.hasRecordedStats {
                Section {
                    Button(role: .destructive) {
                        resetConfirmationVisible = true
                    } label: {
                        Text("Reset stats…")
                            .foregroundStyle(Theme.Color.error)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                } header: {
                    Label("Reset", systemImage: "arrow.counterclockwise")
                }
            }
        }
        .groupedFormChrome()
        .alert(
            "Reset all usage stats?",
            isPresented: $resetConfirmationVisible
        ) {
            Button("Reset", role: .destructive) {
                settings.resetStats()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This wipes every counter and date on this screen. Your profiles and other settings are untouched.")
        }
        // Surface the "also reset?" question at the moment the user
        // cares most: right after they flipped tracking off. Apple's
        // pattern for similar privacy-toggle disables (iCloud Photos,
        // Find My, Screen Time). Skipped when there's nothing worth
        // wiping — a fresh user toggling off → on again shouldn't
        // get a meaningless prompt.
        .alert(
            "Stop tracking usage stats?",
            isPresented: $disableResetPromptVisible
        ) {
            Button("Reset Stats", role: .destructive) {
                settings.resetStats()
            }
            Button("Keep Stats", role: .cancel) {}
        } message: {
            Text("Tracking is off. Your existing counters and dates can stay in case you turn it back on later, or be wiped now.")
        }
        .onChange(of: settings.statsTrackingEnabled) { _, newValue in
            if !newValue && settings.hasRecordedStats {
                disableResetPromptVisible = true
            }
        }
    }

    @ViewBuilder
    private var statsRows: some View {
        LabeledContent("Tracking since", value: trackingSinceString)
        LabeledContent("Auto-switches", value: "\(settings.profileSwitchCount)")
        if let lastLine = lastSwitchedString {
            LabeledContent("Last switched", value: lastLine)
        }
        LabeledContent("Manual overrides", value: "\(settings.manualOverrideCount)")
        LabeledContent("Current streak", value: streakString(settings.currentStreakDays))
        LabeledContent("Longest streak", value: streakString(settings.longestStreakDays))
        LabeledContent("Active days", value: "\(settings.activeDaysCount)")
        LabeledContent("Unique USB devices recognized", value: "\(settings.uniqueDevicesSeenCount)")
    }

    /// "Today" on day 0, "Yesterday" on day 1, "N days ago" beyond.
    /// Renders nil-state as "Not yet" so a freshly-enabled user
    /// doesn't see "0 days ago" before any data has been collected.
    private var trackingSinceString: String {
        guard let start = settings.statsStartDate else { return "Not yet" }
        let days = Calendar.current.dateComponents(
            [.day],
            from: Calendar.current.startOfDay(for: start),
            to: Calendar.current.startOfDay(for: Date())
        ).day ?? 0
        switch days {
        case 0: return "Today"
        case 1: return "Yesterday (1 day)"
        default: return "\(days) days ago"
        }
    }

    private var lastSwitchedString: String? {
        guard let date = settings.lastSwitchDate, let slug = settings.lastSwitchSlug
        else { return nil }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        let relative = formatter.localizedString(for: date, relativeTo: Date())
        return "\(relative) → \(PrettyName.format(slug))"
    }

    /// Every profile that has at least one recorded switch, sorted by
    /// descending count. Powers the "Switches by location" section.
    /// The first entry is implicitly the most-used: sort order carries
    /// the meaning, no separate highlight row needed.
    private var rankedProfiles: [(String, Int)] {
        settings.perProfileCounts
            .sorted { $0.value > $1.value }
            .map { ($0.key, $0.value) }
    }

    private func streakString(_ days: Int) -> String {
        switch days {
        case 0: return "—"
        case 1: return "1 day"
        default: return "\(days) days"
        }
    }
}
