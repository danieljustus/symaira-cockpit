import XCTest
import Foundation
@testable import SymTuneCore

// MARK: - TOML Parser Tests

final class TOMLParserTests: XCTestCase {
    private let parser = TOMLParser()

    // MARK: Basic parsing

    func testEmptyInput() {
        let table = parser.parse("")
        XCTAssertTrue(table.sections.isEmpty)
    }

    func testOnlyComments() {
        let table = parser.parse("# just a comment\n# another")
        XCTAssertTrue(table.sections.isEmpty)
    }

    func testKeyValueInSection() {
        let table = parser.parse("[brightness]\nextended_max = 1.6\n")
        XCTAssertEqual(table["brightness", "extended_max"]?.doubleValue, 1.6)
    }

    func testRootLevelKeys() {
        let table = parser.parse("name = \"symtune\"\nversion = 1\n")
        XCTAssertEqual(table["", "name"]?.stringValue, "symtune")
        XCTAssertEqual(table["", "version"]?.intValue, 1)
    }

    // MARK: Value types

    func testStringValues() {
        let table = parser.parse("[s]\nquoted_d = \"hello\"\nquoted_s = 'world'\n")
        XCTAssertEqual(table["s", "quoted_d"]?.stringValue, "hello")
        XCTAssertEqual(table["s", "quoted_s"]?.stringValue, "world")
    }

    func testIntegerValues() {
        let table = parser.parse("[s]\npositive = 42\nnegative = -7\nzero = 0\n")
        XCTAssertEqual(table["s", "positive"]?.intValue, 42)
        XCTAssertEqual(table["s", "negative"]?.intValue, -7)
        XCTAssertEqual(table["s", "zero"]?.intValue, 0)
    }

    func testDoubleValues() {
        let table = parser.parse("[s]\npi = 3.14\nneg = -0.5\n")
        let pi = table["s", "pi"]?.doubleValue
        let neg = table["s", "neg"]?.doubleValue
        XCTAssertNotNil(pi)
        XCTAssertNotNil(neg)
        XCTAssertEqual(pi!, 3.14, accuracy: 0.001)
        XCTAssertEqual(neg!, -0.5, accuracy: 0.001)
    }

    func testBooleanValues() {
        let table = parser.parse("[s]\non = true\noff = false\n")
        XCTAssertEqual(table["s", "on"]?.boolValue, true)
        XCTAssertEqual(table["s", "off"]?.boolValue, false)
    }

    // MARK: Comments

    func testFullLineComment() {
        let table = parser.parse("# comment\n[x]\nkey = 1\n# another\n")
        XCTAssertEqual(table["x", "key"]?.intValue, 1)
    }

    func testInlineComment() {
        let table = parser.parse("[x]\nkey = 42 # the answer\n")
        XCTAssertEqual(table["x", "key"]?.intValue, 42)
    }

    func testCommentInsideString() {
        let table = parser.parse("[x]\nkey = \"value # not a comment\"\n")
        XCTAssertEqual(table["x", "key"]?.stringValue, "value # not a comment")
    }

    // MARK: Sections

    func testMultipleSections() {
        let input = """
        [brightness]
        max = 1.6

        [fan]
        max = 1.0

        [charge]
        min = 50
        """
        let table = parser.parse(input)
        XCTAssertEqual(table["brightness", "max"]?.doubleValue, 1.6)
        XCTAssertEqual(table["fan", "max"]?.doubleValue, 1.0)
        XCTAssertEqual(table["charge", "min"]?.intValue, 50)
    }

    func testDuplicateSectionMergesKeys() {
        let input = """
        [s]
        a = 1
        [s]
        b = 2
        """
        let table = parser.parse(input)
        XCTAssertEqual(table["s", "a"]?.intValue, 1)
        XCTAssertEqual(table["s", "b"]?.intValue, 2)
    }

    func testEmptySection() {
        let table = parser.parse("[empty]\n")
        XCTAssertNotNil(table.sections["empty"])
        XCTAssertTrue(table.sections["empty"]!.isEmpty)
    }

    // MARK: Edge cases

    func testWhitespaceHandling() {
        let table = parser.parse("  [  s  ]  \n  key  =  42  \n")
        XCTAssertEqual(table["s", "key"]?.intValue, 42)
    }

    func testMalformedLineSkipped() {
        let table = parser.parse("[s]\nvalid = 1\nno_equals_here\nalso_valid = 2\n")
        XCTAssertEqual(table["s", "valid"]?.intValue, 1)
        XCTAssertEqual(table["s", "also_valid"]?.intValue, 2)
    }

