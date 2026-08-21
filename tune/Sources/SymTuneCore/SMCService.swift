import Foundation
import IOKit

// MARK: - SMC Key Encoding

/// Encode a 4-character SMC key as a big-endian UInt32.
func smcEncodeKey(_ key: String) -> UInt32 {
    let utf8 = Array(key.utf8)
    guard utf8.count == 4 else { return 0 }
    return UInt32(utf8[0]) << 24 | UInt32(utf8[1]) << 16
         | UInt32(utf8[2]) << 8 | UInt32(utf8[3])
}

/// Decode a UInt32 SMC key back to a 4-character string.
func smcDecodeKey(_ value: UInt32) -> String {
    let b0 = UInt8((value >> 24) & 0xFF)
    let b1 = UInt8((value >> 16) & 0xFF)
    let b2 = UInt8((value >> 8) & 0xFF)
    let b3 = UInt8(value & 0xFF)
    return String(bytes: [b0, b1, b2, b3], encoding: .ascii) ?? "????"
}

// MARK: - SMC Value Conversion

/// Convert raw SMC bytes to a Double based on the data type.
func smcConvertValue(dataType: UInt32, bytes: [UInt8]) -> Double {
    let typeStr = smcDecodeKey(dataType)

    switch typeStr {
    case "fpe2":
        // Float with exponent bias 2 — standard for temperature sensors.
        // High byte = integer part, low byte = fractional part (1/256).
        guard bytes.count >= 2 else { return 0 }
        let raw = UInt16(bytes[0]) << 8 | UInt16(bytes[1])
        return Double(raw) / 256.0

    case "flt ":
        // IEEE 754 float (4 bytes, big-endian).
        guard bytes.count >= 4 else { return 0 }
        let raw: UInt32 = UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16
                        | UInt32(bytes[2]) << 8 | UInt32(bytes[3])
        return Double(Float(bitPattern: raw))

    case "sp78":
        // Signed fixed-point 7.8 (2 bytes, big-endian).
        guard bytes.count >= 2 else { return 0 }
        let raw = Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1]))
        return Double(raw) / 256.0

    case "ui8 ":
        guard bytes.count >= 1 else { return 0 }
        return Double(bytes[0])

    case "ui16":
        guard bytes.count >= 2 else { return 0 }
        return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1]))

    case "ui32":
        guard bytes.count >= 4 else { return 0 }
        let raw: UInt32 = UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16
                        | UInt32(bytes[2]) << 8 | UInt32(bytes[3])
        return Double(raw)

    default:
        // Unknown type: interpret as a big-endian unsigned integer.
        guard !bytes.isEmpty else { return 0 }
        var raw: UInt64 = 0
        for b in bytes { raw = (raw << 8) | UInt64(b) }
        return Double(raw)
    }
}

// MARK: - SMC Parameter Block

/// Raw 80-byte buffer matching the C `SMCParamStruct` layout used by the
/// AppleSMC IOKit driver. Fields are accessed via byte offsets derived from
/// the canonical C struct:
///
/// ```
/// offset  0: key            (UInt32)
/// offset  4: vers           (8 bytes — 4×UInt8 + UInt16 + UInt16)
/// offset 12: pLimitData     (16 bytes — 2×UInt16 + 3×UInt32, padded for alignment)
/// offset 28: keyInfo        (12 bytes — 2×UInt32 + UInt8 + 3 pad)
/// offset 40: result         (UInt8)
/// offset 41: status         (UInt8)
/// offset 42: data8          (UInt8)
/// offset 43: _pad           (1 byte)
/// offset 44: data32         (UInt32)
/// offset 48: bytes[32]      (32 bytes)
/// ```
struct SMCParamBlock: @unchecked Sendable {
    static let byteCount = 80

    var data: [UInt8]

    init() { data = [UInt8](repeating: 0, count: Self.byteCount) }

    // MARK: Key (bytes 0-3)

    var key: UInt32 {
        get { data.loadBE32(at: 0) }
        set { data.storeBE32(newValue, at: 0) }
    }

    // MARK: KeyInfo (bytes 28-39)

