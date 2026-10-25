import SwiftUI

@main
struct SwitchboardApp: App {
    @StateObject private var matter = MatterManager.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(matter)
        }
    }
}