    func testEmptyValueSkipped() {
        let table = parser.parse("[s]\nkey =\nvalid = 1\n")
        XCTAssertEqual(table["s", "valid"]?.intValue, 1)
        XCTAssertNil(table["s", "key"])
    }

    func testDoubleTableBracketNotSection() {
        let table = parser.parse("[[not_a_section]]\nkey = 1\n")
        XCTAssertNil(table.sections["[not_a_section]"])
        XCTAssertEqual(table["", "key"]?.intValue, 1)
    }

    // MARK: TOMLValue accessors

    func testTOMLValueDoubleFromInt() {
        let val = TOMLValue.integer(5)
        XCTAssertEqual(val.doubleValue, 5.0)
    }

    func testTOMLValueNilAccessors() {
        XCTAssertNil(TOMLValue.string("x").intValue)
        XCTAssertNil(TOMLValue.integer(1).stringValue)
        XCTAssertNil(TOMLValue.double(1.0).boolValue)
        XCTAssertNil(TOMLValue.boolean(true).doubleValue)
    }

    // MARK: TOMLTable subscript

    func testTOMLTableSubscriptMissing() {
        let table = TOMLTable()
        XCTAssertNil(table["no", "key"])
    }
}

// MARK: - TuneConfig Tests

final class TuneConfigTests: XCTestCase {

    // MARK: Defaults match SafetyPolicy

    func testDefaultsMatchSafetyPolicy() {
        let config = TuneConfig()
        XCTAssertEqual(config.extendedBrightnessMin, SafetyPolicy.extendedBrightnessMin)
        XCTAssertEqual(config.extendedBrightnessMax, SafetyPolicy.extendedBrightnessMax)
        XCTAssertEqual(config.dimMin, SafetyPolicy.dimMin)
        XCTAssertEqual(config.dimMax, SafetyPolicy.dimMax)
        XCTAssertEqual(config.brightnessMin, SafetyPolicy.brightnessMin)
        XCTAssertEqual(config.brightnessMax, SafetyPolicy.brightnessMax)
        XCTAssertEqual(config.fanFractionMin, SafetyPolicy.fanFractionMin)
        XCTAssertEqual(config.fanFractionMax, SafetyPolicy.fanFractionMax)
        XCTAssertEqual(config.chargeLimitMin, SafetyPolicy.chargeLimitMin)
        XCTAssertEqual(config.chargeLimitMax, SafetyPolicy.chargeLimitMax)
        XCTAssertEqual(config.defaultProfile, "default")
    }

    // MARK: Custom values

    func testCustomInit() {
        let config = TuneConfig(
            extendedBrightnessMax: 1.4,
            dimMin: 0.2,
            chargeLimitMax: 80,
            defaultProfile: "work"
        )
        XCTAssertEqual(config.extendedBrightnessMax, 1.4)
        XCTAssertEqual(config.dimMin, 0.2)
        XCTAssertEqual(config.chargeLimitMax, 80)
        XCTAssertEqual(config.defaultProfile, "work")
        // Unset values use defaults
        XCTAssertEqual(config.extendedBrightnessMin, SafetyPolicy.extendedBrightnessMin)
    }

    // MARK: TOML loading