    var keyInfoDataSize: UInt32 {
        get { data.loadBE32(at: 28) }
        set { data.storeBE32(newValue, at: 28) }
    }

    var keyInfoDataType: UInt32 {
        get { data.loadBE32(at: 32) }
        set { data.storeBE32(newValue, at: 32) }
    }

    var keyInfoDataAttributes: UInt8 {
        get { data[36] }
        set { data[36] = newValue }
    }

    /// Copy the 12-byte keyInfo block (bytes 28-39) from another param block.
    mutating func copyKeyInfo(from other: SMCParamBlock) {
        for i in 28..<40 { data[i] = other.data[i] }
    }

    // MARK: Result / Status / data8 (bytes 40-42)

    var result: UInt8 { data[40] }
    var status: UInt8 { data[41] }

    var data8: UInt8 {
        get { data[42] }
        set { data[42] = newValue }
    }

    // MARK: data32 (bytes 44-47)

    var data32: UInt32 {
        get { data.loadBE32(at: 44) }
        set { data.storeBE32(newValue, at: 44) }
    }

    // MARK: Data bytes (bytes 48-79)

    /// Return the first `count` data bytes (max 32).
    func dataBytes(_ count: Int) -> [UInt8] {
        let n = min(Int(count), 32)
        guard n > 0 else { return [] }
        return Array(data[48 ..< 48 + n])
    }
}

// MARK: - UInt8 Array BE Helpers

private extension Array where Element == UInt8 {
    func loadBE32(at offset: Int) -> UInt32 {
        UInt32(self[offset]) << 24 | UInt32(self[offset + 1]) << 16
        | UInt32(self[offset + 2]) << 8 | UInt32(self[offset + 3])
    }

    mutating func storeBE32(_ value: UInt32, at offset: Int) {
        self[offset]     = UInt8((value >> 24) & 0xFF)
        self[offset + 1] = UInt8((value >> 16) & 0xFF)
        self[offset + 2] = UInt8((value >> 8) & 0xFF)
        self[offset + 3] = UInt8(value & 0xFF)
    }
}

// MARK: - SMC Connection Protocol

/// Abstraction over the AppleSMC IOKit connection so `SMCService` can be
/// unit-tested without real hardware.
public protocol SMCConnectionProtocol: Sendable {
    var isOpen: Bool { get }

    /// Read a key's data type and raw bytes, or nil if the key does not exist or the read fails.
    func readKeyRaw(_ key: String) -> (dataType: UInt32, bytes: [UInt8])?

    /// Write raw bytes to a key. Returns true on success.
    func writeKeyRaw(_ key: String, dataType: UInt32, bytes: [UInt8]) -> Bool

    /// Enumerate the SMC keys this host actually exposes via the `#KEY`
    /// index selector (`kSMCGetKeyFromIndex`), or nil when index-based
    /// enumeration is unavailable. Callers must treat nil honestly — the
    /// temperature report falls back to the built-in candidate table and
    /// says so instead of assuming enumeration succeeded.
    func enumerateKeys() -> [String]?
}

extension SMCConnectionProtocol {
    /// Default: enumeration is unavailable. Only connections that implement
    /// the index probe override this.
    public func enumerateKeys() -> [String]? { nil }
}

// MARK: - Raw IOKit Call

/// Perform a single `IOConnectCallStructMethod` call on the SMC driver.
/// Selector 2 (`kSMCHandleYPCCommand`) is the standard command dispatch.
private func smcRawCall(
    handle: io_connect_t,
    input: inout SMCParamBlock,
    output: inout SMCParamBlock
) -> Bool {
    guard handle != IO_OBJECT_NULL else { return false }

    var outSize = SMCParamBlock.byteCount

    let kr = input.data.withUnsafeMutableBufferPointer { inBuf in
        output.data.withUnsafeMutableBufferPointer { outBuf in
            IOConnectCallStructMethod(
                handle,
                2, // kSMCHandleYPCCommand
                inBuf.baseAddress,
                SMCParamBlock.byteCount,
                outBuf.baseAddress,
                &outSize
            )
        }
    }

    return kr == kIOReturnSuccess
}

// MARK: - Hardware SMC Connection

