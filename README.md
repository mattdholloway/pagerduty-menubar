<div align="center">

# 🛎️ PagerDuty Menu Bar

**A pragmatic, native macOS menu bar app for living with PagerDuty.**

See who's on call, when *you're* on next, and react to incidents — all
without opening a browser tab.

[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-000?style=flat-square&logo=apple)](https://www.apple.com/macos/)
[![Swift 5.0](https://img.shields.io/badge/Swift-5.0-F05138?style=flat-square&logo=swift&logoColor=white)](https://swift.org)
[![SwiftUI](https://img.shields.io/badge/UI-SwiftUI-1572B6?style=flat-square&logo=swift&logoColor=white)](https://developer.apple.com/xcode/swiftui/)
[![CI](https://img.shields.io/github/actions/workflow/status/mattdholloway/pagerduty-menubar/ci.yml?branch=main&style=flat-square&label=CI)](https://github.com/mattdholloway/pagerduty-menubar/actions/workflows/ci.yml)
[![Latest release](https://img.shields.io/github/v/release/mattdholloway/pagerduty-menubar?style=flat-square&include_prereleases&sort=semver)](https://github.com/mattdholloway/pagerduty-menubar/releases/latest)
[![License](https://img.shields.io/github/license/mattdholloway/pagerduty-menubar?style=flat-square)](LICENSE)
[![GitHub stars](https://img.shields.io/github/stars/mattdholloway/pagerduty-menubar?style=flat-square)](https://github.com/mattdholloway/pagerduty-menubar/stargazers)

</div>

---

## ✨ Why this exists

PagerDuty's web UI is great. It's also a tab you forget to keep open.
This app puts the answer to *"who's on call for X right now?"*, *"when
am I next on?"*, and *"is anything on fire?"* one click away in your
menu bar.

> Personal project. Not affiliated with PagerDuty.

## 🎯 Features

### Two focused tabs

The popover splits into **Schedules** and **Incidents** so each domain
stays focused. The menu bar icon and a small count badge surface
urgent state regardless of which tab is open.

### 🚨 Incidents

- **My active incidents** — anything assigned to you, or attached to a
  service owned by your teams. Red-tinted cards, sorted by urgency
  then recency.
- **Other active incidents** — searchable inbox of every active
  incident across the account; lazy-loaded only when you actually
  search to keep API usage low.
- **Ack / Resolve** with optimistic UI and a 5-second undo strip.
- **macOS notifications** for newly-triggered incidents assigned to
  you, with inline Ack / Resolve / Open actions.
- Menu bar icon switches to ❗️ whenever you have a triggered incident.

### 📅 Schedules

- **Your on-call schedule** — every shift you have across every
  escalation policy in the next 14 days, with role badges, start
  times and shift duration. Active shifts are highlighted.
- **Stacked escalation chain** — each service card shows the **Primary**
  in full and **Secondary / Tertiary** as compact rows underneath —
  no expand required.
- **Schedule calendar** — a side-flyout Gantt-style 7-day timeline
  per service with colour-coded bars and a "now" indicator.
- **My vs Other services & schedules** — your team's policies up top;
  every other policy on the account is searchable underneath.

### 🔔 Menu bar pinning

Pin any schedule and the current on-call's first name lives in your
menu bar, Outlook-style:

```
🛎️  Alice · Bob
```

### 🧰 Customise it

- **Drag-to-reorder** services (or use up/down arrows).
- **Hide** services you don't care about (they collapse into a greyed
  block at the bottom of the schedules tab).
- **Configurable refresh** (1–60 min, default 20).
- **Launch at login** via `SMAppService.mainApp`.
- **Auto-update** from GitHub Releases (off by default).

### 💾 Smart launch

The last successful refresh is cached to disk, so reopening the app
shows real data instantly and skips the immediate fetch when the
cache is still within the refresh window.

## 🚀 Install

### Option 1 — DMG (recommended)

Download `pagerduty-menubar-X.Y.Z.dmg` from the
[Releases](https://github.com/mattdholloway/pagerduty-menubar/releases)
page, open it, drag the app into **Applications**.

### Option 2 — zip

Same page, download `pagerduty-menubar-X.Y.Z.zip`, unzip, drop into
`/Applications`.

> The release is **not notarized**. First launch needs a
> right-click → **Open** to bypass Gatekeeper. Subsequent launches
> are normal. The built-in updater handles future versions silently.

### Option 3 — Build from source

```bash
git clone https://github.com/mattdholloway/pagerduty-menubar.git
cd pagerduty-menubar
open pagerduty-menubar.xcodeproj
```

In Xcode: scheme **pagerduty-menubar**, destination **My Mac**, ⌘R
to run; or `Product → Archive → Distribute App → Copy App` for an
installable bundle.

### First-launch setup

1. Click the menu bar icon → ⚙️ → **Settings**.
2. Paste a PagerDuty **REST API user token**
   (PagerDuty → Profile → User Settings → Create API User Token).
3. The menu populates after the next refresh; hit ↻ for an instant
   pull.

## ⚙️ Configuration

Everything lives in Settings (⌘,):

| Section | What it does |
| ------- | ------------ |
| **PagerDuty API token** | Stored in macOS Keychain only |
| **Updates** | Manual check / install + auto-install toggle |
| **Startup** | Launch automatically at login |
| **Refresh** | Pull interval (1–60 min, default 20) + Refresh now |
| **Reorder services** | Drag-and-drop in a normal-window list |
| **Visibility** | Reset hidden / pinned / order |

## 🔐 Privacy

- Your token is stored **only** in your macOS Keychain
  (service `mattdholloway.pagerduty-menubar`, account
  `pagerduty-api-token`).
- The app talks to `api.pagerduty.com` over HTTPS and
  `api.github.com` for update checks. Nothing else.
- No analytics, no telemetry, no third-party SDKs.

## 🛠 Requirements

- macOS **14 (Sonoma)** or later
- **Xcode 16+** (for building from source)
- PagerDuty REST API user token

## 🏗 Architecture

```
pagerduty-menubar/
├── pagerduty_menubarApp.swift     MenuBarExtra + Settings scenes
├── KeychainStore.swift            API token persistence
├── PagerDutyAPI.swift             Async REST client
├── OnCallStore.swift              @MainActor ObservableObject (state, fetch, ordering)
├── CacheStore.swift               On-disk snapshot of the last refresh
├── NotificationsCoordinator.swift macOS user notifications + actions
├── UpdateChecker.swift            In-app GitHub Releases updater
├── MenuView.swift                 Dropdown UI — tabs, sections, cards, rows
├── CalendarView.swift             Gantt-style schedule popover
└── SettingsView.swift             Token + preferences
```

- **SwiftUI** for everything (no AppKit windows beyond what Apple gives us).
- **`MenuBarExtra(.window)`** as the root scene.
- **Async/await** throughout the network layer.
- **App Sandbox** on, only `com.apple.security.network.client` enabled.

## 🧪 Tests

A real `xctest` bundle hosted by the app:

```bash
xcodebuild -project pagerduty-menubar.xcodeproj \
           -scheme pagerduty-menubar \
           -testPlan Tests \
           -destination 'platform=macOS' test
```

CI runs the test plan on every push and PR. Coverage includes the
REST client (headers, pagination, chunking, error mapping, incident
mutations), the on-call store (grouping, ordering, hide/pin, next
shift, my/other splits, incident urgency sort), and the menu-bar
title condensing.

## 🚢 Releasing

```bash
bin/release 0.2.0           # bump, commit, tag v0.2.0, push
bin/release 1.0.0 --dry-run # preview without changing anything
bin/release 0.1.5 --force   # downgrade / re-tag (rare)
```

The script rewrites `MARKETING_VERSION` and bumps
`CURRENT_PROJECT_VERSION` in `project.pbxproj`, commits, tags
`vX.Y.Z`, and pushes with `--follow-tags`.

CI then:

1. Asserts the tag matches the project's `MARKETING_VERSION`.
2. Builds Release.
3. Runs the test plan.
4. Packages `pagerduty-menubar-X.Y.Z.zip` (drag-to-install) and
   `pagerduty-menubar-X.Y.Z.dmg` (drag-to-/Applications).
5. Creates a GitHub Release with auto-generated notes and attaches
   both assets.

The in-app updater consumes the `.zip` asset to update existing
installs in place.

## 🗺 Roadmap

- [ ] Quick "override" / take-on-call action
- [ ] Notification when *you're about to be on*
- [ ] Per-account quick-switcher (multiple PagerDuty workspaces)
- [ ] Notarized + signed releases via GitHub Actions

## 🤝 Contributing

Issues, ideas and PRs welcome. Open a discussion before large changes
so we can align on direction.

## 📄 License

[MIT](LICENSE) © 2026 [Matthew Holloway](https://github.com/mattdholloway)

---

<div align="center">
<sub>Built with ☕️ in SwiftUI · Not affiliated with PagerDuty, Inc.</sub>
</div>
