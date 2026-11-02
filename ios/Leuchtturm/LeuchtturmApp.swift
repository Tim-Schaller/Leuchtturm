import BackgroundTasks
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
        // Now and then while the app is closed: a fresh position and battery level.
        BGTaskScheduler.shared.register(forTaskWithIdentifier: AppModel.refreshTask, using: .main) { [model] task in
            MainActor.assumeIsolated {
                AppModel.scheduleRefresh()
                let work = Task {
                    await model.backgroundRefresh()
                    task.setTaskCompleted(success: true)
                }
                task.expirationHandler = { work.cancel() }
            }
        }
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
            if phase == .background { AppModel.scheduleRefresh() }
        }
    }
}

/// Shows `AppModel.errorMessage` as a note that slides in at the top and
/// goes away by itself, instead of an alert that stops everything.
/// Attached to the root and to every sheet, because the root is covered
/// by a presented sheet; only the one that appeared last shows it.
struct ErrorAlert: ViewModifier {
    @Environment(AppModel.self) private var model
    @State private var id = UUID()

    private var message: String? { model.errorPresenters.last == id ? model.errorMessage : nil }

    func body(content: Content) -> some View {
        content
            .onAppear { model.errorPresenters.append(id) }
            .onDisappear { model.errorPresenters.removeAll { $0 == id } }
            .overlay(alignment: .top) {
                if let message {
                    ErrorToast(message: message) { model.errorMessage = nil }
                        .padding(.horizontal)
                        .padding(.top, 8)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .task(id: message) {
                            try? await Task.sleep(for: .seconds(6))
                            if model.errorMessage == message { model.errorMessage = nil }
                        }
                }
            }
            .animation(.snappy, value: message)
            .sensoryFeedback(trigger: message) { _, new in new != nil ? .error : nil }
    }
}

private struct ErrorToast: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        Button(action: dismiss) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.Tone.sun)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .glassEffect(.regular, in: .rect(cornerRadius: Theme.Radius.card, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(message))
        .accessibilityHint("Schließt den Hinweis")
    }
}

extension View {
    func errorAlert() -> some View { modifier(ErrorAlert()) }
}
