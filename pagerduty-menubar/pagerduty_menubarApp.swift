import SwiftUI

@main
struct pagerduty_menubarApp: App {
    @StateObject private var store = OnCallStore()

    var body: some Scene {
        MenuBarExtra {
            MenuView()
                .environmentObject(store)
                .frame(width: 380)
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

