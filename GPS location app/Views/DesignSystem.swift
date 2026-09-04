//
//  DesignSystem.swift
//  GPS location app
//
//  The vocabulary every tab is built from.
//
//  Before this file each tab had invented its own: Home used 16pt corners and coloured shadows,
//  Analysis used 12pt on iPhone and 16pt on iPad, History used 12pt with tinted translucent
//  buttons, Settings used the system Form. Five tabs, five idioms, one app. Nothing was wrong
//  individually and the whole read as unfinished.
//
//  So the shapes, spacing, and type live here and the tabs compose them.
//

import SwiftUI

// MARK: - Tokens

enum AppTheme {
    /// One radius for cards, one for the controls that sit inside them. Two values, not five —
    /// the nesting reads correctly only when the inner radius is visibly tighter.
    static let cardRadius: CGFloat = 18
    static let controlRadius: CGFloat = 12

    static let cardPadding: CGFloat = 16
    static let sectionSpacing: CGFloat = 18
    static let itemSpacing: CGFloat = 12

    /// Cards lift off the grouped background with a soft neutral shadow rather than a tinted one.
    /// Coloured shadows under every card made the old Home tab look like it was glowing.
    static let shadowColor = Color.black.opacity(0.06)
    static let shadowRadius: CGFloat = 10
    static let shadowY: CGFloat = 4

    /// A tint per domain, so the same concept is the same colour in every tab.
    static let distance = Color.blue
    static let pace = Color.orange
    static let duration = Color.purple
    static let elevation = Color.teal
    static let count = Color.green
}

// MARK: - Card

/// The single surface everything sits on.
struct AppCard<Content: View>: View {
    var padding: CGFloat = AppTheme.cardPadding
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: AppTheme.cardRadius, style: .continuous)
                    .fill(Color(.secondarySystemGroupedBackground))
            )
            .shadow(color: AppTheme.shadowColor,
                    radius: AppTheme.shadowRadius, x: 0, y: AppTheme.shadowY)
    }
}

extension View {
    func appCard(padding: CGFloat = AppTheme.cardPadding) -> some View {
        AppCard(padding: padding) { self }
    }
}

// MARK: - Section header

/// A title with an optional action on the right. Used instead of `Section("…")` outside Forms so
/// headers look the same whether or not they are in a List.
struct SectionHeader<Trailing: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            trailing
        }
    }
}

extension SectionHeader where Trailing == EmptyView {
    init(_ title: String, subtitle: String? = nil) {
        self.init(title: title, subtitle: subtitle) { EmptyView() }
    }
}

// MARK: - Metrics

/// One number and what it means. The number leads: it is the reason the tile exists, so it gets
/// the weight and a monospaced digit width so a changing value does not make the row twitch.
struct MetricTile: View {
    let icon: String
    let value: String
    let label: String
    var tint: Color = .accentColor
    var compact: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 6 : 10) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.caption)
                    .foregroundStyle(tint)
                Text(label.uppercased())
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .tracking(0.5)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Text(value)
                .font(compact ? .title3 : .title2)
                .fontWeight(.bold)
                .monospacedDigit()
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(compact ? 12 : 14)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.controlRadius, style: .continuous)
                .fill(tint.opacity(0.10))
        )
    }
}

/// A percentage change, coloured and arrowed. Neutral grey when there is nothing to compare
/// against — a grey dash is honest, and a green 0% is not.
struct TrendBadge: View {
    let change: Double
    let hasBaseline: Bool

    var body: some View {
        Group {
            if hasBaseline {
                HStack(spacing: 3) {
                    Image(systemName: change >= 0 ? "arrow.up.right" : "arrow.down.right")
                    Text(String(format: "%.0f%%", abs(change)))
                        .monospacedDigit()
                }
                .foregroundStyle(change >= 0 ? Color.green : Color.orange)
            } else {
                Text("—").foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .fontWeight(.semibold)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule().fill(
                hasBaseline
                    ? (change >= 0 ? Color.green : Color.orange).opacity(0.14)
                    : Color.secondary.opacity(0.12)
            )
        )
    }
}

// MARK: - Controls

/// The one full-width call to action. Only ever one on screen at a time.
struct PrimaryActionButton: View {
    let title: String
    let icon: String
    var tint: Color = .blue
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.title3)
                Text(title).font(.headline)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .foregroundStyle(.white)
            .background(
                RoundedRectangle(cornerRadius: AppTheme.cardRadius, style: .continuous)
                    .fill(LinearGradient(colors: [tint, tint.opacity(0.78)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
            )
            .shadow(color: tint.opacity(0.30), radius: 12, x: 0, y: 6)
        }
        .buttonStyle(.plain)
    }
}

/// A selectable pill. Replaces the four near-identical chip types the Analysis tab had, which
/// differed only in tint and corner radius.
struct AppChip: View {
    let title: String
    var icon: String? = nil
    let isSelected: Bool
    var tint: Color = .accentColor
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let icon { Image(systemName: icon) }
                Text(title)
            }
            .font(.subheadline)
            .fontWeight(isSelected ? .semibold : .regular)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .background(
                Capsule().fill(isSelected ? tint : Color(.secondarySystemGroupedBackground))
            )
        }
        .buttonStyle(.plain)
    }
}

/// A secondary action inside a card — bordered, tinted, and full width when placed in an HStack.
struct SecondaryActionButton: View {
    let title: String
    let icon: String
    var tint: Color = .accentColor
    var isEnabled: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                Text(title).lineLimit(1)
            }
            .font(.subheadline)
            .fontWeight(.medium)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .foregroundStyle(isEnabled ? tint : Color.secondary)
            .background(
                RoundedRectangle(cornerRadius: AppTheme.controlRadius, style: .continuous)
                    .fill((isEnabled ? tint : Color.secondary).opacity(0.12))
            )
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
    }
}

// MARK: - Empty state

/// Shown where data would be. Always says what to do next — an empty tab that only says "no data"
/// leaves the user to guess whether the app is broken or simply new.
struct EmptyStateCard: View {
    let icon: String
    let title: String
    let message: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        AppCard(padding: 24) {
            VStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 34))
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.headline)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                if let actionTitle, let action {
                    Button(actionTitle, action: action)
                        .font(.subheadline.weight(.semibold))
                        .padding(.top, 2)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }
}

/// Stops a screen stretching to the full width of an iPad.
///
/// A settings row is a label at one end and its value at the other. That reads fine across a
/// phone; across the 1100-point detail pane of a 13-inch iPad in landscape the two ends stop
/// belonging to each other, and the eye has to travel the width of the screen to pair them. The
/// same applies to any column of prose or form rows.
///
/// So the content keeps a readable measure and sits centred, with the extra width left as margin
/// — which is what the platform's own settings do. Compact widths are untouched: on a phone
/// there is no surplus to give away.
private struct ReadableColumn: ViewModifier {
    let maxWidth: CGFloat
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    func body(content: Content) -> some View {
        if horizontalSizeClass == .regular {
            content
                .frame(maxWidth: maxWidth)
                .frame(maxWidth: .infinity)
        } else {
            content
        }
    }
}

extension View {
    /// Cap this screen at a readable measure on iPad, and centre it. No effect on iPhone.
    func readableColumn(_ maxWidth: CGFloat = 760) -> some View {
        modifier(ReadableColumn(maxWidth: maxWidth))
    }
}
