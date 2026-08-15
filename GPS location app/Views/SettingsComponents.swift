import SwiftUI

/// The pieces the settings, diagnostics and developer screens are built from.
///
/// They were three screens drawn three ways: one used rounded cards in a scroll view, one a
/// segmented control over hand-laid stacks, one a plain list. Nothing carried between them, so
/// the same idea — a permission, a status, a destructive action — looked different depending on
/// where you met it. These give all three one vocabulary.

/// A tinted SF Symbol tile, the shape iOS uses in its own Settings. It gives a list of rows a
/// scannable left edge: colour finds the row before the words are read.
struct SettingsIcon: View {
    let symbol: String
    let tint: Color
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 14, weight: .semibold))
            .foregroundColor(.white)
            .frame(width: 28, height: 28)
            .background(tint, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

/// State as a pill rather than plain text. "Authorized" and "Denied" are the same shape and
/// length as words; as coloured pills they are different at a glance, which is what a
/// diagnostics screen is for.
struct StatusPill: View {
    let text: String
    let tint: Color
    var body: some View {
        Text(text)
            .font(.caption2)
            .fontWeight(.medium)
            .foregroundColor(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(tint.opacity(0.14), in: Capsule())
            .lineLimit(1)
    }
}

/// A labelled row with an icon on the left and a value or pill on the right.
struct SettingsRow<Trailing: View>: View {
    let symbol: String
    let tint: Color
    let title: String
    var subtitle: String?
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 12) {
            SettingsIcon(symbol: symbol, tint: tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            Spacer(minLength: 8)
            trailing()
        }
    }
}

extension SettingsRow where Trailing == EmptyView {
    init(symbol: String, tint: Color, title: String, subtitle: String? = nil) {
        self.init(symbol: symbol, tint: tint, title: title, subtitle: subtitle) { EmptyView() }
    }
}

/// A number with its name under it, for the small summary strips at the top of a screen.
struct StatTile: View {
    let value: String
    let label: String
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(.subheadline, design: .rounded))
                .fontWeight(.semibold)
            Text(label)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
