import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: OnCallStore
    @State private var tokenInput: String = ""
    @State private var revealToken: Bool = false
    @State private var savedMessage: String?

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
}
