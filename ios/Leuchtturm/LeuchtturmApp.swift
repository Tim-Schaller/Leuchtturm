import SwiftUI

@main
struct LeuchtturmApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .onOpenURL { model.handle(url: $0) }
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model

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
