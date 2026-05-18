# PagerDuty Menu Bar

A native macOS menu bar app for keeping an eye on PagerDuty on-call schedules
across the services you care about — built in Swift / SwiftUI as a personal,
pragmatic alternative to opening the PagerDuty web UI.

> **Status:** personal project, works on macOS 14 (Sonoma) and later.

## Features

- **Menu bar at a glance** — pin any schedule and the current on-call user's
  first name shows directly in the menu bar (`Alice · Bob`, `Alice +2`).
- **Your on-call schedule** — a top section listing every shift you have
  (current + upcoming) across every escalation policy in the next 14 days,
  with role badges (Primary / Secondary / Tertiary), start times and shift
  duration.
- **My services & schedules** — full cards for every service in your teams,
  showing the primary on-call user prominently and the rest of the
  escalation chain in compact rows underneath. Reorder cards with the up/down
  arrows (or via drag-and-drop in Settings).
- **Other services & schedules** — a searchable section listing every other
  escalation policy on the account, so you can find anyone on-call anywhere.
- **Schedule calendar** — click the calendar icon on any card for a
  Gantt-style 7-day timeline popover with bars per level and per schedule.
- **Hide / pin / order** — hide services you don't care about, pin schedules
  to the menu bar, drag-and-drop reorder in Settings. All preferences persist.
- **Auto-refresh** — every 5 minutes by default (configurable 1–60 min).
- **Launch at login** — toggle in Settings (uses `SMAppService.mainApp`).
- **Token storage** — your PagerDuty REST API token is stored in the macOS
  Keychain only; it never leaves your machine except for direct calls to
  `api.pagerduty.com`.

## Requirements

- macOS 14.0 (Sonoma) or later
- Xcode 15+ (16+ recommended)
- A PagerDuty REST API user token (Profile → User Settings → Create API
  User Token)

## Getting started

1. Clone the repo and open `pagerduty-menubar.xcodeproj` in Xcode.
2. Pick scheme `pagerduty-menubar`, destination **My Mac**.
3. ⌘R to build & run. The bell icon appears in the menu bar.
4. Open the app's Settings (⌘,) and paste your REST API token.
5. The menu populates after the next refresh.

### Installing locally

After the app builds in Release mode (Product → Archive → Distribute App →
Copy App), drag the resulting `pagerduty-menubar.app` into `/Applications`,
then enable "Launch at login" in Settings.

## Architecture

| File | Responsibility |
| ---- | -------------- |
| `pagerduty_menubarApp.swift` | App entry point — `MenuBarExtra` + `Settings` scenes |
| `KeychainStore.swift` | API token Keychain wrapper |
| `PagerDutyAPI.swift` | Async REST client for `/users/me`, `/services`, `/escalation_policies`, `/oncalls` |
| `OnCallStore.swift` | `@MainActor ObservableObject` orchestrating fetch, state, ordering, pinning, hiding |
| `MenuView.swift` | The dropdown UI — section layout, search, cards, rows |
| `CalendarView.swift` | The Gantt-style schedule popover |
| `SettingsView.swift` | Token, refresh interval, launch-at-login, reorder, visibility |

## Privacy

- The token lives in your Keychain (item `mattdholloway.pagerduty-menubar /
  pagerduty-api-token`).
- The app talks to `api.pagerduty.com` over HTTPS and nothing else.
- App Sandbox is on; only `com.apple.security.network.client` is enabled.

## License

[MIT](LICENSE). Personal project — no warranty.
