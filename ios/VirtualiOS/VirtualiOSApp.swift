import SwiftUI

@main
struct VirtualiOSApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

struct ContentView: View {
    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground)
                .ignoresSafeArea()

            VStack(spacing: 24) {
                Image(systemName: "iphone.gen3")
                    .font(.system(size: 54, weight: .light))
                    .foregroundStyle(.tint)

                VStack(spacing: 8) {
                    Text("VirtualiOS")
                        .font(.largeTitle.bold())

                    Text("ARM64 virtualization research")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 14) {
                    statusRow("Host app", detail: "Running", symbol: "checkmark.circle.fill", good: true)
                    statusRow("Virtual machine engine", detail: "Not integrated yet", symbol: "hourglass", good: false)
                    statusRow("Guest operating system", detail: "Not configured", symbol: "circle.dashed", good: false)
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 20))

                Text("This is the native host-app foundation. It does not boot iOS 15 yet.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12)

                Spacer(minLength: 0)

                Text("Stage 1 · Host application")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.tertiary)
            }
            .padding(24)
            .frame(maxWidth: 520)
        }
        .tint(.blue)
    }

    private func statusRow(
        _ title: String,
        detail: String,
        symbol: String,
        good: Bool
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(good ? .green : .secondary)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
    }
}