/// Reference-type wrapper for the IOKit `io_connect_t` handle.
/// Prevents accidental double-close when `SMCService` (a struct) is copied.
/// The connection is opened eagerly in `init` so that `handle` is set once
/// and never mutated afterward, fulfilling the `@unchecked Sendable` contract.
public final class HardwareSMCConnection: SMCConnectionProtocol, @unchecked Sendable {
    private static let taskPort: mach_port_t = mach_task_self_
    public let handle: io_connect_t
    public let isOpen: Bool

    /// Cached `READ_KEYINFO` results. A key's type and size are fixed by the
    /// SMC firmware, so the info round-trip only has to happen once per key.
    /// A cached `nil` records a key this Mac does not implement — repeat reads
    /// of it then cost no IOKit call at all instead of one per poll.
    private var keyInfoCache: [String: SMCParamBlock?] = [:]
    private let keyInfoLock = NSLock()

    /// One raw param-block round-trip. Production instances wrap
    /// `smcRawCall(handle:)`; the internal test seam injects a closure so the
    /// keyInfo/read/write logic can be exercised without IOKit hardware.
    private let perform: (inout SMCParamBlock, inout SMCParamBlock) -> Bool

    /// Outcome of the index-based key enumeration, cached after the first
    /// probe so repeated `readTemperatures()` polls cost nothing.
    private enum KeyEnumerationResult: Sendable {
        case unavailable
        case keys([String])
    }

    private var enumerationResult: KeyEnumerationResult?
    private let enumerationLock = NSLock()

    /// Selector for the AppleSMC index-based key lookup: the requested index
    /// goes in `data32`, the 4-character key code comes back in `key`.
    /// (SMCKit documents this as `kSMCGetKeyFromIndex = 8`.)
    private static let getKeyFromIndexSelector: UInt8 = 8

    /// Sanity cap for the `#KEY` count — no shipping Mac exposes more.
    private static let maxEnumerationKeys = 4096

    /// The key the open-probe asks for. `#KEY` reports the total number of SMC
    /// keys and exists on every Mac that implements the SMC at all — unlike
    /// `FNum`, which a fanless Mac may legitimately not implement. Using it
    /// keeps "fanless" and "SMC unreachable" apart.
    static let probeKey = "#KEY"

    /// Decide whether the SMC actually answers us, given a way to perform one
    /// raw param-block round-trip.
    ///
    /// A successful `IOConnectCallStructMethod` only means the *transport*
    /// worked; the SMC firmware reports its own verdict in `result`. On macOS
    /// builds that no longer grant third-party processes access to the raw
    /// AppleSMC user client, the transport call succeeds while every key comes
    /// back `kSMCKeyNotFound` (132) — so a transport-only check reports
    /// "connected" for a connection through which nothing can ever be read.
    static func probeIndicatesOpen(
        perform: (inout SMCParamBlock, inout SMCParamBlock) -> Bool
    ) -> Bool {
        var probe = SMCParamBlock()
        probe.key = smcEncodeKey(probeKey)
        probe.data8 = 9 // kSMCReadKeyInfo

        var out = SMCParamBlock()
        return perform(&probe, &out) && out.result == 0
    }

    public init() {
        var openedHandle: io_connect_t = IO_OBJECT_NULL
        var opened = false

        let service = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("AppleSMC")
        )
        if service != IO_OBJECT_NULL {
            defer { IOObjectRelease(service) }
            let kr = IOServiceOpen(service, Self.taskPort, 0, &openedHandle)
            if kr == kIOReturnSuccess {
                let handle = openedHandle
                opened = Self.probeIndicatesOpen { input, output in
                    smcRawCall(handle: handle, input: &input, output: &output)
                }
                if !opened {
                    IOServiceClose(openedHandle)
                    openedHandle = IO_OBJECT_NULL
                }
            }
        }

        self.handle = openedHandle
        self.isOpen = opened

