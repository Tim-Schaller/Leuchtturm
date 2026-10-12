import SwiftUI

@main
struct LeuchtturmTVApp: App {
    @State private var model = TVModel()

    var body: some Scene {
        WindowGroup {
            TVRootView()
                .environment(model)
        }
    }
}
