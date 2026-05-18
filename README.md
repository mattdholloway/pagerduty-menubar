<div align="center">

# 🛎️ PagerDuty Menu Bar

**A pragmatic, native macOS menu bar app for living with PagerDuty on-call.**

See who's on call, when *you're* on next, and what the rest of the
escalation chain looks like — all without opening a browser tab.

[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-000?style=flat-square&logo=apple)](https://www.apple.com/macos/)
[![Swift 5.9](https://img.shields.io/badge/Swift-5.9-F05138?style=flat-square&logo=swift&logoColor=white)](https://swift.org)
[![SwiftUI](https://img.shields.io/badge/UI-SwiftUI-1572B6?style=flat-square&logo=swift&logoColor=white)](https://developer.apple.com/xcode/swiftui/)
[![Build](https://img.shields.io/github/actions/workflow/status/mattdholloway/pagerduty-menubar/build.yml?branch=main&style=flat-square)](https://github.com/mattdholloway/pagerduty-menubar/actions/workflows/build.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-green?style=flat-square)](LICENSE)
[![GitHub stars](https://img.shields.io/github/stars/mattdholloway/pagerduty-menubar?style=flat-square)](https://github.com/mattdholloway/pagerduty-menubar/stargazers)

</div>

---

## ✨ Why this exists

PagerDuty's web UI is great. It's also a tab you forget to keep open. This
app puts the answer to *"who's on call for X right now?"* one click away
in your menu bar — and the answer to *"when am I next on?"* on the
first row.

> Personal project. Not affiliated with PagerDuty.

## 🎯 Features

<table>
<tr>
<td valign="top" width="33%">

### 🔔 At-a-glance menu bar
Pin any schedule and the current on-call's **first name** lives in your
menu bar, Outlook-style:
`Alice · Bob · Carol +1`
</td>
<td valign="top" width="33%">

### 📅 Your on-call schedule
The top section shows **every shift you have** across every escalation
policy in the next 14 days — role-colored, with start times and
shift duration.
</td>
<td valign="top" width="33%">

### 🧭 Stacked escalation chain
Each service card shows the **Primary** in full and **Secondary /
Tertiary** as compact rows underneath — no expand required.
</td>
</tr>
<tr>
<td valign="top">

### 🗂️ My vs Other
*My services & schedules* lists the policies your teams own.
*Other services & schedules* is a searchable directory of every
policy on the account.
</td>
<td valign="top">

### 📆 Schedule calendar
A side-flyout **Gantt-style 7-day timeline** per service with
color-coded bars (Primary / Secondary / Tertiary), a "now"
indicator, and click-through to PagerDuty.
</td>
<td valign="top">

### 🧰 Make it yours
**Drag-to-reorder**, eye-to-hide, pin-to-menu-bar, search
filter, configurable refresh, launch-at-login. Everything
persists.
</td>
</tr>
</table>

## 🚀 Install

### Option 1 — Build from source (recommended)

```bash
git clone https://github.com/mattdholloway/pagerduty-menubar.git
cd pagerduty-menubar
open pagerduty-menubar.xcodeproj
```

In Xcode: scheme **pagerduty-menubar**, destination **My Mac**,
`Product → Archive → Distribute App → Copy App`, drag the resulting
`.app` into `/Applications`.

### Option 2 — Run from Xcode

Just hit ⌘R. The 🛎️ icon shows up in your menu bar.

### First-launch setup

1. Click the menu bar icon, then ⚙️ → Settings.
2. Paste a PagerDuty **REST API user token**
   (Profile → User Settings → Create API User Token).
3. The menu populates after the next refresh (5 min by default — or
   hit ↻ for an instant pull).

## ⚙️ Configuration

Everything lives in Settings (⌘,):

| Setting | What it does |
| ------- | ------------ |
| **API token** | Stored in macOS Keychain only |
| **Launch at login** | Adds the app via `SMAppService.mainApp` |
| **Refresh every N minutes** | 1–60, default 5 |
| **Reorder services** | Drag-and-drop in a normal-window list |
| **Reset hidden / pinned / order** | One-click bulk reset |

## 🛠 Requirements

- macOS **14 (Sonoma)** or later
- **Xcode 15+** (16+ recommended)
- PagerDuty REST API user token

## 🏗 Architecture

```
pagerduty-menubar/
├── pagerduty_menubarApp.swift   MenuBarExtra + Settings scenes
├── KeychainStore.swift          API token persistence
├── PagerDutyAPI.swift           Async REST client
├── OnCallStore.swift            @MainActor ObservableObject (state, fetch, ordering)
├── MenuView.swift               Dropdown UI — sections, search, cards, rows
├── CalendarView.swift           Gantt-style schedule popover
└── SettingsView.swift           Token + preferences
```

- **SwiftUI** for everything (no AppKit windows beyond what Apple gives us).
- **`MenuBarExtra(.window)`** as the root scene.
- **Async/await** throughout the network layer.
- **App Sandbox** on, only `com.apple.security.network.client` enabled.

## 🔐 Privacy

- Your token is stored **only** in your macOS Keychain
  (service `mattdholloway.pagerduty-menubar`, account
  `pagerduty-api-token`).
- The app talks to `api.pagerduty.com` over HTTPS and nothing else.
- No analytics, no telemetry, no third-party SDKs.

## 🗺 Roadmap

- [ ] Optional menu bar count badge (e.g. number of incidents)
- [ ] Quick "override" / take-on-call action
- [ ] Notification when *you're about to be on*
- [ ] Per-account quick-switcher (multiple PagerDuty workspaces)
- [ ] Notarized .dmg releases via GitHub Actions

## 🤝 Contributing

Issues, ideas and PRs welcome. Open a discussion before large changes
so we can align on direction.

## 📄 License

[MIT](LICENSE) © 2026 [Matthew Holloway](https://github.com/mattdholloway)

---

<div align="center">
<sub>Built with ☕️ in SwiftUI · Not affiliated with PagerDuty, Inc.</sub>
</div>