        let finalHandle = openedHandle
        self.perform = { input, output in
            smcRawCall(handle: finalHandle, input: &input, output: &output)
        }
    }

    /// Test seam: wrap an arbitrary perform closure so the transport logic
    /// (keyInfo caching, READ_KEY/WRITE_KEY dispatch, result validation) can
    /// be unit-tested without an IOKit connection. Not used in production.
    init(isOpen: Bool, perform: @escaping (inout SMCParamBlock, inout SMCParamBlock) -> Bool) {
        self.handle = IO_OBJECT_NULL
        self.isOpen = isOpen
        self.perform = perform
    }

    deinit {
        if handle != IO_OBJECT_NULL {
            IOServiceClose(handle)
        }
    }

    /// Fetch a key's `READ_KEYINFO` block, using the cache when possible.
    /// Returns `nil` for keys this Mac does not implement.
    private func keyInfo(for key: String) -> SMCParamBlock? {
        keyInfoLock.lock()
        if let cached = keyInfoCache[key] {
            keyInfoLock.unlock()
            return cached
        }
        keyInfoLock.unlock()

        var input = SMCParamBlock()
        input.key = smcEncodeKey(key)
        input.data8 = 9 // kSMCReadKeyInfo

        var output = SMCParamBlock()
        let ok = perform(&input, &output)
            && output.result == 0
            && output.keyInfoDataSize > 0
            && output.keyInfoDataSize <= 32
        let resolved: SMCParamBlock? = ok ? output : nil

        keyInfoLock.lock()
        keyInfoCache[key] = resolved
        keyInfoLock.unlock()
        return resolved
    }

    public func readKeyRaw(_ key: String) -> (dataType: UInt32, bytes: [UInt8])? {
        guard isOpen, let info = keyInfo(for: key) else { return nil }

        let dataSize = info.keyInfoDataSize
        let dataType = info.keyInfoDataType

        // READ_KEY — fetch the actual value. The keyInfo round-trip that used
        // to precede this on every call is served from the cache.
        var in2 = SMCParamBlock()
        in2.key = smcEncodeKey(key)
        in2.data8 = 5 // kSMCReadKey
        in2.copyKeyInfo(from: info)

        var out2 = SMCParamBlock()
        guard perform(&in2, &out2),
              out2.result == 0
        else { return nil }

        return (dataType, out2.dataBytes(Int(dataSize)))
    }

    // MARK: - Key Enumeration

    /// Enumerate the SMC keys this host actually exposes.
    ///
    /// The `#KEY` key reports the key count; each key is then looked up by
    /// index through the `kSMCGetKeyFromIndex` selector (index in `data32`,
    /// key code returned in `key`). Returns nil — never an empty array —
    /// when the connection is closed, the count cannot be read, or the
    /// firmware rejects the index probe. macOS builds that restrict the raw
    /// AppleSMC user client reject every key, so callers must not assume
    /// enumeration succeeded.
    public func enumerateKeys() -> [String]? {
        guard isOpen else { return nil }

        enumerationLock.lock()
        if let cached = enumerationResult {
            enumerationLock.unlock()
            if case .keys(let keys) = cached { return keys }
            return nil
        }
        enumerationLock.unlock()

        // #KEY reports the total key count: a ui32 big-endian value on Apple
        // Silicon, an ASCII decimal string on some Intel firmware. Accept
        // both encodings.
        guard let (_, countBytes) = readKeyRaw(Self.probeKey), !countBytes.isEmpty else {
            cacheEnumeration(.unavailable)
            return nil
        }
        let count = Self.parseKeyCount(countBytes)
        guard count > 0 else {
            cacheEnumeration(.unavailable)
            return nil
        }

        var keys: [String] = []
        for index in 0..<min(count, Self.maxEnumerationKeys) {
            var input = SMCParamBlock()
            input.data8 = Self.getKeyFromIndexSelector
            input.data32 = UInt32(index)

            var output = SMCParamBlock()
            guard perform(&input, &output) else {
                cacheEnumeration(.unavailable)
                return nil
            }
            // kSMCKeyNotFound (132) — index past the end of the key table.
            if output.result != 0 { break }

            let key = smcDecodeKey(output.key)
            // Firmwares that do not implement the index selector return empty
            // or non-printable key codes; treat that as the end of the table.
            guard Self.isPrintableKeyCode(key) else { break }
            keys.append(key)
        }

        guard !keys.isEmpty else {
            cacheEnumeration(.unavailable)
            return nil
        }
        cacheEnumeration(.keys(keys))
        return keys
    }

    private func cacheEnumeration(_ result: KeyEnumerationResult) {
        enumerationLock.lock()
        enumerationResult = result
        enumerationLock.unlock()
    }

    /// Parse the `#KEY` payload: big-endian integer, or ASCII decimal string.
    private static func parseKeyCount(_ bytes: [UInt8]) -> Int {
        if bytes.count == 4, bytes.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) {
            return Int(String(bytes: bytes, encoding: .ascii) ?? "") ?? 0
        }
        var value: UInt64 = 0
        for byte in bytes { value = (value << 8) | UInt64(byte) }
        return Int(value)
    }

    /// A valid SMC key code is exactly 4 printable ASCII characters.
    private static func isPrintableKeyCode(_ key: String) -> Bool {
        let utf8 = Array(key.utf8)
        return utf8.count == 4 && utf8.allSatisfy { $0 >= 0x21 && $0 <= 0x7E }
    }

    public func writeKeyRaw(_ key: String, dataType: UInt32, bytes: [UInt8]) -> Bool {
        guard isOpen, bytes.count <= 32, let out1 = keyInfo(for: key) else { return false }

        let dataSize = out1.keyInfoDataSize

        // Step 2: WRITE_KEY — write the value with keyInfo populated.
        var in2 = SMCParamBlock()
        in2.key = smcEncodeKey(key)
        in2.data8 = 6  // kSMCWriteKey
        in2.copyKeyInfo(from: out1)
        in2.data32 = dataSize

        for i in 0..<min(Int(dataSize), bytes.count) {
            in2.data[48 + i] = bytes[i]
        }

        var out2 = SMCParamBlock()
        guard perform(&in2, &out2),
              out2.result == 0
        else { return false }

        return true
    }
}

