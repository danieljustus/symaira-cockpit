import SwiftUI
import SymTuneCore
import SymairaTheme

/// The notch HUD's content (issue #224).
///
/// Two states in one view, because they share the top strip: collapsed is the
/// strip alone — two readouts on the shoulders either side of the camera cutout
/// — and expanded keeps that strip and hangs a card below it. Drawing them as
/// one view is what makes the expansion look like the strip growing rather than
/// a second window appearing.
///
/// Everything here is read off the same ``TuneViewModel`` the status item and
/// the popover use. There is no second polling pipeline and no formatting of
/// its own: the values are the `MetricRowData` rows the panel already renders.
@MainActor
struct NotchHUDView: View {
    let model: TuneViewModel
    @ObservedObject var preferences: PreferencesManager

    /// Width of the camera cutout — the dead zone between the shoulders.
    let notchWidth: CGFloat
    /// Width of one shoulder.
    let shoulderWidth: CGFloat
    /// Height of the menu bar strip the collapsed HUD lives in.
    let menuBarHeight: CGFloat

    let isExpanded: Bool
    let openPanel: () -> Void
    let openCockpit: () -> Void
    let openCockpitTitle: String

    var body: some View {
        VStack(spacing: 0) {
            strip
            if isExpanded {
                card
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background {
            background
                .clipShape(shape)
                .overlay(
                    // Only the bottom edge is drawn: the top edge is the
                    // physical bezel, and a line there would give the illusion
                    // away.
                    shape.strokeBorder(
                        isExpanded ? SymairaTheme.borderGlass : Color.clear,
                        lineWidth: 1
                    )
                )
                // The flare lives outside the frame the readouts were laid out
                // in. Negative padding is what buys it that room without
                // taking a single point away from the shoulders.
                .padding(.horizontal, -HUDBezel.cornerRadius)
        }
        .animation(SymairaTheme.transitionSmooth, value: isExpanded)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Notch HUD")
    }

    // MARK: - Shape and fill

    /// Flared into the bezel at the top, rounded at the bottom so it reads as
    /// one shape with the cutout above it.
    ///
    /// The top corners are concave — see ``HUDBezelShape``. Square ones there
    /// were what made the strip look like a black rectangle someone had pushed
    /// against the top of the screen; convex ones would have been worse, since
    /// they close the outline off entirely.
    private var shape: HUDBezelShape {
        HUDBezelShape(
            anchor: .top,
            flare: HUDBezel.cornerRadius,
            innerRadius: isExpanded ? SymairaRadius.panel : HUDBezel.cornerRadius
        )
    }

    /// Collapsed, the fill has to be the cutout's own black or the seam shows.
    /// Expanded, the card below the menu bar strip may be the usual glass.
    private var background: some View {
        ZStack {
            Color.black
            if isExpanded {
                SymairaTheme.bgCard.opacity(0.55)
                    .padding(.top, menuBarHeight)
            }
        }
    }

    // MARK: - Collapsed strip

    /// The two shoulders, with the cutout's width held open between them.
    private var strip: some View {
        HStack(spacing: 0) {
            shoulder(shoulderMetrics.first, alignment: .trailing)
            Color.clear.frame(width: notchWidth)
            shoulder(shoulderMetrics.dropFirst().first, alignment: .leading)
        }
        .frame(height: menuBarHeight)
    }

    /// The metrics the menu bar is configured to show, in the user's order —
    /// the same selection and the same order the status item uses, so the two
    /// readouts cannot disagree.
    private var shoulderMetrics: [MetricRowData] {
        let visible = preferences.visibleMetrics
        return model.metricRows.filter { visible.contains($0.id) }
    }

    private func shoulder(
        _ row: MetricRowData?,
        alignment: Alignment
    ) -> some View {
        Group {
            if let row {
                HStack(spacing: 3) {
                    Image(systemName: row.id.statusItemSymbol)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(SymairaTheme.goldPrimary)
                    Text(row.current)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(row.title) \(row.current)")
            } else {
                // Nothing to show on this side: the strip stays black, which
                // beside the cutout is indistinguishable from the bezel.
                Color.clear
            }
        }
        // Padding inside the fixed width, not around it: the shoulder's width
        // is what `NotchLayout` budgeted from the menu bar strip, and padding
        // applied outside the frame would quietly spend 8pt more per side.
        .padding(.horizontal, 4)
        .frame(width: shoulderWidth, alignment: alignment)
    }

    // MARK: - Expanded card

    private var card: some View {
        VStack(alignment: .leading, spacing: SymairaSpacing.small) {
            metrics
            Divider().overlay(SymairaTheme.borderGlass)
            state
            actions
        }
        .padding(SymairaSpacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .transition(.opacity)
    }

    /// Every monitored metric, not just the two on the shoulders — the point of
    /// expanding is to see what did not fit.
    private var metrics: some View {
        VStack(spacing: 4) {
            ForEach(model.metricRows) { row in
                HStack(spacing: SymairaSpacing.small) {
                    Image(systemName: row.id.statusItemSymbol)
                        .symairaText(.caption)
                        .frame(width: 16)
                        .foregroundStyle(SymairaTheme.goldPrimary)
                    Text(row.title)
                        .symairaText(.caption)
                        .foregroundStyle(SymairaTheme.textSecondary)
                    Spacer(minLength: SymairaSpacing.small)
                    Text(row.current)
                        .symairaText(.monoSmall)
                        .foregroundStyle(SymairaTheme.textPrimary)
                }
            }
            if model.metricRows.isEmpty {
                Text("No metric is being monitored")
                    .symairaText(.caption)
                    .foregroundStyle(SymairaTheme.textMuted)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// The two pieces of state that change what the machine is doing rather
    /// than what it is reporting.
    private var state: some View {
        HStack(spacing: SymairaSpacing.small) {
            chip(
                symbol: model.keepAwake.active ? "cup.and.saucer.fill" : "cup.and.saucer",
                title: model.keepAwake.active ? "Awake" : "Sleep allowed",
                active: model.keepAwake.active
            )
            chip(
                symbol: "fan",
                title: fanTitle,
                active: model.fanProfile != .system
            )
            Spacer(minLength: 0)
        }
    }

    /// A selected fan profile with no privileged governor behind it is not in
    /// effect, and the chip says so rather than claiming a state the fans are
    /// not in.
    private var fanTitle: String {
        let name = model.fanProfile.displayName
        guard model.fanProfile != .system else { return "Fans: \(name)" }
        return model.fanGovernorRunning ? "Fans: \(name)" : "Fans: \(name) (idle)"
    }

    private func chip(symbol: String, title: String, active: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
            Text(title)
        }
        .symairaText(.caption)
        .foregroundStyle(active ? SymairaTheme.goldPrimary : SymairaTheme.textMuted)
        .padding(.horizontal, SymairaSpacing.small)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: SymairaRadius.control)
                .fill(SymairaTheme.bgDarker.opacity(0.7))
        )
    }

    private var actions: some View {
        HStack(spacing: SymairaSpacing.small) {
            actionButton("Panel", symbol: "slider.horizontal.3", action: openPanel)
            actionButton(openCockpitTitle, symbol: "gauge.with.dots.needle.bottom.50percent", action: openCockpit)
            Spacer(minLength: 0)
        }
        .padding(.top, 2)
    }

    private func actionButton(
        _ title: String,
        symbol: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: symbol)
                Text(title)
            }
            .symairaText(.caption)
            .foregroundStyle(SymairaTheme.textPrimary)
            .padding(.horizontal, SymairaSpacing.small)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: SymairaRadius.control)
                    .fill(SymairaTheme.bgCardHover.opacity(0.8))
            )
            .overlay(
                RoundedRectangle(cornerRadius: SymairaRadius.control)
                    .strokeBorder(SymairaTheme.borderGlass, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
