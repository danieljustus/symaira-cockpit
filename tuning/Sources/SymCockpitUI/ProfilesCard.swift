import SwiftUI
import SymCockpitCore
import SymairaTheme

/// Saved display profiles (brightness, dimming, warmth): apply, save the current
/// look under a name, delete. All of it goes through the agent's `profile.*`
/// commands; applying and saving are reversible, deleting asks first.
@MainActor
struct ProfilesCard: View {
    let model: ProfilesModel
    let isAgentReady: Bool
    @State private var newName = ""
    @State private var deleting: String?

    var body: some View {
        VStack(alignment: .leading, spacing: SymairaSpacing.small) {
            Label("Profiles", symairaIcon: .tune, iconSize: 16)
                .symairaText(.subheading)
                .foregroundStyle(SymairaTokens.ink2)
            list
            saveRow
            feedback
        }
        .disabled(!isAgentReady)
        .cardStyle()
        .task { await model.load() }
        .confirmationDialog(
            "Delete this profile?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            presenting: deleting
        ) { name in
            Button("Delete Profile", role: .destructive) { Task { await model.delete(name) } }
            Button("Cancel", role: .cancel) {}
        } message: { name in
            Text("“\(name)” is removed from this Mac. Your display is not changed.")
        }
    }

    @ViewBuilder
    private var list: some View {
        switch model.state {
        case .idle, .loading:
            SymairaLoadingState("Loading profiles…")
        case .failed(let message):
            SymairaNotice(message: message, tone: .critical)
            Button("Retry") { Task { await model.load() } }
                .symairaButtonStyle(.secondary)
        case .loaded(let profiles) where profiles.isEmpty:
            Text("No profiles yet. Save the current brightness, dimming and warmth under a name to bring it back later.")
                .symairaText(.caption)
                .foregroundStyle(SymairaTokens.ink3)
                .fixedSize(horizontal: false, vertical: true)
        case .loaded(let profiles):
            VStack(spacing: SymairaSpacing.xSmall) {
                ForEach(profiles) { profile in
                    HStack(spacing: SymairaSpacing.small) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(profile.name)
                                .symairaText(.body, respectsForeground: false)
                                .foregroundStyle(SymairaTokens.ink)
                                .lineLimit(1)
                            Text(Self.summary(profile))
                                .symairaText(.caption)
                                .foregroundStyle(SymairaTokens.ink3)
                                .monospacedDigit()
                        }
                        Spacer(minLength: SymairaSpacing.small)
                        Button("Apply") { Task { await model.apply(profile.name) } }
                            .symairaButtonStyle(.secondary)
                            .accessibilityLabel("Apply profile \(profile.name)")
                        SymairaIconButton("Delete profile \(profile.name)", icon: .delete, size: 16) {
                            deleting = profile.name
                        }
                    }
                    .contextMenu {
                        Button("Apply Profile") { Task { await model.apply(profile.name) } }
                        Button("Delete Profile…", role: .destructive) { deleting = profile.name }
                    }
                }
            }
        }
    }

    private var saveRow: some View {
        HStack(spacing: SymairaSpacing.small) {
            TextField("Profile name, for example reading", text: $newName)
                .textFieldStyle(.symaira)
                .accessibilityLabel("Profile name")
                .onSubmit(save)
            Button("Save Profile", action: save)
                .symairaButtonStyle(.secondary)
                .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty || model.isBusy)
        }
    }

    @ViewBuilder
    private var feedback: some View {
        if let failure = model.failure {
            SymairaNotice(message: failure, tone: .critical)
        } else if let notice = model.notice {
            SymairaNotice(message: notice, tone: .positive)
        }
    }

    private func save() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        Task {
            await model.save(name)
            if model.failure == nil { newName = "" }
        }
    }

    /// "Brightness 40 % · Warmth 60 %": only what the profile holds.
    static func summary(_ profile: TuneProfile) -> String {
        var parts: [String] = []
        if let brightness = profile.brightness { parts.append("Brightness \(Int((brightness * 100).rounded())) %") }
        if let dim = profile.dim { parts.append("Dimming \(Int(((1 - dim) * 100).rounded())) %") }
        if let warmth = profile.warmth { parts.append("Warmth \(Int((warmth * 100).rounded())) %") }
        return parts.isEmpty ? "No display values" : parts.joined(separator: " · ")
    }
}