// MARK: - SMCService

/// Bridge to the System Management Controller (SMC) for temperature/fan sensors
/// and (when running with sufficient privileges) fan/charge-limit writes.
///
/// Reads are unprivileged (user type 0). Writes require root/SMC privileges;
/// without them the driver returns an error that the caller surfaces as a
/// permission failure. The controller is responsible for safety clamps,
/// restore-on-exit, and never disabling firmware thermal protection.
///
/// Handles Apple Silicon vs Intel key differences automatically. Fanless Macs
/// are supported: `FNum` returning 0 produces an empty fans array.
public struct SMCService: Sendable {
    private let connection: any SMCConnectionProtocol

    /// Test seam: pin the chip generation instead of detecting it from the
    /// host, so generation-specific behavior is deterministic in tests.
    /// Production callers leave it nil.
    private let fixedGeneration: ChipGeneration?

    public init(
        connection: any SMCConnectionProtocol = HardwareSMCConnection(),
        generation: ChipGeneration? = nil
    ) {
        self.connection = connection
        self.fixedGeneration = generation
    }

    /// Whether the SMC bridge successfully connected to the AppleSMC driver.
    public var isAvailable: Bool { connection.isOpen }

    // MARK: - Capability Reporting

    /// The detected Apple Silicon chip generation (`.unknown` on Intel or
    /// when detection fails). Drives the candidate temperature table.
    public var chipGeneration: ChipGeneration {
        Self.detectChipGeneration()
    }

    /// Whether the host allowed index-based SMC key enumeration. False on
    /// closed connections and on macOS builds that reject the index probe —
    /// callers must surface this instead of silently assuming enumeration.
    public var keyEnumerationAvailable: Bool {
        guard connection.isOpen else { return false }
        return connection.enumerateKeys() != nil
    }

    /// The SMC keys this host actually exposes, or nil when index-based
    /// enumeration is unavailable.
    public func enumerateKeys() -> [String]? {
        guard connection.isOpen else { return nil }
        return connection.enumerateKeys()
    }

    // MARK: - Key Reading

    public func readKeyValue(_ key: String) -> Double? {
        guard let (dataType, bytes) = connection.readKeyRaw(key) else { return nil }
        return smcConvertValue(dataType: dataType, bytes: bytes)
    }

