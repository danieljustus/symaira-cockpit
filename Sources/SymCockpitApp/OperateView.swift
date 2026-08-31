import SwiftUI
import SymairaTheme
import SymOperateCore

/// The Operate section: permission state first, because nothing else in this
/// family works without it, then what is currently on screen.
@MainActor
struct OperateView: View {
    @ObservedObject var model: OperateViewModel

    @State private var query = ""

    var body: some View {
        CockpitSectionScroll(
            title: "Operate",
            command: CockpitSection.operate.command,
            status: model.isLoading ? "reading…" : nil
        ) {
            permissionsCard
            environmentCard
            CockpitSearchField(placeholder: "Filter apps and windows", text: $query)
            appsCard
            windowsCard
        }
        .onAppear { model.refresh() }
    }

    private func matches(_ fields: String?...) -> Bool {
        guard !query.isEmpty else { return true }
        return fields.contains { $0?.localizedCaseInsensitiveContains(query) == true }
    }

    private func subtitle(shown: Int, total: Int) -> String? {
        guard !query.isEmpty, shown != total else { return nil }
        return "\(shown) of \(total) match “\(query)”"
    }

    // MARK: - Permissions

    private var permissionsCard: some View {
        CockpitCard(
            title: "Permissions",
            subtitle: "Granted to this app, separately from the CLI",
            trailing: AnyView(CockpitRefreshButton(isLoading: model.isLoading) { model.refresh() })
        ) {
            if !model.accessibilityGranted || !model.screenRecordingGranted {
                // The one thing worth spelling out: people grant the CLI and
                // then wonder why the app still cannot see anything.
                Text("macOS keys these to the binary that asks. Granting them to your terminal does not grant them here.")
                    .font(SymairaTypography.caption)
                    .foregroundStyle(SymairaTheme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 0) {
                permissionRow(
                    name: "Accessibility",
                    detail: "Read the UI tree, click and type",
                    symbol: "hand.tap",
                    granted: model.accessibilityGranted,
                    request: { model.requestAccessibility() }
                )
                Divider().overlay(SymairaTheme.borderGlass)
                permissionRow(
                    name: "Screen Recording",
                    detail: "Screenshots and OCR",
                    symbol: "camera.viewfinder",
                    granted: model.screenRecordingGranted,
                    request: { model.requestScreenRecording() }
                )
            }

            if let source = model.permissions?.source {
                // The source carries a long explanatory note aimed at CLI
                // users ("grant these to the process that will use them") —
                // in the GUI that process is simply this app, so the row only
                // names the binary the grants belong to.
                Text("Reported for \((source.executablePath as NSString).lastPathComponent) · pid \(String(source.pid))")
                    .font(SymairaTypography.caption)
                    .foregroundStyle(SymairaTheme.textMuted)
                    .help(source.note)
            }
        }
    }

    private func permissionRow(
        name: String,
        detail: String,
        symbol: String,
        granted: Bool,
        request: @escaping () -> Void
    ) -> some View {
        CockpitRow {
            HStack(spacing: SymairaSpacing.medium) {
                Image(systemName: symbol)
                    .font(.system(size: 13))
                    .frame(width: 20)
                    .foregroundStyle(granted ? SymairaTheme.positive : SymairaTheme.textMuted)
                CockpitRowLabel(title: name, detail: detail)
            }
        } trailing: {
            HStack(spacing: SymairaSpacing.small) {
                CockpitBadge(
                    text: granted ? "granted" : "missing",
                    tint: granted ? SymairaTheme.positive : SymairaTheme.critical
                )
                if !granted {
                    Button("Grant…", action: request)
                        .buttonStyle(.borderless)
                        .font(SymairaTypography.caption)
                        .help("Opens the system prompt, or System Settings if you answered it before")
                }
            }
        }
    }

    // MARK: - Environment

    private var environmentCard: some View {
        CockpitCard(title: "Environment") {
            HStack(alignment: .top, spacing: SymairaSpacing.large) {
                CockpitStat(value: String(model.apps.count), caption: "apps")
                CockpitStat(value: String(model.windows.count), caption: "windows")
                CockpitStat(value: String(model.displays.count), caption: "displays")
                CockpitStat(value: Self.macOSVersion, caption: "macOS")
            }
        }
    }

    /// `operatingSystemVersionString` reads "Version 27.0 (Build 26A5416b)" —
    /// four words for one number. The stat tile wants the number.
    private static var macOSVersion: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion)"
    }

    // MARK: - Apps and windows

    private var filteredApps: [AppInfo] {
        model.apps.filter { matches($0.localizedName, $0.bundleIdentifier) }
    }

    private var appsCard: some View {
        CockpitDisclosureCard(
            title: "Running apps",
            subtitle: subtitle(shown: filteredApps.count, total: model.apps.count),
            count: model.apps.count,
            storageKey: "operate.apps"
        ) {
            if filteredApps.isEmpty {
                CockpitEmptyRow(
                    text: model.apps.isEmpty ? "Nothing running." : "No match for “\(query)”.",
                    symbol: model.apps.isEmpty ? "app.dashed" : "line.3.horizontal.decrease"
                )
            } else {
                CockpitList(items: filteredApps) { app, _ in
                    CockpitRow {
                        CockpitRowLabel(
                            title: app.localizedName,
                            detail: app.bundleIdentifier ?? "pid \(String(app.processIdentifier))",
                            monospacedDetail: true
                        )
                    } trailing: {
                        if app.isActive {
                            CockpitBadge(text: "frontmost", tint: SymairaTheme.goldPrimary)
                        }
                    }
                }
            }
        }
    }

    private var filteredWindows: [WindowInfo] {
        model.windows.filter { matches($0.title, $0.ownerName) }
    }

    private var windowsCard: some View {
        CockpitDisclosureCard(
            title: "Windows",
            subtitle: subtitle(shown: filteredWindows.count, total: model.windows.count),
            count: model.windows.count,
            storageKey: "operate.windows",
            initiallyExpanded: false
        ) {
            if filteredWindows.isEmpty {
                CockpitEmptyRow(
                    text: emptyWindowsText,
                    symbol: model.screenRecordingGranted ? "macwindow" : "eye.slash"
                )
            } else {
                CockpitList(items: filteredWindows) { window, _ in
                    CockpitRow {
                        CockpitRowLabel(
                            title: window.title?.isEmpty == false ? window.title! : "(untitled)",
                            detail: window.ownerName
                        )
                    } trailing: {
                        Text("\(String(Int(window.bounds.width)))×\(String(Int(window.bounds.height)))")
                            .font(SymairaTypography.monoSmall)
                            .foregroundStyle(SymairaTheme.textSecondary)
                    }
                }
            }
        }
    }

    private var emptyWindowsText: String {
        if !model.windows.isEmpty { return "No match for “\(query)”." }
        return model.screenRecordingGranted
            ? "No windows reported."
            : "Window titles need Screen Recording."
    }
}
