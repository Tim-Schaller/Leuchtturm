import SwiftUI

struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @State private var name = ""
    @State private var server = ""
    @FocusState private var focused: Field?

    private enum Field { case name, server }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(spacing: 12) {
                        Image(systemName: "light.beacon.max")
                            .font(.system(size: 52))
                            .foregroundStyle(.tint)
                        Text("Willkommen bei Leuchtturm")
                            .font(.title2.bold())
                        Text("Teile deinen Standort mit den Menschen, die dir wichtig sind. Alles wird auf deinem Gerät verschlüsselt, der Server sieht nur Datensalat.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }
                .listRowBackground(Color.clear)

                Section {
                    TextField("Dein Name", text: $name)
                        .textContentType(.givenName)
                        .focused($focused, equals: .name)
                        .submitLabel(.next)
                        .onSubmit { focused = .server }
                } header: {
                    Text("Name")
                } footer: {
                    Text("So sehen dich die Mitglieder deiner Kreise. Nur sie können ihn lesen.")
                }

                Section {
                    TextField("leuchtturm.example.org", text: $server)
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focused, equals: .server)
                        .submitLabel(.go)
                        .onSubmit(start)
                } header: {
                    Text("Server")
                } footer: {
                    Text("Die Adresse deines Leuchtturm-Servers. Alle in einem Kreis müssen denselben Server benutzen.")
                }

                Section {
                    Button(action: start) {
                        HStack {
                            Spacer()
                            if model.isLoading {
                                ProgressView()
                            } else {
                                Text("Los geht's").bold()
                            }
                            Spacer()
                        }
                    }
                    .buttonStyle(.glassProminent)
                    .disabled(model.isLoading || name.isEmpty || server.isEmpty)
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }
            .navigationTitle(AppInfo.name)
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func start() {
        guard !model.isLoading else { return }
        Task { _ = await model.setUp(name: name, server: server) }
    }
}
