// Times one Accessibility tree walk against a running application.
//
//   probe <pid> <maxDepth> <maxNodes> <iterations> <label>
//
// Prints one tab-separated sample per line:
//   kind  label  pid  maxDepth  maxNodes  nodeCount  milliseconds
//
// With the label `dump` it prints the walked tree as JSON instead of timings,
// so two builds can be compared for identical output before their speeds are
// compared. Node ids are fresh UUIDs on every walk and are stripped.
import AppKit
import ApplicationServices
import Foundation
import SymOperateCore

let arguments = CommandLine.arguments
guard arguments.count > 1, let pid = pid_t(arguments[1]) else {
    FileHandle.standardError.write(
        "usage: probe <pid> [maxDepth] [maxNodes] [iterations] [label]\n".data(using: .utf8)!
    )
    exit(2)
}
let maxDepth = arguments.count > 2 ? Int(arguments[2]) ?? 4 : 4
let maxNodes = arguments.count > 3 ? Int(arguments[3]) ?? 200 : 200
let iterations = arguments.count > 4 ? Int(arguments[4]) ?? 15 : 15
let label = arguments.count > 5 ? arguments[5] : "run"

func milliseconds(_ body: () -> Void) -> Double {
    let start = DispatchTime.now().uptimeNanoseconds
    body()
    return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
}

func nodeCount(_ nodes: [UINode]) -> Int {
    var total = 0
    var stack = nodes
    while let node = stack.popLast() {
        total += 1
        stack.append(contentsOf: node.children)
    }
    return total
}

// Take the target window's frame from Accessibility rather than from
// CGWindowList: with Stage Manager on, a backgrounded app's CGWindow bounds
// describe its shrunken strip thumbnail, and the production frame match would
// never hit. The walk being measured is the same either way.
let axApp = AXUIElementCreateApplication(pid)
var windowsValue: CFTypeRef?
AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsValue)
guard let axWindow = (windowsValue as? [AXUIElement])?.first else {
    FileHandle.standardError.write("no Accessibility window for pid \(pid)\n".data(using: .utf8)!)
    exit(1)
}
var positionValue: CFTypeRef?
var sizeValue: CFTypeRef?
AXUIElementCopyAttributeValue(axWindow, kAXPositionAttribute as CFString, &positionValue)
AXUIElementCopyAttributeValue(axWindow, kAXSizeAttribute as CFString, &sizeValue)
var origin = CGPoint.zero
var extent = CGSize.zero
if let positionValue { AXValueGetValue(positionValue as! AXValue, .cgPoint, &origin) }
if let sizeValue { AXValueGetValue(sizeValue as! AXValue, .cgSize, &extent) }
let bounds = RectValue(x: origin.x, y: origin.y, width: extent.width, height: extent.height)

let accessibility = AccessibilityService()

@MainActor func walk() -> [UINode] {
    (try? accessibility.queryUI(
        snapshotID: UUID().uuidString,
        processID: pid,
        windowID: 0,
        windowBounds: bounds,
        maxDepth: maxDepth,
        maxNodes: maxNodes
    )) ?? []
}

@MainActor func run() {
    if label == "dump" {
        // One discarded walk first: a window that has only just come up settles
        // for a moment, and the point of the dump is to compare two builds, not
        // two instants.
        _ = walk()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let json = String(data: try! encoder.encode(walk()), encoding: .utf8)!
        print(json.split(separator: "\n").filter { !$0.contains("\"id\" :") }.joined(separator: "\n"))
        return
    }

    // Warm-up walks are not measured: the first call into a target application
    // pays connection setup that no later call repeats.
    var nodes = 0
    for _ in 0..<3 { nodes = nodeCount(walk()) }

    for _ in 0..<iterations {
        let elapsed = milliseconds { _ = walk() }
        print("walk\t\(label)\t\(pid)\t\(maxDepth)\t\(maxNodes)\t\(nodes)\t\(String(format: "%.4f", elapsed))")
    }

    // The text search walks the same tree through a different reader. A needle
    // that cannot match forces the full traversal every time.
    for _ in 0..<3 { _ = accessibility.containsText("zzz-absent-zzz", processID: pid) }
    for _ in 0..<iterations {
        let elapsed = milliseconds { _ = accessibility.containsText("zzz-absent-zzz", processID: pid) }
        print("search\t\(label)\t\(pid)\t-\t300\t-\t\(String(format: "%.4f", elapsed))")
    }
}

MainActor.assumeIsolated { run() }
