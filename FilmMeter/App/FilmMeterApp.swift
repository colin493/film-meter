import SwiftUI

@main
struct FilmMeterApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .tint(Theme.accent)
        }
    }
}

enum Theme {
    static let accent = Color(red: 0.84, green: 0.47, blue: 0.20)
    static let panel = Color(white: 0.08)
    static let chip = Color(white: 0.16)
    static let dim = Color(white: 0.55)
}
