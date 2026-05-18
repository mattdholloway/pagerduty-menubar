import SwiftUI

@main
struct pagerduty_menubarApp: App {
    @StateObject private var store = OnCallStore()

    var body: some Scene {
        MenuBarExtra {
            MenuView()
                .environmentObject(store)
                .frame(width: 360)
        } label: {
            Label {
                Text(store.menuBarTitle)
            } icon: {
                Image(systemName: store.menuBarSymbol)
            }
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(store)
                .frame(width: 420, height: 220)
        }
    }
}

