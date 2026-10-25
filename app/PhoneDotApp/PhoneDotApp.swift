import SwiftUI

@main
struct PhoneDotApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var connection = PhoneConnectionSession()
    var body: some Scene {
        WindowGroup {
            PhoneConnectionView(connection: connection, connectivity: connection.connectivity)
                .onAppear { if scenePhase == .active { connection.enterForeground() } }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { connection.enterForeground() }
                    else if phase == .background { connection.enterBackground() }
                }
        }
    }
}

private struct PhoneConnectionView: View {
    @ObservedObject var connection: PhoneConnectionSession
    @ObservedObject var connectivity: CompanionConnectivity
    var body: some View {
        NavigationStack {
            List {
                Section("Apple Watch") {
                    Label(connectivity.reachable ? "Watch Dot available" : "Waiting for the watch",
                          systemImage: connectivity.reachable ? "applewatch.radiowaves.left.and.right" : "applewatch")
                    if !connectivity.counterpartInstalled {
                        Text("Install Watch Dot from the Watch app on your iPhone.")
                    } else if !connectivity.reachable {
                        Text("Open Watch Dot on your Apple Watch and keep it nearby while you authorize.")
                    }
                }
                Section("ChatGPT account") {
                    Text(connection.status)
                    Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "") · \(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "")")
                        .font(.caption).foregroundStyle(.secondary)
                    if connection.busy { ProgressView("Authorizing…") }
                    Button("Continue with ChatGPT", action: connection.start)
                        .disabled(connection.busy || !connectivity.reachable)
                    if connection.busy || !connection.authorized {
                        Button("Cancel authorization", role: .cancel, action: connection.cancel)
                    }
                }
                Section {
                    Text("The chat with your Dot lives on your Apple Watch. After sign-in, the watch can use its own internet connection.")
                }
            }
            .navigationTitle("Watch Dot")
        }
    }
}
