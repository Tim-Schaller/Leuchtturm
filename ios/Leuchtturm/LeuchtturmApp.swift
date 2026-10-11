import SwiftUI
import UIKit

@main
struct LeuchtturmApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(delegate.model)
                .onOpenURL { delegate.model.handle(url: $0) }
        }
    }
}

/// Owns the model so silent pushes reach it even when iOS launches the app
/// in the background without a scene.
final class AppDelegate: NSObject, UIApplicationDelegate {
    let model = AppModel()

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        application.registerForRemoteNotifications()
        return true
    }

    /// iCloud says something changed in a circle. The push has no content:
    /// fetch, decrypt and notify locally.
    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any]) async -> UIBackgroundFetchResult {
        await model.checkForNews()
        model.noteRemoteChange()
        return .newData
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            switch model.phase {
            case .onboarding:
                OnboardingView()
            case .ready:
                MapHomeView()
            }
        }
        .fontDesign(.rounded)
        .errorAlert()
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.tracker.refreshAuthorization() }
        }
    }
}

/// Shows `AppModel.errorMessage`. Attached to the root and to every sheet,
/// because an alert on the root cannot appear above a presented sheet.
struct ErrorAlert: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        content.alert(
            "Hoppla",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

extension View {
    func errorAlert() -> some View { modifier(ErrorAlert()) }
}
