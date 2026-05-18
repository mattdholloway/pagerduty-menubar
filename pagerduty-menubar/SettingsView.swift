import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @EnvironmentObject private var store: OnCallStore
    @StateObject private var updater = UpdateChecker.shared
    @State private var tokenInput: String = ""
    @State private var revealToken: Bool = false
    @State private var savedMessage: String?
    @State private var launchAtLogin: Bool = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        Form {
            Section("PagerDuty API token") {
                HStack {
                    Group {
                        if revealToken {
                            TextField("REST API token", text: $tokenInput)
                        } else {
                            SecureField("REST API token", text: $tokenInput)
                        }
                    }
                    .textFieldStyle(.roundedBorder)

                    Button {
                        revealToken.toggle()
                    } label: {
                        Image(systemName: revealToken ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.borderless)
                }

                HStack {
                    Button("Save") {
                        store.setToken(tokenInput)
                        tokenInput = ""
                        savedMessage = "Saved to Keychain."
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(tokenInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    if store.hasToken {
                        Button("Remove stored token", role: .destructive) {
                            store.clearToken()
                            savedMessage = "Token removed."
                        }
                    }

                    Spacer()

                    if let msg = savedMessage {
                        Text(msg).font(.caption).foregroundStyle(.secondary)
                    } else if store.hasToken {
                        Label("Token stored", systemImage: "checkmark.seal.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                    } else {
                        Label("No token", systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }

                Text("Create a REST API token in PagerDuty under your profile → User Settings → Create API User Token. The token is stored only in your macOS Keychain.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Updates") {
                HStack {
                    VStack(alignment: .leading) {
                        Text("Current version: \(updater.currentVersion)")
                        Text(updateStatusText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    updateActionView
                }
                Toggle("Automatically install updates in the background", isOn: $updater.autoInstall)
                Text("When enabled, the app checks GitHub Releases every 24 h (and at launch) and installs the latest version automatically. The app will quit and relaunch when an update is applied.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Startup") {
                Toggle("Launch automatically at login", isOn: Binding(
                    get: { launchAtLogin },
                    set: { newValue in
                        do {
                            if newValue {
                                try SMAppService.mainApp.register()
                            } else {
                                try SMAppService.mainApp.unregister()
                            }
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                            loginError = nil
                        } catch {
                            loginError = error.localizedDescription
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
                ))
                if let err = loginError {
                    Text(err).font(.caption).foregroundStyle(.red)
                } else if SMAppService.mainApp.status == .requiresApproval {
                    Text("Approval required — open System Settings → General → Login Items to enable.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Section("Refresh") {
                Stepper(value: $store.refreshMinutes, in: 1...60) {
                    Text("Refresh every \(store.refreshMinutes) minute\(store.refreshMinutes == 1 ? "" : "s")")
                }
                Button("Refresh now") { store.refresh() }
                    .disabled(!store.hasToken)
            }

            Section("Reorder services") {
                if store.groups.isEmpty {
                    Text("Reorder will appear here once services have loaded.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    List {
                        ForEach(store.orderedGroupsIncludingHiddenPublic, id: \.id) { group in
                            HStack(spacing: 6) {
                                Image(systemName: "line.3.horizontal")
                                    .foregroundStyle(.secondary)
                                Text(group.policy.summary ?? "Escalation policy")
                                if store.isPolicyHidden(group.id) {
                                    Text("Hidden")
                                        .font(.system(size: 9, weight: .semibold))
                                        .padding(.horizontal, 4).padding(.vertical, 1)
                                        .background(Color.secondary.opacity(0.18), in: Capsule())
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text("\(group.services.count) svc")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .onMove { source, destination in
                            var ids = store.orderedGroupsIncludingHiddenPublic.map(\.id)
                            ids.move(fromOffsets: source, toOffset: destination)
                            store.setOrder(ids)
                        }
                    }
                    .frame(minHeight: 160, maxHeight: 240)
                    .listStyle(.bordered)
                }
                Text("Drag to reorder. The order applies to the menu (drag-and-drop in the menu bar popover is unreliable; use the up/down arrows there).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Visibility") {
                HStack {
                    Text("Hidden services: \(store.hiddenPolicyCount)")
                    Spacer()
                    Button("Reset") { store.resetHiddenPolicies() }
                        .disabled(store.hiddenPolicyCount == 0)
                }
                HStack {
                    Text("Pinned to menu bar: \(store.pinnedKeys.count)")
                    Spacer()
                    Button("Reset") { store.resetPinned() }
                        .disabled(store.pinnedKeys.isEmpty)
                }
                HStack {
                    Text("Custom order")
                    Spacer()
                    Button("Reset to default") { store.resetPolicyOrder() }
                        .disabled(store.policyOrder.isEmpty)
                }
                Text("Drag policy cards in the menu to reorder them. Use the eye-slash icon in a card header to hide a whole service; it'll reappear greyed-out at the bottom of the menu. Use the pin icon on an on-call row to surface that schedule in the menu bar.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    // MARK: - Update helpers

    private var updateStatusText: String {
        switch updater.status {
        case .idle: return updater.lastCheckedAt.map { "Last checked \(Self.shortDate.string(from: $0))" } ?? "Not checked yet"
        case .checking: return "Checking for updates…"
        case .upToDate: return "You're on the latest version."
        case .available(let r): return "Update available: \(r.version)"
        case .downloading(let p): return String(format: "Downloading… %.0f%%", p * 100)
        case .installing: return "Installing — the app will relaunch."
        case .failed(let msg): return "Update failed: \(msg)"
        }
    }

    @ViewBuilder
    private var updateActionView: some View {
        switch updater.status {
        case .checking, .installing:
            ProgressView().controlSize(.small)
        case .downloading(let p):
            ProgressView(value: p).frame(width: 120)
        case .available(let r):
            Button("Install \(r.version)") { Task { await updater.downloadAndInstall(r) } }
                .buttonStyle(.borderedProminent)
        default:
            Button("Check now") { Task { _ = await updater.check() } }
        }
    }

    private static let shortDate: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()
}
