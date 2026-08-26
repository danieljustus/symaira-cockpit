import SwiftUI
import SymairaTheme

// MARK: - Cards

/// A titled card with the cockpit's glass styling — the container every
/// section builds out of, so Scope and Operate read like the Tune panel.
///
/// The header is the card's control strip: title, an optional count on the
/// right of it, and whatever actions the section needs. Actions sit in the
/// header rather than under the content so a long list never pushes its own
/// refresh button off screen.
struct CockpitCard<Content: View>: View {
    let title: String
    var subtitle: String?
    var count: Int?
    var trailing: AnyView?
    @ViewBuilder let content: Content

    init(
        title: String,
        subtitle: String? = nil,
        count: Int? = nil,
        trailing: AnyView? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.count = count
        self.trailing = trailing
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SymairaSpacing.medium) {
            CockpitCardHeader(title: title, subtitle: subtitle, count: count, trailing: trailing)
            content
        }
        .padding(SymairaSpacing.large)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cockpitCardSurface()
    }
}

/// A card whose body can be folded away, with the fold remembered per card.
///
/// Scope and Operate list things that range from a handful to a few dozen
/// rows. Collapsing is what keeps a section scannable: the header still
/// carries the count, so a folded card is a one-line answer rather than a
/// hidden one.
struct CockpitDisclosureCard<Content: View>: View {
    let title: String
    var subtitle: String?
    var count: Int?
    var trailing: AnyView?
    /// Storage key for the fold state; unique per card.
    let storageKey: String
    var initiallyExpanded = true
    @ViewBuilder let content: Content

    @AppStorage private var isExpanded: Bool

    init(
        title: String,
        subtitle: String? = nil,
        count: Int? = nil,
        trailing: AnyView? = nil,
        storageKey: String,
        initiallyExpanded: Bool = true,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.count = count
        self.trailing = trailing
        self.storageKey = storageKey
        self.initiallyExpanded = initiallyExpanded
        self.content = content()
        self._isExpanded = AppStorage(
            wrappedValue: initiallyExpanded,
            "com.symaira.cockpit.card.\(storageKey)"
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SymairaSpacing.medium) {
            HStack(alignment: .firstTextBaseline, spacing: SymairaSpacing.small) {
                Button {
                    withAnimation(SymairaTheme.transitionFast) { isExpanded.toggle() }
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: SymairaSpacing.small) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(SymairaTheme.textMuted)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        CockpitCardHeader(title: title, subtitle: subtitle, count: count, trailing: nil)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(isExpanded ? "Collapse" : "Expand")

                if let trailing {
                    trailing
                }
            }

            if isExpanded {
                content
            }
        }
        .padding(SymairaSpacing.large)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cockpitCardSurface()
    }
}

/// Title / subtitle / count / actions — shared by both card kinds so their
/// headers line up pixel for pixel.
private struct CockpitCardHeader: View {
    let title: String
    var subtitle: String?
    var count: Int?
    var trailing: AnyView?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: SymairaSpacing.small) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: SymairaSpacing.small) {
                    Text(title.uppercased())
                        .font(SymairaTypography.label)
                        .foregroundStyle(SymairaTheme.goldPrimary)
                        .kerning(0.6)
                    if let count {
                        Text(String(count))
                            .font(SymairaTypography.micro)
                            .monospacedDigit()
                            .foregroundStyle(SymairaTheme.textSecondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(SymairaTheme.borderGlass))
                    }
                }
                if let subtitle {
                    Text(subtitle)
                        .font(SymairaTypography.caption)
                        .foregroundStyle(SymairaTheme.textMuted)
                }
            }
            Spacer(minLength: SymairaSpacing.small)
            if let trailing {
                trailing
            }
        }
    }
}

extension View {
    /// The card's fill and hairline border, in one place so every surface in
    /// the window matches.
    func cockpitCardSurface(hovered: Bool = false) -> some View {
        background(
            RoundedRectangle(cornerRadius: SymairaRadius.card, style: .continuous)
                .fill(hovered ? SymairaTheme.bgCardHover : SymairaTheme.bgCard)
        )
        .overlay(
            RoundedRectangle(cornerRadius: SymairaRadius.card, style: .continuous)
                .stroke(hovered ? SymairaTheme.borderGlassHover : SymairaTheme.borderGlass, lineWidth: 1)
        )
    }
}

// MARK: - Rows

/// One list row: a name, a supporting line, and trailing detail.
///
/// Rows alternate nothing and draw no separators of their own — the list draws
/// them between rows (``CockpitList``), which keeps a single row reusable in
/// contexts that want no rules at all.
struct CockpitRow<Leading: View, Trailing: View>: View {
    @ViewBuilder let leading: Leading
    @ViewBuilder let trailing: Trailing

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: SymairaSpacing.medium) {
            leading
            Spacer(minLength: SymairaSpacing.small)
            trailing
        }
        .padding(.horizontal, SymairaSpacing.small)
        .padding(.vertical, SymairaSpacing.small)
        .background(
            RoundedRectangle(cornerRadius: SymairaRadius.control, style: .continuous)
                .fill(isHovered ? SymairaTheme.bgCardHover : .clear)
        )
        .onHover { isHovered = $0 }
    }
}

