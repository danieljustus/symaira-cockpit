// symtune — legacy entrypoint, now a thin wrapper over SymCockpitCLI.
// The unified entrypoint is `symcockpit <command>`.
import Foundation
import SymCockpitCLI

let args = Array(CommandLine.arguments.dropFirst())
let code = SymCockpitMain.run(args)
exit(code)
