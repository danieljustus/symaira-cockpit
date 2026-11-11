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

let engine = FanHelperEngine { selectionProvider, shouldContinue, sleep in
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

let delegate = FanHelperListenerDelegate(engine: engine)
let listener = NSXPCListener(machServiceName: FanHelperConstants.helperIdentifier)
listener.delegate = delegate

// SIGTERM (launchd stop, unregister, shutdown): restore the fans, then exit.
signal(SIGTERM, SIG_IGN)
let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
termination.setEventHandler {
    if !engine.terminate() {
        // The governor is blocked (e.g. in an SMC call) and did not restore
        // within the grace period; say so in launchd's log before exiting.
        fputs("symaira fan helper: SIGTERM grace expired before the fans were restored\n", stderr)
    }
    exit(0)
}
termination.resume()

listener.resume()
RunLoop.main.run()
