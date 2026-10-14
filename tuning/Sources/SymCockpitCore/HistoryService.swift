import Foundation
import SymCockpitHistory

public final class HistoryService: @unchecked Sendable {
    private let store: CanonicalHistoryStore

    public init(dataDir: URL) {
        self.store = CanonicalHistoryStore(fileURL: dataDir.appendingPathComponent("history.ndjson"))
    }

    public var isWritable: Bool { store.isWritable }

    public func logEvent(_ event: HistoryEvent) {
        do {
            try store.append(try canonicalEvent(from: event))
        } catch {
            fputs("symtune: warning: failed to write history event: \(error.localizedDescription)\n", stderr)
        }
    }

    public func readEvents(limit: Int? = 100) -> [HistoryEvent] {
        guard let records = try? store.read(limit: limit) else { return [] }
        return records.compactMap { decodeTuneEvent(from: $0.payload) }
    }

    private func canonicalEvent(from event: HistoryEvent) throws -> CanonicalHistoryEvent {
        let payload = try payload(from: event)
        guard let timestamp = payload["timestamp"]?.stringValue,
              let action = payload["action"]?.stringValue else {
            throw CocoaError(.coderInvalidValue)
        }
        return CanonicalHistoryEvent(source: "tune", timestamp: timestamp, action: action, payload: payload)
    }

    private func payload(from event: HistoryEvent) throws -> [String: HistoryJSONValue] {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.sortedKeys]
        guard case .object(let object) = try HistoryJSONValue.fromJSONData(encoder.encode(event)) else {
            throw CocoaError(.coderInvalidValue)
        }
        return object
    }

    private func decodeTuneEvent(from payload: [String: HistoryJSONValue]) -> HistoryEvent? {
        guard let data = try? HistoryJSONValue.object(payload).jsonData() else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try? decoder.decode(HistoryEvent.self, from: data)
    }
}
