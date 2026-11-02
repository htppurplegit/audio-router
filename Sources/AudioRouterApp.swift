import SwiftUI

@main
struct AudioRouterApp: App {
    @StateObject private var store = RouterStore()

    var body: some Scene {
        MenuBarExtra("Audio Router", systemImage: "cat.fill") {
            MenuView()
                .environmentObject(store)
        }
        .menuBarExtraStyle(.window)
    }
}

struct MenuView: View {
    @EnvironmentObject var store: RouterStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Audio Router").font(.headline)
            Text("Pick where each app's sound goes. Apps show up here once they've played audio.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            if store.apps.isEmpty {
                Text("No apps are using audio yet.")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else if store.apps.count <= 8 {
                appList
            } else {
                // A ScrollView in a menu-bar window collapses to zero height unless
                // it's given a definite height.
                ScrollView { appList }
                    .frame(height: 380)
            }

            Divider()

            Toggle("Open at login", isOn: $store.launchAtLogin)
            HStack {
                Spacer()
                Button("Quit") {
                    store.stopAll()
                    NSApp.terminate(nil)
                }
                .keyboardShortcut("q")
            }
        }
        .padding(14)
        .frame(width: 360)
    }

    private var appList: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(store.apps) { app in
                AppRow(app: app)
            }
        }
    }
}

struct AppRow: View {
    @EnvironmentObject var store: RouterStore
    let app: RouterStore.AppEntry

    private var selection: Binding<String> {
        Binding(
            get: { store.device(for: app.bundleID) ?? "" },
            set: { store.setDevice($0.isEmpty ? nil : $0, for: app.bundleID) }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                if let icon = app.icon {
                    Image(nsImage: icon).resizable().frame(width: 22, height: 22)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(app.name).lineLimit(1)
                    if !app.isRunning {
                        Text("Not running").font(.caption2).foregroundStyle(.secondary)
                    } else if app.isBackgroundProcess {
                        Text("Background process").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                if app.isPlaying {
                    Image(systemName: "waveform")
                        .foregroundStyle(.green)
                        .help("Playing now")
                }
                Spacer()
                Picker("", selection: selection) {
                    Text("System default").tag("")
                    Divider()
                    ForEach(store.devices) { d in
                        Text(d.name).tag(d.uid)
                    }
                    // Keep a saved-but-disconnected device selectable/visible.
                    if let uid = store.device(for: app.bundleID),
                       !store.devices.contains(where: { $0.uid == uid }) {
                        Text("\(store.deviceName(uid: uid)) (offline)").tag(uid)
                    }
                }
                .labelsHidden()
                .frame(width: 150)
            }
            if let err = store.errors[app.bundleID] {
                Text(err)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