/// A title line with a muted detail line underneath — the left half of most
/// rows in the window.
struct CockpitRowLabel: View {
    let title: String
    var detail: String?
    var titleColor: Color = SymairaTheme.textPrimary
    var monospacedDetail = false

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(SymairaTypography.bodyMedium)
                .foregroundStyle(titleColor)
                .lineLimit(1)
                .truncationMode(.middle)
            if let detail {
                Text(detail)
                    .font(monospacedDetail ? SymairaTypography.monoSmall : SymairaTypography.caption)
                    .foregroundStyle(SymairaTheme.textMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Rows with hairlines between them and nothing above the first or below the
/// last — a plain `Divider()` per row would double up at the card's edges.
///
/// Past ``scrollAfter`` rows the list scrolls inside its own card instead of
/// growing the page. Twenty listening ports are normal on a developer machine,
/// and letting one card run to a full screen height buries every card under it.
struct CockpitList<Item, RowContent: View>: View {
    let items: [Item]
    var scrollAfter: Int = 9
    @ViewBuilder let row: (Item, Int) -> RowContent

    /// Roughly one row plus its hairline; only used to size the scroll area,
    /// so being a few points off just shows a little more or less of the row
    /// that is meant to be visibly cut off.
    private static var approximateRowHeight: CGFloat { 44 }

    var body: some View {
        if items.count > scrollAfter {
            ScrollView(.vertical) {
                rows
            }
            .frame(maxHeight: CGFloat(scrollAfter) * Self.approximateRowHeight)
            .scrollIndicators(.visible)
        } else {
            rows
        }
    }

    private var rows: some View {
        VStack(spacing: 0) {
            ForEach(items.indices, id: \.self) { index in
                if index > 0 {
                    Divider().overlay(SymairaTheme.borderGlass)
                }
                row(items[index], index)
            }
        }
    }
}

// MARK: - Small parts

/// A single headline number with a caption — the overview's unit of content.
struct CockpitStat: View {
    let value: String
    let caption: String
    var tint: Color = SymairaTheme.textPrimary
    /// Dims the value while the first load is still running, so a placeholder
    /// zero does not read as a measured zero.
    var isPlaceholder = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(.title2, design: .rounded, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(tint)
                .opacity(isPlaceholder ? 0.35 : 1)
                .contentTransition(.numericText())
            Text(caption)
                .font(SymairaTypography.caption)
                .foregroundStyle(SymairaTheme.textMuted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A small pill for a boolean or status word.
struct CockpitBadge: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(SymairaTypography.micro)
            .foregroundStyle(tint)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, SymairaSpacing.small)
            .padding(.vertical, 2)
            .background(Capsule().fill(tint.opacity(0.14)))
            .overlay(Capsule().stroke(tint.opacity(0.25), lineWidth: 1))
    }
}

/// The refresh control every live section carries: one button that also
/// reports that a load is in flight.
struct CockpitRefreshButton: View {
    let isLoading: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            if isLoading {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "arrow.clockwise")
            }
        }
        .buttonStyle(.borderless)
        .disabled(isLoading)
        .help("Refresh (⌘R)")
        .frame(width: 20, height: 16)
    }
}

/// The filter box above a long list.
struct CockpitSearchField: View {
    let placeholder: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: SymairaSpacing.small) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(SymairaTheme.textMuted)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(SymairaTypography.callout)
                .foregroundStyle(SymairaTheme.textPrimary)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(SymairaTheme.textMuted)
                }
                .buttonStyle(.plain)
                .help("Clear")
            }
        }
        .padding(.horizontal, SymairaSpacing.small)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: SymairaRadius.control, style: .continuous)
                .fill(SymairaTheme.bgDarker.opacity(0.6))
        )
        .overlay(
            RoundedRectangle(cornerRadius: SymairaRadius.control, style: .continuous)
                .stroke(SymairaTheme.borderGlass, lineWidth: 1)
        )
    }
}

/// What a list shows when it has nothing to show.
///
/// Distinguishes "still loading", "your filter matched nothing" and "there is
/// genuinely nothing here" — three states that look identical if you only draw
/// an empty box.
struct CockpitEmptyRow: View {
    let text: String
    var symbol: String = "tray"
    var isLoading = false

    var body: some View {
        HStack(spacing: SymairaSpacing.small) {
            if isLoading {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: symbol)
                    .font(.system(size: 12))
                    .foregroundStyle(SymairaTheme.textMuted)
            }
            Text(text)
                .font(SymairaTypography.caption)
                .foregroundStyle(SymairaTheme.textMuted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, SymairaSpacing.small)
    }
}

// MARK: - Layout

/// The scrolling frame each section's cards sit in.
///
/// One column, capped at a readable width and centred — a section stretched
/// across a wide window turns every row into a sparse line with the detail
/// stranded a foot away from the name.
struct CockpitSectionScroll<Content: View>: View {
    let title: String
    var command: String?
    var status: String?
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SymairaSpacing.large) {
                header
                content
            }
            .padding(.horizontal, SymairaSpacing.xLarge)
            .padding(.vertical, SymairaSpacing.large)
            .frame(maxWidth: 780, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .top)
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(SymairaTypography.title)
                    .foregroundStyle(SymairaTheme.textPrimary)
                if let command {
                    Text(command)
                        .font(SymairaTypography.monoSmall)
                        .foregroundStyle(SymairaTheme.textMuted)
                        .textSelection(.enabled)
                        .help("The command that prints the same data")
                }
            }
            Spacer(minLength: SymairaSpacing.small)
            if let status {
                Text(status)
                    .font(SymairaTypography.caption)
                    .foregroundStyle(SymairaTheme.textMuted)
                    .monospacedDigit()
            }
        }
        .padding(.bottom, SymairaSpacing.xSmall)
    }
}
