import Foundation

/// On-disk snapshot of the last successful refresh. Used at launch to
/// hydrate `OnCallStore` immediately so the menu is populated without
/// waiting for (or making) a network call when the previous fetch is
/// still within the refresh window.
///
/// Lives under Application Support; safe to delete at any time.
struct CacheSnapshot: Codable {
    let savedAt: Date
    let me: PDUser?
    let groups: [EscalationPolicyGroup]
    let myPolicyIDs: Set<String>
    let currentByPolicy: [String: [PDOnCall]]
    let upcomingByPolicy: [String: [PDOnCall]]
    let upcomingByKey: [String: [PDOnCall]]
    let activeIncidents: [PDIncident]
}

enum CacheStore {
    private static let filename = "snapshot.json"

    private static var fileURL: URL? {
        let fm = FileManager.default
        guard let base = try? fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else { return nil }
        let dir = base.appendingPathComponent("pagerduty-menubar", isDirectory: true)
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir.appendingPathComponent(filename)
    }

    static func load() -> CacheSnapshot? {
        guard let url = fileURL,
              let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(CacheSnapshot.self, from: data)
    }

    static func save(_ snapshot: CacheSnapshot) {
        guard let url = fileURL else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(snapshot) {
            try? data.write(to: url, options: [.atomic])
        }
    }

    static func clear() {
        guard let url = fileURL else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