    /// Read an SMC key as an unsigned integer (for `ui8 `, `ui16`, `ui32`).
    public func readKeyUInt(_ key: String) -> UInt? {
        guard let (_, bytes) = connection.readKeyRaw(key), !bytes.isEmpty else { return nil }
        var result: UInt = 0
        for b in bytes { result = (result << 8) | UInt(b) }
        return result
    }

    /// Read a `ui32` SMC key, returning the full 32-bit value.
    public func readKeyUInt32(_ key: String) -> UInt32? {
        guard let (dataType, bytes) = connection.readKeyRaw(key) else { return nil }
        guard smcDecodeKey(dataType) == "ui32", bytes.count >= 4 else { return nil }
        return UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16
             | UInt32(bytes[2]) << 8 | UInt32(bytes[3])
    }

    // MARK: - System Power (DC-in rail)

    /// Read live power draw from the DC-in rail: `VD0R` (volts), `ID0R`
    /// (amps) and `PDTR` (watts). Strictly read-only — no SMC writes, no
    /// elevated privileges, no `SafetyPolicy` surface.
    ///
    /// Returns nil when the connection is closed or when none of the three
    /// keys is readable (many Macs do not expose the DC-in keys), so callers
    /// can report honest unavailability instead of zeros. Values are reported
    /// as read; `PDTR` is the direct wattage read, not a V×A derivation.
    public func readSystemPower() -> PowerReport? {
        guard connection.isOpen else { return nil }
        let volts = readKeyValue("VD0R")
        let amps = readKeyValue("ID0R")
        let watts = readKeyValue("PDTR")
        guard volts != nil || amps != nil || watts != nil else { return nil }
        return PowerReport(volts: volts, amps: amps, watts: watts)
    }

    // MARK: - Key Writing (privileged, used by helper IPC)

    /// Write a raw value to an SMC key. Requires root/SMC connection privileges.
    /// Used by the privileged Pro helper for fan/charge control.
    public func writeKeyRaw(_ key: String, dataType: UInt32, bytes: [UInt8]) -> Bool {
        connection.writeKeyRaw(key, dataType: dataType, bytes: bytes)
    }

    /// Write a value to an SMC key, encoding as the specified data type.
    /// Supported types: `fpe2` (Intel temperature/fan), `flt ` (Apple Silicon
    /// fan RPM), `ui8 `, `ui16`, `ui32`.
    public func writeKeyValue(_ key: String, value: Double, dataType: String = "fpe2") -> Bool {
        let typeUInt = smcEncodeKey(dataType)
        let bytes: [UInt8]
        switch dataType {
        case "fpe2":
            let raw = UInt16((value * 256.0).rounded())
            bytes = [UInt8((raw >> 8) & 0xFF), UInt8(raw & 0xFF)]
        case "flt ":
            let raw = Float(value).bitPattern
            bytes = [
                UInt8((raw >> 24) & 0xFF),
                UInt8((raw >> 16) & 0xFF),
                UInt8((raw >> 8) & 0xFF),
                UInt8(raw & 0xFF)
            ]
        case "ui8 ":
            bytes = [UInt8(min(max(value, 0), 255))]
        case "ui16":
            let raw = UInt16(min(max(value, 0), 65535))
            bytes = [UInt8((raw >> 8) & 0xFF), UInt8(raw & 0xFF)]
        case "ui32":
            let raw = UInt32(min(max(value, 0), 4294967295))
            bytes = [
                UInt8((raw >> 24) & 0xFF),
                UInt8((raw >> 16) & 0xFF),
                UInt8((raw >> 8) & 0xFF),
                UInt8(raw & 0xFF)
            ]
        default:
            return false
        }
        return writeKeyRaw(key, dataType: typeUInt, bytes: bytes)
    }

    // MARK: - Temperature Sensors

