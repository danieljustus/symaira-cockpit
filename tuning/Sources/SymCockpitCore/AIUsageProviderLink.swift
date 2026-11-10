import Foundation

/// Browser destinations only; opening a link never supplies credentials.
public struct AIUsageProviderLink: Identifiable, Sendable {
    public let title: String
    public let url: URL
    public var id: String { url.absoluteString }

    public static func links(for providerID: String) -> [Self] {
        let destinations: [(String, String)]
        switch providerID {
        case "claude": destinations = [("Status", "https://status.anthropic.com/"), ("Dashboard", "https://claude.ai/settings/usage")]
        case "codex": destinations = [("Status", "https://status.openai.com/"), ("Dashboard", "https://chatgpt.com/settings/usage")]
        case "copilot": destinations = [("Status", "https://www.githubstatus.com/"), ("Dashboard", "https://github.com/settings/billing")]
        case "cursor": destinations = [("Status", "https://status.cursor.com/"), ("Dashboard", "https://www.cursor.com/dashboard")]
        case "devin": destinations = [("Dashboard", "https://app.devin.ai/settings/plans")]
        case "grok": destinations = [("Usage", "https://grok.com/?_s=usage")]
        case "ollama": destinations = [("Usage", "https://ollama.com/settings"), ("API Keys", "https://ollama.com/settings/keys")]
        case "opencode": destinations = [("Dashboard", "https://opencode.ai/auth")]
        case "openrouter": destinations = [("Activity", "https://openrouter.ai/activity"), ("Credits", "https://openrouter.ai/settings/credits")]
        case "zai": destinations = [("Dashboard", "https://z.ai/manage-apikey/coding-plan/personal/my-plan"), ("API Keys", "https://z.ai/manage-apikey/apikey-list")]
        default: destinations = []
        }
        return destinations.compactMap { title, address in
            guard let url = URL(string: address), url.scheme == "https" else { return nil }
            return Self(title: title, url: url)
        }
    }
}
