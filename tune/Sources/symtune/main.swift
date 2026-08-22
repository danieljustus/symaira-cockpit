// symtune — legacy entrypoint, now a thin wrapper over SymTuneCLI.
// The unified entrypoint is `symcockpit tune <command>`.
import Foundation
import SymTuneCLI

let args = Array(CommandLine.arguments.dropFirst())
let code = SymTuneMain.run(args)
exit(code)
