import SwiftUI
import ServiceManagement

@main
struct focus_macApp: App {
    @State private var store = FocusStore()
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(store: store)
        } label: {
            MenuBarLabel(store: store)
        }
        .menuBarExtraStyle(.menu)
    }

    init() {
        store.startPolling()
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}

struct MenuBarLabel: View {
    let store: FocusStore

    var body: some View {
        if let first = store.tickets.first {
            let truncated = first.title.prefix(30)
            Text(truncated.count < first.title.count ? "\(truncated)…" : first.title)
        } else if store.isLoading {
            Image(systemName: "arrow.trianglehead.2.counterclockwise")
        } else {
            Image(systemName: "checklist")
        }
    }
}

struct MenuBarView: View {
    let store: FocusStore

    var body: some View {
        if store.isLoading && store.tickets.isEmpty {
            Text("Loading…")
        } else if let error = store.lastError, store.tickets.isEmpty {
            Text(error)
        } else if store.tickets.isEmpty {
            Text("No tickets")
        } else {
            if let first = store.tickets.first {
                Button("\(first.identifier): \(first.title)") {
                    store.openTicket(first)
                }
                .keyboardShortcut("1")
            }

            Divider()

            ForEach(store.tickets.dropFirst()) { ticket in
                Button("\(ticket.identifier): \(ticket.title)") {
                    store.openTicket(ticket)
                }
            }
        }

        Divider()

        LaunchAtLoginToggle()

        Button("Refresh") {
            store.refresh()
        }
        .keyboardShortcut("r")

        Button("Quit") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}

struct LaunchAtLoginToggle: View {
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Toggle("Launch at Login", isOn: $launchAtLogin)
            .onChange(of: launchAtLogin) { _, newValue in
                do {
                    if newValue {
                        try SMAppService.mainApp.register()
                    } else {
                        try SMAppService.mainApp.unregister()
                    }
                } catch {
                    launchAtLogin = SMAppService.mainApp.status == .enabled
                }
            }
    }
}