    public func readTemperatures() -> [SensorReading] {
        guard connection.isOpen else { return [] }

        #if arch(arm64)
        let keys = Self.appleSiliconTemperatureKeys(
            for: fixedGeneration ?? Self.detectChipGeneration()
        )
        #else
        let keys = Self.intelTempKeys
        #endif

        // Reported temperatures = intersection of the candidate table and the
        // keys the host actually exposes. Absent keys are omitted — never
        // reported as zero or unknown. When index-based enumeration is
        // unavailable (some macOS builds restrict the AppleSMC user client),
        // the candidate table is used as-is; SensorService surfaces that in
        // the report notes.
        let enumeratedKeys = connection.enumerateKeys()
        let knownKeys: Set<String>? = enumeratedKeys.map { Set($0) }

        var readings: [SensorReading] = []
        for (key, label) in keys {
            if let knownKeys, !knownKeys.contains(key) { continue }
            if let celsius = readKeyValue(key), celsius > 0 {
                readings.append(SensorReading(key: key, label: label, celsius: celsius))
            }
        }
        return readings
    }

    // MARK: - Fan Sensors

    public func readFans() -> [FanReading] {
        guard connection.isOpen else { return [] }

        // Fan count key (`FNum`) returns a ui8.
        guard let fanCount = readKeyUInt("FNum"), fanCount > 0 else { return [] }

        var fans: [FanReading] = []
        for i in 0..<min(fanCount, 4) { // practical max: 4 fans
            let prefix = "F\(i)"

            // Actual RPM: F0Ac, F1Ac, …
            guard let rpm = readKeyValue("\(prefix)Ac") else { continue }
            let rpmInt = Int(rpm)

            // Min / max RPM: best effort (may not exist on all Macs).
            let minRpm = readKeyValue("\(prefix)Mn").map(Int.init)
            let maxRpm = readKeyValue("\(prefix)Mx").map(Int.init)

            let label = i == 0 ? "Main Fan" : "Fan \(i + 1)"
            fans.append(FanReading(
                index: Int(i),
                label: label,
                rpm: rpmInt,
                minRpm: minRpm,
                maxRpm: maxRpm
            ))
        }
        return fans
    }

    // MARK: - Chip Generation

    /// Apple Silicon chip generation, detected from `machdep.cpu.brand_string`.
    /// Drives which SMC temperature-key candidates are probed — the E-core
    /// and SoC sensor namespaces have shifted between generations (see
    /// `docs/hardware-matrix.md`).
    public enum ChipGeneration: String, Sendable {
        case m1 = "M1"
        case m2 = "M2"
        case m3 = "M3"
        case m4 = "M4"

        /// Not detected: Intel, or an unrecognized/future chip (e.g. M5).
        case unknown = "unknown"

        /// Label used in report notes.
        public var displayName: String {
            switch self {
            case .unknown: return "unknown-generation"
            default: return rawValue
            }
        }
    }

