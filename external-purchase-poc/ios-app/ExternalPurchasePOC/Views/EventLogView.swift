import SwiftUI

struct EventLogView: View {
    let entries: [EventLogEntry]

    var body: some View {
        Group {
            if entries.isEmpty {
                ContentUnavailableView(
                    "No Events Yet",
                    systemImage: "list.bullet.rectangle",
                    description: Text("State transitions will appear here as you use the app.")
                )
            } else {
                List(entries.reversed()) { entry in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.timestamp.formatted(date: .omitted, time: .standard))
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                        Text(entry.message)
                            .font(.footnote)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .navigationTitle("Event Log")
    }
}

#Preview {
    NavigationStack {
        EventLogView(entries: [
            EventLogEntry(timestamp: Date(), message: "App launched"),
            EventLogEntry(timestamp: Date(), message: "Checkout: buy tapped"),
        ])
    }
}