    func testLoadFromTOMLFile() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("symtune-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let toml = """
        [brightness]
        extended_brightness_max = 1.4
        dim_min = 0.20

        [fan]
        fan_fraction_max = 0.8

        [charge]
        charge_limit_min = 60

        [general]
        default_profile = "work"
        """

        // Create a home dir structure so ConfigPaths finds our config.toml
        let homeDir = tmp.appendingPathComponent("fakehome", isDirectory: true)
        let configDir = homeDir.appendingPathComponent(".config/symtune", isDirectory: true)
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        try toml.write(to: configDir.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: homeDir) }

        let loadedPaths = ConfigPaths(home: homeDir)
        let config = TuneConfig.load(paths: loadedPaths)

        XCTAssertEqual(config.extendedBrightnessMax, 1.4, accuracy: 0.001)
        XCTAssertEqual(config.dimMin, 0.20, accuracy: 0.001)
        XCTAssertEqual(config.fanFractionMax, 0.8, accuracy: 0.001)
        XCTAssertEqual(config.chargeLimitMin, 60)
        XCTAssertEqual(config.defaultProfile, "work")
        // Unset values keep defaults
        XCTAssertEqual(config.extendedBrightnessMin, SafetyPolicy.extendedBrightnessMin)
    }

    // MARK: Env overrides

    func testEnvOverrideTakesPrecedence() {
        let config = TuneConfig.load(
            paths: ConfigPaths(),
            env: [
                "SYMTUNE_EXTBRIGHT_MAX": "1.3",
                "SYMTUNE_DIM_MIN": "0.25",
                "SYMTUNE_BRIGHTNESS_MAX": "0.9",
                "SYMTUNE_FAN_MIN": "0.1",
                "SYMTUNE_FAN_MAX": "0.9",
                "SYMTUNE_CHARGE_MIN": "55",
                "SYMTUNE_CHARGE_MAX": "90",
                "SYMTUNE_DEFAULT_PROFILE": "gaming",
            ]
        )
        XCTAssertEqual(config.extendedBrightnessMax, 1.3, accuracy: 0.001)
        XCTAssertEqual(config.dimMin, 0.25, accuracy: 0.001)
        XCTAssertEqual(config.brightnessMax, 0.9, accuracy: 0.001)
        XCTAssertEqual(config.fanFractionMin, 0.1, accuracy: 0.001)
        XCTAssertEqual(config.fanFractionMax, 0.9, accuracy: 0.001)
        XCTAssertEqual(config.chargeLimitMin, 55)
        XCTAssertEqual(config.chargeLimitMax, 90)
        XCTAssertEqual(config.defaultProfile, "gaming")
    }

    func testEnvOverrideInvalidValueIgnored() {
        let config = TuneConfig.load(
            paths: ConfigPaths(),
            env: ["SYMTUNE_EXTBRIGHT_MAX": "not-a-number"]
        )
        // Invalid env value is ignored, default used
        XCTAssertEqual(config.extendedBrightnessMax, SafetyPolicy.extendedBrightnessMax)
    }

    func testEnvOverrideEmptyValueIgnored() {
        let config = TuneConfig.load(
            paths: ConfigPaths(),
            env: ["SYMTUNE_EXTBRIGHT_MAX": ""]
        )
        XCTAssertEqual(config.extendedBrightnessMax, SafetyPolicy.extendedBrightnessMax)
    }

    // MARK: Charge-limit hysteresis

    func testChargeLimitHysteresisDefaultsAndClamps() {
        XCTAssertEqual(
            TuneConfig().chargeLimitHysteresisPercent,
            SafetyPolicy.chargeLimitHysteresis
        )

        let overMax = TuneConfig.load(
            paths: ConfigPaths(),
            env: ["SYMTUNE_CHARGE_HYSTERESIS": "999"]
        )
        XCTAssertEqual(overMax.chargeLimitHysteresisPercent, SafetyPolicy.chargeLimitHysteresisMax)

        let underMin = TuneConfig.load(
            paths: ConfigPaths(),
            env: ["SYMTUNE_CHARGE_HYSTERESIS": "0"]
        )
        XCTAssertEqual(underMin.chargeLimitHysteresisPercent, 1)

        let inBand = TuneConfig.load(
            paths: ConfigPaths(),
            env: ["SYMTUNE_CHARGE_HYSTERESIS": "8"]
        )
        XCTAssertEqual(inBand.chargeLimitHysteresisPercent, 8)
    }

    // MARK: Missing / malformed config

    func testMissingConfigFileReturnsDefaults() {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("symtune-nonexistent-\(UUID().uuidString)", isDirectory: true)
        let paths = ConfigPaths(home: home)
        let config = TuneConfig.load(paths: paths)

        XCTAssertEqual(config, TuneConfig())
        try? FileManager.default.removeItem(at: home)
    }

    func testMalformedConfigReturnsDefaults() {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("symtune-malformed-\(UUID().uuidString)", isDirectory: true)
        let configDir = home.appendingPathComponent(".config/symtune", isDirectory: true)
        try? FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let badToml = "this is not valid toml [[[\nkey without value\n"
        let configURL = configDir.appendingPathComponent("config.toml")
        try? badToml.write(to: configURL, atomically: true, encoding: .utf8)

        let paths = ConfigPaths(home: home)
        let config = TuneConfig.load(paths: paths)

        // Malformed file → defaults
        XCTAssertEqual(config, TuneConfig())
    }

    func testPartiallyValidConfig() {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("symtune-partial-\(UUID().uuidString)", isDirectory: true)
        let configDir = home.appendingPathComponent(".config/symtune", isDirectory: true)
        try? FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let toml = """
        [brightness]
        extended_brightness_max = 1.3
        # some garbage follows
        [[[[invalid
        """
        try? toml.write(
            to: configDir.appendingPathComponent("config.toml"),
            atomically: true, encoding: .utf8
        )

        let paths = ConfigPaths(home: home)
        let config = TuneConfig.load(paths: paths)

        // Valid value parsed, invalid lines skipped
        XCTAssertEqual(config.extendedBrightnessMax, 1.3, accuracy: 0.001)
        // Everything else stays default
        XCTAssertEqual(config.dimMin, SafetyPolicy.dimMin)
    }

    // MARK: ConfigPaths.loadConfig convenience

    func testConfigPathsLoadConfigConvenience() {
        // Isolate from any real user config at ~/.config/symtune/config.toml.
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("symtune-convenience-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let paths = ConfigPaths(home: home)
        let config = paths.loadConfig()
        XCTAssertEqual(config, TuneConfig())
    }

    // MARK: TuneController uses config

    func testTuneControllerStoresConfig() {
        let custom = TuneConfig(extendedBrightnessMax: 1.4)
        let controller = TuneController(config: custom)
        XCTAssertEqual(controller.config.extendedBrightnessMax, 1.4)
    }

    func testTuneControllerUsesConfigInWriteStub() {
        let custom = TuneConfig(
            extendedBrightnessMin: 1.2,
            extendedBrightnessMax: 1.4
        )
        let controller = TuneController(config: custom)
        XCTAssertEqual(controller.config.extendedBrightnessMin, 1.2)
        XCTAssertEqual(controller.config.extendedBrightnessMax, 1.4)
    }

    func testTuneControllerDefaultConfig() {
        let controller = TuneController()
        XCTAssertEqual(controller.config, TuneConfig())
    }

    // MARK: - Inverted range validation

    func testInvertedRangeFallsBackToDefaults() {
        let config = TuneConfig.load(
            paths: ConfigPaths(),
            env: [
                "SYMTUNE_BRIGHTNESS_MIN": "0.9",
                "SYMTUNE_BRIGHTNESS_MAX": "0.5",
            ]
        )
        XCTAssertEqual(config.brightnessMin, SafetyPolicy.brightnessMin)
        XCTAssertEqual(config.brightnessMax, SafetyPolicy.brightnessMax)
    }

    func testValidRangeAccepted() {
        let config = TuneConfig.load(
            paths: ConfigPaths(),
            env: [
                "SYMTUNE_BRIGHTNESS_MIN": "0.1",
                "SYMTUNE_BRIGHTNESS_MAX": "0.9",
            ]
        )
        XCTAssertEqual(config.brightnessMin, 0.1, accuracy: 0.001)
        XCTAssertEqual(config.brightnessMax, 0.9, accuracy: 0.001)
    }

    func testInvertedDimRangeFallsBackToDefaults() {
        let config = TuneConfig.load(
            paths: ConfigPaths(),
            env: [
                "SYMTUNE_DIM_MIN": "0.9",
                "SYMTUNE_DIM_MAX": "0.5",
            ]
        )
        XCTAssertEqual(config.dimMin, SafetyPolicy.dimMin)
        XCTAssertEqual(config.dimMax, SafetyPolicy.dimMax)
    }

    // MARK: - SafetyPolicy clamping

    func testDimMinClampedToSafetyPolicy() {
        let config = TuneConfig.load(
            paths: ConfigPaths(),
            env: ["SYMTUNE_DIM_MIN": "0.0"]
        )
        XCTAssertEqual(config.dimMin, SafetyPolicy.dimMin)
        XCTAssertGreaterThan(config.dimMin, 0.0)
    }

    func testFanMaxClampedToSafetyPolicy() {
        let config = TuneConfig.load(
            paths: ConfigPaths(),
            env: ["SYMTUNE_FAN_MAX": "2.0"]
        )
        XCTAssertEqual(config.fanFractionMax, SafetyPolicy.fanFractionMax)
    }

    func testChargeMaxClampedToSafetyPolicy() {
        let config = TuneConfig.load(
            paths: ConfigPaths(),
            env: ["SYMTUNE_CHARGE_MAX": "150"]
        )
        XCTAssertEqual(config.chargeLimitMax, SafetyPolicy.chargeLimitMax)
    }

    func testExtendedBrightnessMaxClampedToSafetyPolicy() {
        let config = TuneConfig.load(
            paths: ConfigPaths(),
            env: ["SYMTUNE_EXTBRIGHT_MAX": "2.0"]
        )
        XCTAssertEqual(config.extendedBrightnessMax, SafetyPolicy.extendedBrightnessMax)
    }

    func testSafetyPolicyClampPreservesValidCustomRange() {
        let config = TuneConfig.load(
            paths: ConfigPaths(),
            env: [
                "SYMTUNE_DIM_MIN": "0.2",
                "SYMTUNE_DIM_MAX": "0.9",
            ]
        )
        XCTAssertEqual(config.dimMin, 0.2, accuracy: 0.001)
        XCTAssertEqual(config.dimMax, 0.9, accuracy: 0.001)
    }
}
