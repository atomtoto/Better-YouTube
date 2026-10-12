import SwiftUI

/// What Settings shows in place of the account while a demo runs: what the demo is, and the way
/// out of it. It stands where Sign Out would, which in a demo would have signed out the device's
/// real account rather than the demo's.
struct DemoSection: View {
    @ObservedObject private var demo = DemoMode.shared

    var body: some View {
        Section {
            Label {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Demo Mode")
                        .font(.headline)
                    Text("You're trying Better YouTube with a catalogue of real videos. Liking, subscribing and commenting need a Google sign-in.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "sparkles.tv")
                    .foregroundStyle(.tint)
            }
            .padding(.vertical, 4)

            Button("Quit Demo", role: .destructive) {
                Task { await demo.exit() }
            }
        } footer: {
            Text("Quitting deletes the demo's library, searches and downloads. Your own library, sign-ins and iCloud sync carry on as they were.")
        }
    }
}

extension View {
    /// The Demo menu at the leading edge of a screen's toolbar while a demo runs, so it is always
    /// clear what is on screen — and how to leave.
    func demoMenu() -> some View {
        modifier(DemoMenu())
    }
}

private struct DemoMenu: ViewModifier {
    @ObservedObject private var demo = DemoMode.shared

    func body(content: Content) -> some View {
        content.toolbar {
            if demo.isActive {
                ToolbarItem(placement: .navigation) {
                    Menu {
                        // Short: a menu cuts anything past a few lines.
                        Text("Real videos — nothing leaves this device.")
                        Button("Quit Demo", systemImage: "xmark.circle", role: .destructive) {
                            Task { await demo.exit() }
                        }
                    } label: {
                        // Words rather than a symbol: a toolbar shows a label's icon alone, and no
                        // symbol says "this is a demo" on its own.
                        Text("Demo")
                    }
                }
            }
        }
    }
}
