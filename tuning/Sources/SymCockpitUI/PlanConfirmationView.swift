import SwiftUI
import SymCockpitCore
import SymairaTheme

/// The one place where a plan of a risky command is shown to the person who has to
/// approve it: the command, what it touches (target and size where the plan knows
/// it), how long it stays valid, then Cancel or the verb that applies it. After
/// that it shows what happened to every entry. The agent recorded the plan and
/// executes it; this view decides nothing (`PlanConfirmationModel` carries the logic).
///
/// Inline, so it works in the popover's 320 pt column and in a window page alike. Esc cancels;
/// Return does not confirm, because this changes the hardware of the Mac.
struct PlanConfirmationView: View {
    let model: PlanConfirmationModel
    /// What the change does in words, when the host knows (a fan profile, a limit).
    var summary: String?
    /// The verb on the button that applies it, e.g. "Apply Fan Profile".
    var confirmTitle = "Apply Changes"
    /// Dismisses the review (Cancel) or the result (Done).
    let onClose: () -> Void

    /// Entries listed before the rest is summarised; a plan can hold thousands.
    private static let visibleItems = 6

    var body: some View {
        VStack(alignment: .leading, spacing: SymairaSpacing.small) {
            switch model.phase {
            case .reviewing, .running:
                review
            case .finished(let report):
                result(report)
            }
        }
        .accessibilityIdentifier("plan-confirmation")
    }

    // MARK: Review

    private var isRunning: Bool { model.phase == .running }

    private var review: some View {
        VStack(alignment: .leading, spacing: SymairaSpacing.small) {
            Text("Review Plan")
                .symairaText(.subheading, respectsForeground: false)
                .foregroundStyle(SymairaTokens.ink)
            Text(model.plan.command)
                .symairaText(.monoSmall, respectsForeground: false)
                .foregroundStyle(SymairaTokens.ink2)
                .textSelection(.enabled)
            if let summary {
                Text(summary)
                    .symairaText(.caption, respectsForeground: false)
                    .foregroundStyle(SymairaTokens.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            entries
            expiry
            if isRunning {
                SymairaLoadingState("Applying… you may be asked for your administrator password…")
            } else {
                HStack(spacing: SymairaSpacing.small) {
                    Button("Cancel", role: .cancel, action: onClose)
                        .symairaButtonStyle(.secondary)
                        .keyboardShortcut(.cancelAction)
                    Button(confirmTitle) { Task { await model.confirm() } }
                        .symairaButtonStyle(.primary)
                }
            }
        }
    }

    private var entries: some View {
        let items = model.plan.items
        return VStack(alignment: .leading, spacing: SymairaSpacing.xSmall) {
            ForEach(Array(items.prefix(Self.visibleItems).enumerated()), id: \.offset) { _, item in
                HStack(spacing: SymairaSpacing.small) {
                    Text(item.target)
                        .symairaText(.caption, respectsForeground: false)
                        .foregroundStyle(SymairaTokens.ink)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(item.target)
                    Spacer(minLength: SymairaSpacing.small)
                    if let size = item.sizeBytes {
                        Text(Self.size(size))
                            .symairaText(.caption, respectsForeground: false)
                            .foregroundStyle(SymairaTokens.ink2)
                            .monospacedDigit()
                    }
                }
            }
            if items.count > Self.visibleItems {
                Text("and \(items.count - Self.visibleItems) more")
                    .symairaText(.caption)
                    .foregroundStyle(SymairaTokens.ink3)
            }
            if let total = Self.total(items), items.count > 1 {
                Text("\(Self.size(total)) in total")
                    .symairaText(.caption)
                    .foregroundStyle(SymairaTokens.ink3)
                    .monospacedDigit()
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Entries of the plan")
    }

    /// Counts down once a second; no timer runs while the plan is not on screen.
    private var expiry: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            if let seconds = model.secondsRemaining(at: context.date) {
                if seconds == 0 {
                    SymairaStatusLabel("Expired. Request the change again.", tone: .warning)
                } else {
                    Text("Nothing has changed yet. Valid for \(Self.clock(seconds)).")
                        .symairaText(.caption)
                        .foregroundStyle(SymairaTokens.ink3)
                        .monospacedDigit()
                }
            } else {
                Text("Nothing has changed yet.")
                    .symairaText(.caption)
                    .foregroundStyle(SymairaTokens.ink3)
            }
        }
    }

    // MARK: Result

    @ViewBuilder
    private func result(_ report: PlanReport) -> some View {
        if report.isConfirmed {
            SymairaNotice(title: "Applied", message: summary ?? model.plan.command, tone: .positive)
        } else {
            SymairaNotice(
                title: "Not applied",
                message: report.failureMessage ?? "The agent reported “\(report.status.rawValue)”.",
                tone: .critical
            )
        }
        if !report.items.isEmpty {
            VStack(alignment: .leading, spacing: SymairaSpacing.xSmall) {
                ForEach(report.items.prefix(Self.visibleItems)) { item in
                    HStack(alignment: .firstTextBaseline, spacing: SymairaSpacing.small) {
                        Text(item.target)
                            .symairaText(.caption, respectsForeground: false)
                            .foregroundStyle(SymairaTokens.ink)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help([item.target, item.detail].compactMap { $0 }.joined(separator: "\n"))
                        Spacer(minLength: SymairaSpacing.small)
                        SymairaStatusLabel(item.outcome.label, tone: Self.tone(item.outcome))
                    }
                }
                if report.items.count > Self.visibleItems {
                    let rest = report.items.dropFirst(Self.visibleItems)
                    Text("and \(rest.count) more, \(rest.filter { $0.outcome != .confirmed }.count) not done")
                        .symairaText(.caption)
                        .foregroundStyle(SymairaTokens.ink3)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Result per entry")
        }
        Button("Done", action: onClose)
            .symairaButtonStyle(.secondary)
    }

    // MARK: Formatting

    static func tone(_ outcome: PlanOutcome) -> SymairaTone {
        switch outcome {
        case .confirmed: .positive
        case .unconfirmed, .skippedChanged: .warning
        case .failed: .critical
        case .unsupported, .other: .neutral
        }
    }

    static func size(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    static func total(_ items: [AgentPlan.Item]) -> Int? {
        let sizes = items.compactMap(\.sizeBytes)
        return sizes.isEmpty ? nil : sizes.reduce(0, +)
    }

    static func clock(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
