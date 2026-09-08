// A deterministic Accessibility target for the AX-walk benchmark.
//
// Real applications are moving targets: their trees grow and shrink while a
// benchmark runs, which makes a before/after comparison meaningless. This app
// puts up one window with a fixed, statically-built control hierarchy, so both
// builds under test walk exactly the same tree.
//
// Build and run:
//   swiftc -O scripts/bench-ax-walk/Fixture.swift -o /tmp/ax-bench-fixture
//   /tmp/ax-bench-fixture &
import AppKit

/// Rows per group and groups per window. 12 x 16 x 3 controls plus the group
/// and row containers is a few hundred elements — the same order as a real
/// app window, and above the 200-node default cap of `query_ui`.
let groupCount = 12
let rowsPerGroup = 16

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!

    func applicationDidFinishLaunching(_ notification: Notification) {
        let content = NSStackView()
        content.orientation = .horizontal
        content.spacing = 4

        for group in 0..<groupCount {
            let column = NSStackView()
            column.orientation = .vertical
            column.spacing = 2
            column.setAccessibilityLabel("group-\(group)")

            for row in 0..<rowsPerGroup {
                let line = NSStackView()
                line.orientation = .horizontal
                line.spacing = 2

                let label = NSTextField(labelWithString: "cell-\(group)-\(row)")
                label.setAccessibilityHelp("help-\(group)-\(row)")

                let button = NSButton(title: "act-\(group)-\(row)", target: nil, action: nil)
                button.setAccessibilityIdentifier("button-\(group)-\(row)")

                let field = NSTextField(string: "value-\(group)-\(row)")
                field.isEditable = false

                line.addArrangedSubview(label)
                line.addArrangedSubview(button)
                line.addArrangedSubview(field)
                column.addArrangedSubview(line)
            }
            content.addArrangedSubview(column)
        }

        let scroll = NSScrollView()
        scroll.documentView = content
        // No scrollers: their knob fades in and out, and a control that comes
        // and goes is one more node in some walks and not in others. Content
        // outside the visible rect is still in the Accessibility tree.
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false

        window = NSWindow(
            contentRect: NSRect(x: 60, y: 60, width: 720, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "ax-bench-fixture"
        window.contentView = scroll
        // Stage Manager pulls a backgrounded app's windows out of the space,
        // and an absent window has no Accessibility tree to walk. Floating on
        // every space keeps the fixture measurable while something else has
        // focus, which is exactly the situation a benchmark run creates.
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.makeKeyAndOrderFront(nil)
        print("pid \(ProcessInfo.processInfo.processIdentifier)")
        fflush(stdout)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
