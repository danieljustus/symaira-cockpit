import Dispatch
import Foundation
import SymCockpitCore
import SymCockpitHelperKit

// Privileged fan helper (issue #405). Started by launchd as root through the
// app's SMAppService registration; speaks XPC on the grandfathered Mach
// service `com.symaira.symtune-helper`.
//
// This file stays deliberately thin and stable: everything with logic lives
// in SymCockpitHelperKit / SymCockpitCore, where it is unit-tested. The daemon
// never uses stdout; diagnostics go to stderr (launchd's log).
//
// Two read-only introspection modes exist for the release workflow, which
// must verify the signed bundle against exactly the requirement strings the
// code enforces (they do nothing else and never touch XPC or the SMC):
//   --print-embedded-team                       the team baked in at build time
//   --print-requirement <app|helper> <TEAM>     the XPC requirement for TEAM

setvbuf(stderr, nil, _IOLBF, 0)

let arguments = CommandLine.arguments
if arguments.count >= 2, arguments[1] == "--print-embedded-team" {
    print(EmbeddedTeamIdentifier.value ?? "")
    exit(EmbeddedTeamIdentifier.value == nil ? 1 : 0)
}
if arguments.count == 4, arguments[1] == "--print-requirement" {
    let requirement = arguments[2] == "app"
        ? CodeSigningRequirements.appRequirement(teamID: arguments[3])
        : arguments[2] == "helper"
            ? CodeSigningRequirements.helperRequirement(teamID: arguments[3])
            : nil
    guard let requirement else {
        fputs("usage: --print-requirement <app|helper> <TEAMID>\n", stderr)
        exit(2)
    }
    print(requirement)
    exit(0)
}

// A fresh helper governs nothing, so fans still forced at launch were left by
// a predecessor that died mid-run (issue #414). The same recovery runs when
// the app asks for Standard while no run is active.
let staleRecovery: @Sendable () -> Void = {
    let smc = SMCService()
    let fanControl = FanControlService(smc: smc, sensors: SensorService(smc: smc))
    let outcome = FanStaleOverrideRecovery.run(
        hasOverride: { fanControl.hasSoftwareOverride() },
        legacyGovernorRunning: { FanGovernorProcessProbe.isRunning() },
        restore: { try fanControl.restoreAuto() }
    )
    if outcome != .nothingForced {
        FileHandle.standardError.write(Data("symaira fan helper: stale fan override: \(outcome)\n".utf8))
    }
}

let engine = FanHelperEngine(staleRecovery: staleRecovery) { selectionProvider, shouldContinue, sleep in
    let smc = SMCService()
    let sensors = SensorService(smc: smc)
    let fanControl = FanControlService(smc: smc, sensors: sensors)
    // The existing governor, unchanged: SafetyPolicy clamps, thermal-headroom
    // gate and the bounded failure policy all apply exactly as in the CLI.
    let governor = FanGovernor(
        fanControl: fanControl, sensors: sensors, config: TuneConfig(), sleep: sleep
    )
    try governor.run(selectionProvider: selectionProvider, shouldContinue: shouldContinue)
}
engine.startWatchdogTimer()
engine.recoverStaleOverride()

let delegate = FanHelperListenerDelegate(engine: engine)
let listener = NSXPCListener(machServiceName: FanHelperConstants.helperIdentifier)
listener.delegate = delegate

// SIGTERM (launchd stop, unregister, shutdown): restore the fans, then exit.
// Unchanged by the idle exit below.
// Both dispatch sources below run on the main queue: top-level code here is
// main-actor isolated under Swift 6, so their handlers are too, and a handler
// on any other queue trips the runtime isolation check (SIGTRAP). The idle
// timer on a private queue crashed the helper a second after every start,
// mid-governing, leaving the fans forced. `RunLoop.main.run()` drains the
// main queue, and blocking it during termination costs nothing: XPC requests
// arrive on their own queues and the process exits right after.
signal(SIGTERM, SIG_IGN)
let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
termination.setEventHandler {
    if !engine.terminate() {
        // The governor is blocked (e.g. in an SMC call) and did not restore
        // within the grace period; say so in launchd's log before exiting.
        fputs("symaira fan helper: SIGTERM grace expired before the fans were restored\n", stderr)
    }
    exit(0)
}
termination.resume()

// Idle exit: with no client and no governor (the fans are already restored by
// then) the helper leaves after a short grace. launchd starts the current
// binary on the next Mach lookup, so an app upgrade swaps the helper without
// a reboot. Never exits while governing or while a client is connected.
let idleMonitor = FanHelperIdleMonitor(
    isGoverning: { engine.snapshot.isGoverning },
    hasConnection: { delegate.hasActiveConnection }
)
let idleTimer = DispatchSource.makeTimerSource(queue: .main)
idleTimer.schedule(
    deadline: .now() + FanHelperConstants.idleCheckInterval,
    repeating: FanHelperConstants.idleCheckInterval
)
idleTimer.setEventHandler {
    if idleMonitor.tick() {
        fputs("symaira fan helper: idle, exiting (launchd restarts it on demand)\n", stderr)
        exit(0)
    }
}
idleTimer.resume()

listener.resume()
RunLoop.main.run()
