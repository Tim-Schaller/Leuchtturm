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
        WatchLink.shared.activate()
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
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-loadingPreview") { BeaconLoadingScreen() } else { content }
            #else
            content
            #endif
        }
    }

    @ViewBuilder private var content: some View {
        Group {
            switch model.phase {
            case .onboarding:
                OnboardingView()
            case .ready:
                MapHomeView()
                    // Until the first list of Leuchttürme arrives, instead of an empty map.
                    .overlay {
                        if !model.hasLoadedCircles {
                            BeaconLoadingScreen().transition(.opacity)
                        }
                    }
                    .animation(.easeOut(duration: 0.35), value: model.hasLoadedCircles)
            }
        }
        .fontDesign(.rounded)
        .errorAlert()
        .fullScreenCover(isPresented: Binding(get: { model.crashCheckDeadline != nil }, set: { _ in })) {
            CrashCheckView()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.tracker.refreshAuthorization() }
        }
    }
}

/// Shows `AppModel.errorMessage`. Attached to the root and to every sheet,
/// because an alert on the root cannot appear above a presented sheet; only
/// the one that appeared last shows it.
struct ErrorAlert: ViewModifier {
    @Environment(AppModel.self) private var model
    @State private var id = UUID()

    func body(content: Content) -> some View {
        content
            .onAppear { model.errorPresenters.append(id) }
            .onDisappear { model.errorPresenters.removeAll { $0 == id } }
            .alert(
                "Hoppla",
                isPresented: Binding(
                    get: { model.errorMessage != nil && model.errorPresenters.last == id },
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
