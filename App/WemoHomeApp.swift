import SwiftUI

@main
@MainActor
struct WemoHomeApp: App {
    @StateObject private var model = HomeModel()

    var body: some Scene {
        WindowGroup { HomeView(model: model) }
    }
}
