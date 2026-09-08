import AppKit

// A spike, not a product: intercept the brightness keys, log what arrives, and
// draw a stand-in HUD. It never changes the actual display brightness.
//
//   --tap hid|session|annotated   where to insert the tap (default: hid)
//   --observe                     do not swallow the event (native HUD stays)
//   --dry-run                     log only, never touch the actual brightness

var tapLocation: CGEventTapLocation = .cghidEventTap
var consume = true
var dryRun = false

var arguments = Array(CommandLine.arguments.dropFirst())
while let argument = arguments.first {
    arguments.removeFirst()
    switch argument {
    case "--observe":
        consume = false
    case "--dry-run":
        dryRun = true
    case "--tap":
        switch arguments.first {
        case "hid": tapLocation = .cghidEventTap
        case "session": tapLocation = .cgSessionEventTap
        case "annotated": tapLocation = .cgAnnotatedSessionEventTap
        default:
            FileHandle.standardError.write(Data("--tap needs hid|session|annotated\n".utf8))
            exit(2)
        }
        arguments.removeFirst()
    case "--help", "-h":
        print("BrightnessHUDProbe [--tap hid|session|annotated] [--observe] [--dry-run]")
        exit(0)
    default:
        FileHandle.standardError.write(Data("unknown argument: \(argument)\n".utf8))
        exit(2)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

Log.write("--- probe start (pid \(ProcessInfo.processInfo.processIdentifier)) ---")
Log.write("log file: \(Log.fileURL.path)")

// Prompts once; the grant is tied to this bundle's code signature, so a rebuild
// with a fresh ad-hoc signature shows up to TCC as a different app.
let prompt = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
let trusted = AXIsProcessTrustedWithOptions(prompt)
Log.write("accessibility: \(trusted ? "granted" : "NOT granted — approve in System Settings, then relaunch")")

let hud = MainActor.assumeIsolated { HUDPanel() }
let tap = MainActor.assumeIsolated {
    BrightnessEventTap(location: tapLocation, consume: consume, dryRun: dryRun, hud: hud)
}

// Do not exit on a missing grant: the TCC dialog is asynchronous, and an app
// that dies immediately takes its own prompt down with it. Poll instead, so the
// tap comes up the moment Accessibility is granted — no relaunch needed.
func installTap(attempt: Int = 1) {
    if tap.start() {
        Log.write("probe: press F1 / F2. Ctrl-C or `killall BrightnessHUDProbe` to stop.")
        return
    }
    if attempt == 1 {
        Log.write("probe: waiting for Accessibility. System Settings > Privacy & Security > Accessibility, add BrightnessHUDProbe.")
    } else if attempt % 15 == 0 {
        Log.write("probe: still waiting for Accessibility (\(attempt * 2)s)")
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { installTap(attempt: attempt + 1) }
}

installTap()
app.run()