    /// Detect the Apple Silicon generation from `machdep.cpu.brand_string`
    /// (e.g. "Apple M4 Pro" → `.m4`). Returns `.unknown` on Intel and on
    /// unrecognized chips, so callers fall back to the broad candidate table.
    public static func detectChipGeneration() -> ChipGeneration {
        #if arch(arm64)
        var size = 0
        guard sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0, size > 0 else {
            return .unknown
        }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0) == 0 else {
            return .unknown
        }
        // The sysctl buffer is NUL-terminated; stop at the first NUL.
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        guard let brand = String(bytes: bytes, encoding: .utf8) else { return .unknown }
        return chipGeneration(fromBrandString: brand) ?? .unknown
        #else
        return .unknown
        #endif
    }

    /// Parse a chip brand string into a generation. Testable without sysctl.
    /// Returns nil for Intel and for unrecognized chips.
    public static func chipGeneration(fromBrandString brand: String) -> ChipGeneration? {
        let normalized = brand.uppercased()
        for generation in [ChipGeneration.m1, .m2, .m3, .m4] {
            if normalized.contains(generation.rawValue.uppercased()) { return generation }
        }
        return nil
    }

    // MARK: - Key Tables

    /// Candidate Apple Silicon temperature keys shared by every generation.
    /// Rows are candidates, not guarantees: `readTemperatures` intersects
    /// them with the host-enumerated keys, so a row a given Mac does not
    /// expose is simply omitted.
    ///
    /// `TCMz` (CPU die hotspot) and `TRDX` (GPU die hotspot) are the
    /// authoritative peak sensors (MacMonitor SENSORS.md); `Tp0x` are the
    /// P-core cluster sensors; `TG0P`/`TM0P`/`Ts0S`/`Ta0P` are the die,
    /// memory, SoC and ambient probes carried over from the original flat
    /// list.
    static let commonAppleSiliconTempKeys: [(key: String, label: String)] = [
        ("TCMz", "CPU Die Hotspot"),
        ("TRDX", "GPU Die Hotspot"),
        ("Tp01", "CPU Core 1"),
        ("Tp02", "CPU Core 2"),
        ("Tp03", "CPU Core 3"),
        ("Tp04", "CPU Core 4"),
        ("Tp05", "CPU Core 5"),
        ("Tp06", "CPU Core 6"),
        ("Tp07", "CPU Core 7"),
        ("Tp08", "CPU Core 8"),
        ("Tp09", "CPU Core 9"),
        ("Tp10", "CPU Core 10"),
        ("Tp11", "CPU Core 11"),
        ("Tp12", "CPU Core 12"),
        ("TG0P", "GPU Die"),
        ("TM0P", "Memory Proximity"),
        ("Ts0S", "SoC Die"),
        ("Ta0P", "Ambient"),
    ]

    /// CPU sensors verified on M2 and later (MacMonitor SENSORS.md). Candidate
    /// rows — trimmed by the enumeration intersection when absent.
    static let m2PlusCpuKeys: [(key: String, label: String)] = [
        ("TCMb", "CPU Die (Core Max)"),
        ("TCHP", "CPU/Charger Proximity"),
    ]

    /// E-core cluster sensor keys per generation. The E-core namespace has
    /// shifted between chip generations: M2 exposes `Te04`–`Te06`
    /// (MacMonitor SENSORS.md), and the M3 row (`Te05`/`Te0L`/`Te0P`/`Te0S`)
    /// vs M4 row (`Te05`/`Te0S`/`Te09`/`Te0H`) follow prior art. These rows
    /// could not be re-verified against a live host on macOS builds that
    /// block unprivileged AppleSMC reads — the enumeration intersection
    /// trims any row the host does not expose. The `unknown` row is the
    /// union so the runtime intersection still narrows it down.
    static let eCoreKeysByGeneration: [ChipGeneration: [String]] = [
        .m1: [],
        .m2: ["Te04", "Te05", "Te06"],
        .m3: ["Te05", "Te0L", "Te0P", "Te0S"],
        .m4: ["Te05", "Te0S", "Te09", "Te0H"],
        .unknown: ["Te04", "Te05", "Te06", "Te09", "Te0H", "Te0L", "Te0P", "Te0S"],
    ]

    /// The full Apple Silicon candidate table for one chip generation.
    static func appleSiliconTemperatureKeys(
        for generation: ChipGeneration
    ) -> [(key: String, label: String)] {
        var keys = Self.commonAppleSiliconTempKeys
        if generation != .m1 {
            keys.append(contentsOf: Self.m2PlusCpuKeys)
        }
        for eCoreKey in Self.eCoreKeysByGeneration[generation] ?? [] {
            keys.append((eCoreKey, "CPU E-Core Cluster"))
        }
        return keys
    }

    /// Intel (x86_64) temperature sensor keys.
    static let intelTempKeys: [(key: String, label: String)] = [
        ("TC0C", "CPU Core 1"),
        ("TC1C", "CPU Core 2"),
        ("TC2C", "CPU Core 3"),
        ("TC3C", "CPU Core 4"),
        ("TC4C", "CPU Core 5"),
        ("TC5C", "CPU Core 6"),
        ("TC6C", "CPU Core 7"),
        ("TC7C", "CPU Core 8"),
        ("TC8C", "CPU Core 9"),
        ("TC9C", "CPU Core 10"),
        ("TCXC", "CPU Core X"),
        ("TC0P", "CPU Proximity"),
        ("TG0P", "GPU Proximity"),
        ("TM0P", "Memory Proximity"),
        ("TA0P", "Ambient"),
    ]
}
