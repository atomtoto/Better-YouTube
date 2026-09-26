import SwiftUI

/// The day's allowance, which is the resource this app actually runs on.
struct QuotaSection: View {
    @EnvironmentObject private var quota: QuotaTracker

    var body: some View {
        Section {
            QuotaGauge(quota: quota)

            // Where it went, biggest first — a single search is worth a hundred of anything else,
            // and that is only obvious once it is written down.
            ForEach(quota.breakdown.prefix(4)) { spend in
                LabeledContent(spend.title, value: spend.units.formatted())
            }

            if quota.used > 0 {
                Button("Reset Counter", role: .destructive) {
                    quota.reset()
                }
            }
        } header: {
            Text("API Quota")
        } footer: {
            Text("""
            The Data API gives a Cloud project \(QuotaTracker.dailyLimit.formatted()) units a day \
            and no way to ask what is left, so this is the app's own tally of what it has spent: \
            a search costs 100 units, every other read 1, and each change to a custom playlist \
            costs 50. Anything else using the same Cloud project spends from the same allowance \
            without appearing here. Google refills it at midnight Pacific time.
            """)
        }
        // Catches the day turning over while the app sat in the background.
        .onAppear { quota.refresh() }
    }
}

/// The day's allowance at a glance: what is left in figures, and how much has gone as a bar.
/// The bar warms from green through amber to red as the day's spending climbs, so the state
/// reads before the numbers do.
private struct QuotaGauge: View {
    @ObservedObject var quota: QuotaTracker

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(quota.remaining, format: .number)
                    .font(.system(.title, design: .rounded).weight(.semibold))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text("of \(QuotaTracker.dailyLimit.formatted()) units left")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }

            QuotaBar(fraction: quota.fraction, tint: tint)

            HStack(spacing: 8) {
                Text("\(quota.used.formatted()) spent today")
                Spacer(minLength: 0)
                Text("Resets at \(quota.resetDate.formatted(date: .omitted, time: .shortened))")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
        .animation(.snappy, value: quota.used)
    }

    /// Green while there is room, amber once three quarters have gone, red at the end.
    private var tint: Color {
        switch quota.fraction {
        case ..<0.75: return .green
        case ..<0.9: return .orange
        default: return .red
        }
    }
}

/// The bar itself: a capsule track with the spent share filled over it.
private struct QuotaBar: View {
    let fraction: Double
    let tint: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(Color.appTertiaryFill)
                Capsule(style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [tint.opacity(0.55), tint],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    // A few units in, the fill would be a sliver too thin to read as a shape;
                    // give it at least its own height so it starts as a dot rather than a line.
                    .frame(width: fraction > 0 ? max(10, proxy.size.width * fraction) : 0)
            }
        }
        .frame(height: 10)
        .accessibilityElement()
        .accessibilityLabel("Quota spent")
        .accessibilityValue("\(Int((fraction * 100).rounded())) percent")
    }
}
