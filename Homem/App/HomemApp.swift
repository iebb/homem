import SwiftUI

@main struct HomemApp: App {
    @State private var store = AppStore()
    @AppStorage("appearance") private var appearance = "system"
    @AppStorage("color-scheme") private var colorScheme = "system"
    var body: some Scene {
        WindowGroup {
            Group {
                if store.api != nil { HomeShell().id(store.connectionID) }
                else { ConnectionView() }
            }
            .environment(store)
            .environment(\.appAccent, Theme.accent(for: colorScheme))
            .tint(Theme.accent(for: colorScheme))
            .preferredColorScheme(appearance == "system" ? nil : appearance == "dark" ? .dark : .light)
        }
    }
}
