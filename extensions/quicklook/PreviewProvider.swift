import Foundation
import QuickLookUI
import UniformTypeIdentifiers

// Quick Look for folders and archives (R70, R71). No domain logic: the path goes to
// libsymcockpit_ffi, which lists with limits and never unpacks; this file turns the JSON into HTML.
@objc(SymPreviewProvider)
final class PreviewProvider: QLPreviewProvider, QLPreviewingController {
    func providePreview(for request: QLFilePreviewRequest) async throws -> QLPreviewReply {
        let url = request.fileURL
        let isFolder = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        let raw = (isFolder ? symcockpit_list_dir_json : symcockpit_list_archive_json)(url.path, nil)
        defer { symcockpit_free_string(raw) }
        let json = raw.flatMap { String(validatingCString: $0) } ?? #"{"ok":false,"error":"no result"}"#
        let html = Self.render(json: json, title: url.lastPathComponent)
        let reply = QLPreviewReply(dataOfContentType: .html, contentSize: CGSize(width: 720, height: 540)) { _ in
            Data(html.utf8)
        }
        reply.title = url.lastPathComponent
        return reply
    }

    private static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func tr(_ key: String) -> String {
        NSLocalizedString(key, bundle: .main, comment: "")
    }

    static func render(json: String, title: String) -> String {
        let head = "<html><head><meta charset=utf-8><meta name=color-scheme content=\"light dark\">"
            + "<style>body{font:13px -apple-system;margin:16px}td{padding:2px 12px 2px 0}"
            + ".n{text-align:right;color:gray}.w{color:#b26a00}</style></head><body>"
        let obj = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any]
        guard let obj, obj["ok"] as? Bool == true, let entries = obj["entries"] as? [[String: Any]] else {
            let err = (obj?["error"] as? String) ?? tr("unreadable result")
            return head + "<h3>\(esc(title))</h3><p class=w>\(esc(err))</p></body></html>"
        }
        var rows = ""
        for e in entries {
            let path = e["path"] as? String ?? "?"
            let depth = (e["depth"] as? Int) ?? 1
            let kind = e["kind"] as? String ?? "file"
            let size = (e["size"] as? NSNumber)?.int64Value ?? 0
            let icon = kind == "dir" ? "📁" : (kind == "symlink" ? "🔗" : "📄")
            let indent = String(repeating: "&nbsp;&nbsp;&nbsp;", count: max(0, depth - 1))
            let name = esc((e["name"] as? String) ?? path)
            let bytes = kind == "file" ? ByteCountFormatter.string(fromByteCount: size, countStyle: .file) : ""
            rows += "<tr><td>\(indent)\(icon) \(name)</td><td class=n>\(bytes)</td></tr>"
        }
        let notices = (obj["notices"] as? [String] ?? []).map { "<p class=w>\(esc($0))</p>" }.joined()
        let partial = obj["truncated"] as? Bool == true ? "<p class=w>\(esc(tr("Partial listing")))</p>" : ""
        return head + "<h3>\(esc(title))</h3><table>\(rows)</table>\(partial)\(notices)</body></html>"
    }
}
