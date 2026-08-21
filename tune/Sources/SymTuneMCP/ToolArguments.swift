import Foundation
import SymTuneCore
import SymairaMCP

/// Extract a required `Double` from MCP tool arguments.
func requireDouble(_ value: MCPJSONValue?, name: String) throws -> Double {
    if let number = value?.doubleValue { return number }
    if let string = value?.stringValue, let double = Double(string) { return double }
    throw TuneError.usage("Missing required numeric argument '\(name)'.")
}

/// Extract a required `Int` from MCP tool arguments.
func requireInt(_ value: MCPJSONValue?, name: String) throws -> Int {
    if let number = value?.intValue { return Int(number) }
    if let string = value?.stringValue, let int = Int(string) { return int }
    throw TuneError.usage("Missing required integer argument '\(name)'.")
}
