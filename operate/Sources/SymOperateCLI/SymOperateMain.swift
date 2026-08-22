
import Foundation
import SymOperateCore
import SymOperateMCP

enum Command: String {
    case serve
    case doctor
    case permissions
    case version
    case history
    case updates
}

struct GrantResult: Codable {
    let prompted: Bool
}


func printUsage() {
    let usage = """
    symoperate

    Commands:
      serve                          Run the MCP server over stdio.
      doctor                         Print permission status and environment checks (JSON).
      version                        Print version and check for updates.
      history --json                 Print the local operation history in JSON format.
      updates check [--force]        Check for updates and print result (JSON).
      updates skip [<version>]       Show skipped version, or skip a specific version.
      updates clear-skip             Clear the skipped version.
      permissions status             Print the current macOS permissions.
      permissions grant accessibility  Trigger the Accessibility permission prompt.
      permissions grant screen         Trigger the Screen Recording permission prompt.
    """
    FileHandle.standardOutput.write(Data((usage + "\n").utf8))
}

func printJSON<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
    let data = try encoder.encode(value)
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
}

func exitCode(for error: AutomationError) -> ExitCode {
    switch error {
    case .permissionDenied: return .permissionDenied
    case .notFound: return .notFound
    case .invalidArgument: return .invalidArgument
    case .operationFailed: return .operationFailed
    case .staleReference: return .staleReference
    case .unavailable: return .unavailable
    }
}

