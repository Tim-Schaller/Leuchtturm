import SwiftUI

struct ContentView: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [.indigo.opacity(0.35), .teal.opacity(0.25)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 12) {
                Image(systemName: "person.2.fill")
                    .font(.system(size: 44))
                Text(AppInfo.name)
                    .font(.largeTitle.bold())
                Text("Private location sharing.\nEnd-to-end encrypted.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
            .padding(32)
            .glassEffect(in: .rect(cornerRadius: 28))
        }
    }
}

#Preview {
    ContentView()
}
