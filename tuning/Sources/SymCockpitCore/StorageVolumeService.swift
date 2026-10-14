import Foundation

/// A mounted, user-visible filesystem, not a physical disk. APFS volumes can
/// share capacity, so callers must not sum these figures into a machine total.
public struct StorageVolumeReport: Codable, Sendable, Equatable, Identifiable {
    public let name: String
    public let mountPath: String
    /// Native filesystem identity, when available; stable across volume renames.
    public let uuid: String?
    public let isInternal: Bool?
    public let isLocal: Bool?
    public let isReadOnly: Bool?
    /// Nil means capacity could not be read, never an empty disk.
    public let space: DiskReport?

    /// Mount paths distinguish even two volumes with identical display names.
    public var id: String { mountPath }
    public var isBoot: Bool { mountPath == "/" }

    public var selectionID: String {
        if let uuid, !uuid.isEmpty { return "uuid:\(uuid)" }
        // ponytail: filesystems without a UUID follow their mount path; use a
        // provider-specific identity if persistent network-volume renames are needed.
        return "path:\(mountPath)"
    }

    public init(
        name: String, mountPath: String, uuid: String? = nil,
        isInternal: Bool? = nil, isLocal: Bool? = nil, isReadOnly: Bool? = nil,
        space: DiskReport? = nil
    ) {
        self.name = name
        self.mountPath = mountPath
        self.uuid = uuid
        self.isInternal = isInternal
        self.isLocal = isLocal
        self.isReadOnly = isReadOnly
        self.space = space
    }

    public var kind: String {
        if isBoot { return "Startup volume" }
        if isLocal == false { return "Network / virtual volume" }
        if isInternal == true { return "Internal volume" }
        if isInternal == false { return "External volume" }
        return "Volume"
    }

    public var usedFraction: Double? {
        guard let space, space.capacityBytes > 0 else { return nil }
        return min(Double(space.usedBytes) / Double(space.capacityBytes), 1)
    }

    /// Uses the same decimal storage convention as the existing Disk metric.
    public var capacitySummary: String {
        guard let space else { return "Capacity unavailable" }
        let used = MetricFormatting.storageBytes(space.usedBytes)
        let total = MetricFormatting.storageBytes(space.capacityBytes)
        let available = MetricFormatting.storageBytes(space.freeBytes)
        return "\(used) used of \(total) · \(available) available"
    }
}

/// Native metadata reads only: no diskutil subprocess, file scan, or mounting.
public struct StorageVolumeService: Sendable {
    private let mountedVolumes: @Sendable () -> [URL]
    private let resourceValues: @Sendable (URL) throws -> VolumeResourceValues

    private static let keys: Set<URLResourceKey> = [
        .volumeNameKey, .volumeUUIDStringKey, .volumeIsInternalKey, .volumeIsLocalKey,
        .volumeIsReadOnlyKey, .volumeIsBrowsableKey,
        .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
        .volumeAvailableCapacityForImportantUsageKey
    ]

    public init() {
        self.init(
            mountedVolumes: {
                FileManager.default.mountedVolumeURLs(
                    includingResourceValuesForKeys: nil, options: [.skipHiddenVolumes]
                ) ?? []
            },
            resourceValues: { Self.metadata(try $0.resourceValues(forKeys: Self.keys)) }
        )
    }

    /// Value-based seam keeps discovery checks independent of real disks.
    init(
        mountedVolumes: @escaping @Sendable () -> [URL],
        resourceValues: @escaping @Sendable (URL) throws -> VolumeResourceValues
    ) {
        self.mountedVolumes = mountedVolumes
        self.resourceValues = resourceValues
    }

    public func read() -> [StorageVolumeReport] {
        var seen: Set<String> = []
        return mountedVolumes().compactMap { url -> StorageVolumeReport? in
            let path = url.standardizedFileURL.path
            guard !path.hasPrefix("/System/Volumes/"),
                  !url.lastPathComponent.hasPrefix("."), seen.insert(path).inserted else { return nil }
            let values = try? resourceValues(url)
            guard values?.volumeIsBrowsable != false else { return nil }
            // The sealed root snapshot is not the writable startup data volume.
            let dataValues = path == "/"
                ? try? resourceValues(URL(fileURLWithPath: "/System/Volumes/Data")) : nil
            let space = (dataValues.flatMap(Self.statistics) ?? values.flatMap(Self.statistics)).map {
                DiskReport(capacityBytes: $0.capacityBytes, usedBytes: $0.usedBytes, freeBytes: $0.freeBytes)
            }
            return StorageVolumeReport(
                name: values?.volumeName ?? (path == "/" ? "Startup volume" : url.lastPathComponent),
                mountPath: path, uuid: dataValues?.volumeUUIDString ?? values?.volumeUUIDString,
                isInternal: values?.volumeIsInternal,
                isLocal: values?.volumeIsLocal, isReadOnly: dataValues?.volumeIsReadOnly ?? values?.volumeIsReadOnly,
                space: space
            )
        }.sorted { lhs, rhs in
            if lhs.isBoot != rhs.isBoot { return lhs.isBoot }
            if (lhs.isInternal == true) != (rhs.isInternal == true) { return lhs.isInternal == true }
            let order = lhs.name.localizedStandardCompare(rhs.name)
            return order == .orderedSame ? lhs.mountPath < rhs.mountPath : order == .orderedAscending
        }
    }

    /// Important-usage availability includes purgeable APFS space, like Finder.
    /// Some non-APFS/network volumes report zero for that unsupported key even
    /// though ordinary available capacity is positive; prefer the latter then.
    static func statistics(_ values: URLResourceValues) -> DiskStatistics? {
        statistics(metadata(values))
    }

    static func statistics(_ values: VolumeResourceValues) -> DiskStatistics? {
        let important = values.volumeAvailableCapacityForImportantUsage
        let ordinary = values.volumeAvailableCapacity.map(Int64.init)
        guard let total = values.volumeTotalCapacity, total > 0,
              let available = important.flatMap({ $0 > 0 ? $0 : nil })
                ?? ordinary.flatMap({ $0 >= 0 ? $0 : nil })
                ?? important.flatMap({ $0 == 0 ? $0 : nil }) else { return nil }
        let capacity = UInt64(total)
        let free = min(UInt64(available), capacity)
        return DiskStatistics(capacityBytes: capacity, usedBytes: capacity - free, freeBytes: free)
    }

    private static func metadata(_ values: URLResourceValues) -> VolumeResourceValues {
        VolumeResourceValues(
            volumeName: values.volumeName, volumeUUIDString: values.volumeUUIDString,
            volumeIsInternal: values.volumeIsInternal,
            volumeIsLocal: values.volumeIsLocal, volumeIsReadOnly: values.volumeIsReadOnly,
            volumeIsBrowsable: values.volumeIsBrowsable, volumeTotalCapacity: values.volumeTotalCapacity,
            volumeAvailableCapacity: values.volumeAvailableCapacity,
            volumeAvailableCapacityForImportantUsage: values.volumeAvailableCapacityForImportantUsage
        )
    }
}

/// Own values rather than Foundation's read-only resource object, so tests can
/// represent unsupported capacity keys and disks disappearing during a read.
struct VolumeResourceValues: Sendable {
    var volumeName: String?
    var volumeUUIDString: String?
    var volumeIsInternal: Bool?
    var volumeIsLocal: Bool?
    var volumeIsReadOnly: Bool?
    var volumeIsBrowsable: Bool?
    var volumeTotalCapacity: Int?
    var volumeAvailableCapacity: Int?
    var volumeAvailableCapacityForImportantUsage: Int64?
}
