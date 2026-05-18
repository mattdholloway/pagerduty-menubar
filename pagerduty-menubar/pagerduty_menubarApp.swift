import SwiftUI

@main
struct pagerduty_menubarApp: App {
    @StateObject private var store = OnCallStore()

    init() {
        NotificationsCoordinator.shared.requestAuthorizationIfNeeded()
        UpdateChecker.shared.startBackgroundChecks()
        NotificationCenter.default.addObserver(
            forName: NotificationsCoordinator.didRequestAcknowledge,
            object: nil,
            queue: .main
        ) { note in
            guard let id = note.userInfo?["id"] as? String else { return }
            Task { @MainActor in
                // Read the latest store via a global accessor by routing via
                // a notification — store ref isn't available from a static
                // observer. We post to a second notification the App's body
                // observes via the store.
                NotificationCenter.default.post(name: .pdRouteAcknowledge, object: nil, userInfo: ["id": id])
            }
        }
        NotificationCenter.default.addObserver(
            forName: NotificationsCoordinator.didRequestResolve,
            object: nil,
            queue: .main
        ) { note in
            guard let id = note.userInfo?["id"] as? String else { return }
            NotificationCenter.default.post(name: .pdRouteResolve, object: nil, userInfo: ["id": id])
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuView()
                .environmentObject(store)
                .frame(width: 380)
                .onReceive(NotificationCenter.default.publisher(for: .pdRouteAcknowledge)) { note in
                    if let id = note.userInfo?["id"] as? String { store.updateIncidentStatus(id, to: "acknowledged") }
                }
                .onReceive(NotificationCenter.default.publisher(for: .pdRouteResolve)) { note in
                    if let id = note.userInfo?["id"] as? String { store.updateIncidentStatus(id, to: "resolved") }
                }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: store.menuBarSymbol)
                if !store.menuBarTitle.isEmpty {
                    Text(store.menuBarTitle)
                }
            }
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(store)
                .frame(width: 460, height: 380)
        }
    }
}


extension Notification.Name {
    static let pdRouteAcknowledge = Notification.Name("PDRouteAcknowledge")
    static let pdRouteResolve = Notification.Name("PDRouteResolve")
}
