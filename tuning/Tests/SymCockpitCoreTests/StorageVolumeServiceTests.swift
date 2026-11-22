import Foundation
import XCTest
@testable import SymCockpitCore

final class StorageVolumeServiceTests: XCTestCase {
    func testDiscoveryAndCapacityFallbacks() throws {
        let paths = ["/Volumes/USB 1", "/System/Volumes/Preboot", "/Volumes/.hidden", "/",
                     "/Volumes/USB", "/Volumes/USB", "/Volumes/private", "/Volumes/unreadable", "/Volumes/Internal"]
        let service = StorageVolumeService(
            mountedVolumes: { paths.map { URL(fileURLWithPath: $0) } },
            resourceValues: { url in
                if url.path == "/Volumes/unreadable" { throw CocoaError(.fileReadNoPermission) }
                return VolumeResourceValues(
                    volumeName: url.path == "/" ? "Macintosh HD" : "Shared name",
                    volumeUUIDString: "demo-\(url.path)",
                    volumeIsInternal: url.path == "/" || url.path == "/Volumes/Internal",
                    volumeIsLocal: true, volumeIsReadOnly: url.path == "/Volumes/USB",
                    volumeIsBrowsable: url.path != "/Volumes/private",
                    volumeTotalCapacity: 100,
                    volumeAvailableCapacity: url.path == "/System/Volumes/Data" ? 40 : 1,
                    volumeAvailableCapacityForImportantUsage: 0
                )
            }
        )
        let volumes = service.read()
        XCTAssertEqual(volumes.map(\.mountPath), ["/", "/Volumes/Internal", "/Volumes/USB", "/Volumes/USB 1", "/Volumes/unreadable"])
        XCTAssertEqual(Set(volumes.map(\.id)).count, volumes.count)
        XCTAssertEqual(volumes.first?.space?.freeBytes, 40, "Boot capacity must come from the writable Data volume")
        XCTAssertEqual(volumes.first?.uuid, "demo-/System/Volumes/Data")
        XCTAssertEqual(volumes[2].uuid, "demo-/Volumes/USB")
        XCTAssertEqual(volumes[2].isReadOnly, true)
        XCTAssertNil(volumes.last?.space)
        XCTAssertNil(volumes.last?.usedFraction)
        XCTAssertEqual(volumes.last?.capacitySummary, "Capacity unavailable")
        XCTAssertTrue(StorageVolumeService(mountedVolumes: { [] }, resourceValues: { _ in VolumeResourceValues() }).read().isEmpty)

        // total, ordinary available, important-usage available, expected free.
        func input(_ total: Int?, _ ordinary: Int?, _ important: Int64?) -> VolumeResourceValues {
            VolumeResourceValues(volumeTotalCapacity: total, volumeAvailableCapacity: ordinary,
                                 volumeAvailableCapacityForImportantUsage: important)
        }
        let cases: [(VolumeResourceValues, UInt64?)] = [
            (input(100, 10, 30), 30), (input(100, 10, 0), 10), (input(100, 10, nil), 10),
            (input(100, 10, -1), 10), (input(100, 0, 0), 0), (input(100, nil, 0), 0),
            (input(100, 200, nil), 100), (input(100, nil, nil), nil), (input(nil, 10, 30), nil),
            (input(0, 10, 30), nil), (input(-1, 10, 30), nil), (input(100, -1, -1), nil)
        ]
        for (values, expected) in cases {
            let result = StorageVolumeService.statistics(values)
            XCTAssertEqual(result?.freeBytes, expected, "Capacity fallback for \(values)")
            if let result { XCTAssertEqual(result.usedBytes + result.freeBytes, result.capacityBytes) }
        }
    }

    func testStableSelectionIdentityAndLegacyVolumeJSON() throws {
        let original = StorageVolumeReport(name: "Backup", mountPath: "/Volumes/Backup", uuid: "demo-volume-A")
        let renamed = StorageVolumeReport(name: "Archive", mountPath: "/Volumes/Archive 1", uuid: "demo-volume-A")
        let sameName = StorageVolumeReport(name: "Backup", mountPath: "/Volumes/Backup 1", uuid: "demo-volume-B")
        XCTAssertEqual(original.selectionID, renamed.selectionID)
        XCTAssertNotEqual(original.id, renamed.id)
        XCTAssertNotEqual(original.selectionID, sameName.selectionID)
        XCTAssertEqual(StorageVolumeReport(name: "NAS", mountPath: "/Volumes/NAS").selectionID, "path:/Volumes/NAS")
        XCTAssertEqual(StorageVolumeReport(name: "NAS", mountPath: "/Volumes/NAS", uuid: "").selectionID, "path:/Volumes/NAS")

        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let data = try encoder.encode(original)
        XCTAssertEqual(try decoder.decode(StorageVolumeReport.self, from: data), original)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        legacy.removeValue(forKey: "uuid")
        let decoded = try decoder.decode(StorageVolumeReport.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertNil(decoded.uuid)
        XCTAssertEqual(decoded.selectionID, "path:/Volumes/Backup")
    }

    func testCardVisibilityMigrationPreservesChoices() {
        let parser = TOMLParser()
        for version in [1, 2] {
            let table = parser.parse("[popover]\ncards_version = \(version)\ncards = ['displays']")
            let cards = TuneConfig.parseCardSet(table: table)
            XCTAssertTrue(cards.contains(.storageVolumes))
            XCTAssertTrue(cards.contains(.displays))
            XCTAssertFalse(cards.contains(.systemStatus), "Existing hidden cards stay hidden")
            XCTAssertEqual(cards.contains(.topProcesses), version == 1)
        }
        let current = parser.parse("[popover]\ncards_version = \(TuneConfig.popoverCardsSchemaVersion)\ncards = ['displays']")
        XCTAssertEqual(TuneConfig.parseCardSet(table: current), [.displays])
        XCTAssertEqual(TuneConfig.parseCardSet(table: parser.parse("[popover]\ncards = []")), [])
        XCTAssertTrue(TuneConfig().visibleCards.contains(.storageVolumes))
    }
}
