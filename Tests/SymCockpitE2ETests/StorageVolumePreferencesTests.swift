import Foundation
import XCTest
import SymTuneCore
@testable import SymTuneUI

final class StorageVolumePreferencesTests: XCTestCase {
    @MainActor
    func testPanelSelectionPersistsWithoutFilteringDiscovery() async throws {
        let suite = "com.symaira.cockpit.storage-selection-tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("preserve", forKey: "unrelated-preference")
        let preferences = PreferencesManager(defaults: defaults)
        let first = StorageVolumeReport(name: "Backup", mountPath: "/Volumes/Backup", uuid: "demo-A")
        let second = StorageVolumeReport(name: "Backup", mountPath: "/Volumes/Backup 1", uuid: "demo-B")
        let all = [first, second]
        XCTAssertNil(defaults.object(forKey: PreferencesManager.hiddenStorageVolumeIDsKey), "Construction must not write")
        XCTAssertTrue(preferences.storageVolumeVisibility(for: first).wrappedValue)
        XCTAssertTrue(preferences.storageVolumeVisibility(for: second).wrappedValue)

        preferences.storageVolumeVisibility(for: first).wrappedValue = false
        let panel = StorageVolumesCard(volumes: all, hiddenVolumeIDs: preferences.hiddenStorageVolumeIDs,
                                       visibility: { preferences.storageVolumeVisibility(for: $0) })
        XCTAssertEqual(panel.visibleVolumes, [second])
        XCTAssertEqual(panel.volumes, all, "Selection must not remove discovered volumes")
        XCTAssertEqual(defaults.stringArray(forKey: PreferencesManager.hiddenStorageVolumeIDsKey), [first.selectionID])
        let reloaded = PreferencesManager(defaults: defaults)
        let renamed = StorageVolumeReport(name: "Archive", mountPath: "/Volumes/Archive", uuid: "demo-A")
        XCTAssertFalse(reloaded.storageVolumeVisibility(for: renamed).wrappedValue)
        XCTAssertTrue(reloaded.storageVolumeVisibility(for: second).wrappedValue)
        let newcomer = StorageVolumeReport(name: "New USB", mountPath: "/Volumes/New USB", uuid: "demo-C")
        XCTAssertTrue(reloaded.storageVolumeVisibility(for: newcomer).wrappedValue)

        reloaded.storageVolumeVisibility(for: second).wrappedValue = false
        let emptyPanel = StorageVolumesCard(volumes: all, hiddenVolumeIDs: reloaded.hiddenStorageVolumeIDs,
                                            visibility: { reloaded.storageVolumeVisibility(for: $0) })
        XCTAssertEqual(emptyPanel.visibleVolumes, [])
        XCTAssertEqual(emptyPanel.volumes, all, "Hidden volumes remain available to the selection menu")
        XCTAssertNotNil(emptyPanel.visibility)
        reloaded.storageVolumeVisibility(for: renamed).wrappedValue = true
        XCTAssertEqual(reloaded.hiddenStorageVolumeIDs, [second.selectionID])
        XCTAssertEqual(defaults.string(forKey: "unrelated-preference"), "preserve")
        XCTAssertTrue(reloaded.visibleCards.contains(.storageVolumes))
        XCTAssertNil(StorageVolumesCard(volumes: all).visibility, "Passive previews have no preference write path")
        XCTAssertNil(StorageVolumesCard(volumes: nil).visibleVolumes, "Loading is not an empty selection")
    }
}
