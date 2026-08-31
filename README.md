<p align="center">
  <img src="docs/og-card.png" alt="AV Pain Reliever. Your laptop knows where it is." width="800">
</p>

You carry your MacBook to a few different desks during the week. Home office, work desk, conference room, café. Each one has a different microphone, different speakers, maybe a different camera. The audio is wrong until you fix it. **AV Pain Reliever** notices which dock you've connected to and handles it for you:

- Sets your **system default microphone** for that location.
- Sets your **system default speaker** for that location.
- Sets your **system preferred camera** for that location.

Set your video apps (Zoom, Slack, Teams) once to follow the system default. After that, plug in and the right setup kicks in. Unplug, and you're back to the laptop's built-in mic and speakers.

Some apps (Zoom, Slack, Teams) keep their own camera selection that ignores the system default. For those, AV Pain Reliever can also act as a **virtual camera** that streams whichever real camera the active profile names. See *Virtual camera* below.

The app lives in your menu bar. No Dock icon, no windows in your way.

---

## Requirements

A Mac running **macOS 14 (Sonoma) or later**.

---

## Install

1. Download the latest **AVPainReliever.app.zip** from the [Releases page](https://github.com/superic/av-pain-reliever/releases/latest).
2. Unzip and drag **AVPainReliever.app** into your **Applications** folder.
3. Double-click to launch. The icon appears in your menu bar.
4. Open **Settings…** and toggle **Launch at Login** if you want it running every time you sign in.

The app updates itself in the background. To check manually, open **About → Check for Updates**.

To stop it: click the menu bar icon → **Quit**.

### Release channels

Most users want the stable channel. Dev and experimental are opt-in via **Settings → General → Updates** inside the app; once enabled, Sparkle auto-updates from that channel.

<!-- BEGIN CURRENT RELEASES -->
- **Stable** — [latest](https://github.com/superic/av-pain-reliever/releases/latest)
- **Dev** — [v0.2.0.22-dev.1](https://github.com/superic/av-pain-reliever/releases/tag/v0.2.0.22-dev.1)
- **Experimental** — _no current release_
<!-- END CURRENT RELEASES -->

---

## First-run setup

The first time you launch, the welcome window walks you through capturing the dock you're at right now:

1. **Name the location.** Whatever makes sense to you: "Home Office", "Work Desk", "Studio", "Conference Room".
2. **Pick which USB devices identify this location.** Untick anything that travels with you (keyboards, mice, phones).
3. **Pick the audio and camera defaults.** Pre-filled with your current System Settings.
4. **Save.**

Repeat once per location. The app switches automatically whenever you dock there.

When you connect to a new dock the app doesn't recognise, the menu bar shows **"New location"** and offers to set it up. Plugging in a flash drive, card reader, or phone on its own doesn't count — the app only suggests a new location for devices that could actually be part of one.

---

## Using the app

Click the menu bar icon for:

- **Switch to**: manually apply a different profile.
- **Add Profile…**: capture the dock you're at right now (⌘N).
- **Settings…**: notifications, menu bar appearance, profile management, Launch at Login (⌘,).
- **About**: version and updates.

---

## Virtual camera (optional)

Zoom, Slack, and Teams remember the camera you pick *inside their own settings* and ignore the system default. So even after AV Pain Reliever changes your system camera, those apps keep using whatever you last chose in their picker.

The virtual camera fixes that. Once turned on, **AV Pain Reliever** appears as a camera in any video app's picker. Pick it once and it streams whichever real camera the active profile names: built-in, USB capture card, iPhone Continuity Camera, anything you can configure in a profile. When the profile changes, the picture follows.

To enable:

1. Open **Settings… → Camera**.
2. Toggle **Enable virtual camera**.
3. Approve in **System Settings → General → Login Items & Extensions** when prompted (one-time setup).
4. In Zoom / Slack / Teams, pick **AV Pain Reliever** as your camera.

**Settings… → Camera** also shows a live preview of what the virtual camera is sending, with a one-line readout underneath ("Relaying 30 fps from …"), so you can confirm the feed is healthy without starting a call. The preview runs only while that tab is open.

To turn it off, flip the toggle back. The "AV Pain Reliever" entry stops showing up in those apps' camera lists.

---

## Privacy

The app makes no network calls beyond checking for its own updates. No analytics, no telemetry, no third-party services. Your profiles are stored as a plain text file on your Mac (`~/Library/Application Support/AVPainReliever/profiles.toml`). You can read it, back it up, or edit it by hand.

---

## Support

Questions or bug reports: [open an issue](https://github.com/superic/av-pain-reliever/issues).

---

For developers: see [CHANGELOG.md](CHANGELOG.md) for the project journal, [docs/](docs/) for architecture / decisions / virtual camera / release docs, and [CLAUDE.md](CLAUDE.md) for repo orientation. MIT licensed. See [LICENSE](LICENSE).
