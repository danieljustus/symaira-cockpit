import Dispatch
import Foundation
import SymCockpitCore
import SymCockpitHelperKit

// Privileged fan helper (issue #405). Started by launchd as root through the
// app's SMAppService registration; speaks XPC on the grandfathered Mach
// service `com.symaira.symtune-helper`.
//
// This file stays deliberately thin and stable: everything with logic lives
// in SymCockpitHelperKit / SymCockpitCore, where it is unit-tested. stdout is
// never used; diagnostics go to stderr (launchd's log).

setvbuf(stderr, nil, _IOLBF, 0)

let engine = FanHelperEngine { profileProvider, shouldContinue, sleep in
    let smc = SMCService()
    let sensors = SensorService(smc: smc)
    let fanControl = FanControlService(smc: smc, sensors: sensors)
    // The existing governor, unchanged: SafetyPolicy clamps, thermal-headroom
    // gate and the bounded failure policy all apply exactly as in the CLI.
    let governor = FanGovernor(
        fanControl: fanControl, sensors: sensors, config: TuneConfig(), sleep: sleep
    )
    try governor.run(profileProvider: profileProvider, shouldContinue: shouldContinue)
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
