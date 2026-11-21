import FinderSync
import os

// Finder context actions (R72). No domain logic: a click writes one job file into the app
// group's jobs/ directory (JSON with version, id and expiry, written atomically); the app
// validates and runs it. File names only ever travel as JSON strings, never through a shell.
@objc(SymFinderSync)
final class SymFinderSync: FIFinderSync {
    private let log = Logger(subsystem: "com.symaira.cockpit.findersync", category: "jobs")

    /// Action ids must match `ALLOWED_ACTIONS` in `symcockpit-core` (checked by a Rust test).
    private static let actions: [(id: String, title: String)] = [
        ("copy_path", "Copy Path"),
        ("new_file", "New File Here"),
        ("open_in_terminal", "Open in Terminal"),
    ]
    private static let jobVersion = 1
    private static let lifetime: TimeInterval = 60

    override init() {
        super.init()
        // Without watched folders Finder shows no context menu; "/" covers every volume.
        FIFinderSyncController.default().directoryURLs = [URL(fileURLWithPath: "/")]
    }

    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        guard menuKind == .contextualMenuForItems || menuKind == .contextualMenuForContainer else { return nil }
        let menu = NSMenu(title: "")
        for (index, action) in Self.actions.enumerated() {
            let item = menu.addItem(
                withTitle: NSLocalizedString(action.title, bundle: .main, comment: ""),
                action: #selector(runAction(_:)), keyEquivalent: "")
            item.tag = index
        }
        return menu
    }

    @objc func runAction(_ sender: NSMenuItem) {
        guard Self.actions.indices.contains(sender.tag) else { return }
        let controller = FIFinderSyncController.default()
        var paths = (controller.selectedItemURLs() ?? []).map(\.path)
        if paths.isEmpty, let target = controller.targetedURL() { paths = [target.path] }
        guard !paths.isEmpty, let dir = Self.jobsDirectory() else {
            log.error("no selection or no app group container")
            return
        }
        let id = UUID().uuidString.lowercased()
        let now = Int(Date().timeIntervalSince1970)
        let job: [String: Any] = [
            "version": Self.jobVersion, "id": id, "action": Self.actions[sender.tag].id, "paths": paths,
            "created_at": now, "expires_at": now + Int(Self.lifetime),
        ]
        do {
            let data = try JSONSerialization.data(withJSONObject: job, options: [.sortedKeys])
            try data.write(to: dir.appendingPathComponent("\(id).json"), options: .atomic)
        } catch {
            log.error("job write failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func jobsDirectory() -> URL? {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "SymCockpitAppGroup") as? String, !group.isEmpty,
            let base = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)
        else { return nil }
        let dir = base.appendingPathComponent("jobs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
