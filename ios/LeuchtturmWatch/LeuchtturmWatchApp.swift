import SwiftUI

@main
struct LeuchtturmWatchApp: App {
    @State private var model = WatchModel()

    var body: some Scene {
        WindowGroup {
            WatchHomeView()
                .environment(model)
        }
    }
}
