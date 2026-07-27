import CryptoKit
import Foundation
import ImageIO
import SQLite3

public enum WallpaperMediaKind: String, Codable, Sendable {
    case video
    case image
}

public enum WallpaperProvenance: String, Codable, Sendable {
    case discovery
    case generated
    case upscaled
    case imported
}

public struct WallpaperMetadata: Codable, Equatable, Identifiable, Sendable {
    public let schemaVersion: Int
    public let id: String
    public let mediaRelativePath: String
    public let mediaKind: WallpaperMediaKind
    public var title: String
    public var description: String
    public var tags: [String]
    public let provenance: WallpaperProvenance
    public var sourceWallpaperID: String?
    public let width: Int?
    public let height: Int?
    public let duration: TimeInterval?
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        schemaVersion: Int = 1,
        id: String,
        mediaRelativePath: String,
        mediaKind: WallpaperMediaKind,
        title: String,
        description: String,
        tags: [String],
        provenance: WallpaperProvenance,
        sourceWallpaperID: String? = nil,
        width: Int? = nil,
        height: Int? = nil,
        duration: TimeInterval? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.mediaRelativePath = mediaRelativePath
        self.mediaKind = mediaKind
        self.title = title
        self.description = description
        self.tags = tags
        self.provenance = provenance
        self.sourceWallpaperID = sourceWallpaperID
        self.width = width
        self.height = height
        self.duration = duration
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var mediaURL: URL {
        PaperwallConfiguration.sharedDataDirectory
            .appendingPathComponent(mediaRelativePath)
    }
}

public enum WallpaperCatalogError: Error, LocalizedError {
    case mediaOutsideSharedStorage(URL)
    case database(String)
    case invalidSidecar(URL)

    public var errorDescription: String? {
        switch self {
        case .mediaOutsideSharedStorage(let url):
            "Wallpaper is outside Paperwall's shared storage: \(url.path)"
        case .database(let detail):
            "Wallpaper catalog database error: \(detail)"
        case .invalidSidecar(let url):
            "Wallpaper metadata is invalid: \(url.path)"
        }
    }
}

public actor WallpaperCatalog {
    public static let shared = WallpaperCatalog()

    private let fileManager = FileManager.default
    private var database: OpaquePointer?
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    public func refresh() async throws -> [WallpaperMetadata] {
        try await PaperwallStorageMigrator.migrateLegacySharedAssetsIfNeeded()
        try openDatabaseIfNeeded()
        let mediaURLs = discoverMedia()
        var records: [WallpaperMetadata] = []
        records.reserveCapacity(mediaURLs.count)
        for mediaURL in mediaURLs {
            do {
                let metadata = try await loadOrCreateSidecar(for: mediaURL)
                try upsert(metadata)
                records.append(metadata)
            } catch {
                NSLog("Paperwall: could not catalog %@: %@", mediaURL.lastPathComponent, error.localizedDescription)
            }
        }
        try deleteRows(except: Set(records.map(\.id)))
        return records.sorted {
            $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }

    public func metadata(for mediaURL: URL) async throws -> WallpaperMetadata {
        try openDatabaseIfNeeded()
        if let existing = try fetch(relativePath: try relativePath(for: mediaURL)) {
            return existing
        }
        let metadata = try await loadOrCreateSidecar(for: mediaURL)
        try upsert(metadata)
        return metadata
    }

    @discardableResult
    public func update(
        mediaURL: URL,
        title: String,
        description: String,
        tags: [String]
    ) async throws -> WallpaperMetadata {
        var metadata = try await metadata(for: mediaURL)
        metadata.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        metadata.description = description.trimmingCharacters(in: .whitespacesAndNewlines)
        metadata.tags = normalizedTags(tags)
        metadata.updatedAt = Date()
        try writeSidecar(metadata, for: mediaURL)
        try upsert(metadata)
        return metadata
    }

    @discardableResult
    public func enrich(
        mediaURL: URL,
        description: String,
        tags: [String],
        provenance: WallpaperProvenance,
        sourceWallpaperID: String? = nil
    ) async throws -> WallpaperMetadata {
        var metadata = try await buildMetadata(for: mediaURL, provenanceOverride: provenance)
        metadata.description = description.trimmingCharacters(in: .whitespacesAndNewlines)
        metadata.tags = normalizedTags(metadata.tags + tags)
        metadata.sourceWallpaperID = sourceWallpaperID
        metadata.updatedAt = Date()
        try writeSidecar(metadata, for: mediaURL)
        try openDatabaseIfNeeded()
        try upsert(metadata)
        return metadata
    }

    private func discoverMedia() -> [URL] {
        let root = PaperwallConfiguration.sharedDataDirectory
        let allowed = Set(["mp4", "mov", "m4v", "png", "jpg", "jpeg", "webp", "heic"])
        let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        var urls: [URL] = []
        while let url = enumerator?.nextObject() as? URL {
            guard allowed.contains(url.pathExtension.lowercased()),
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                continue
            }
            urls.append(url)
        }
        return urls
    }

    private func loadOrCreateSidecar(for mediaURL: URL) async throws -> WallpaperMetadata {
        let sidecarURL = sidecarURL(for: mediaURL)
        if let data = try? Data(contentsOf: sidecarURL),
           var metadata = try? decoder.decode(WallpaperMetadata.self, from: data),
           metadata.schemaVersion == 1,
           metadata.mediaRelativePath == (try? relativePath(for: mediaURL)) {
            if metadata.title.isEmpty {
                metadata.title = inferredTitle(for: mediaURL)
            }
            return metadata
        }
        let metadata = try await buildMetadata(for: mediaURL)
        try writeSidecar(metadata, for: mediaURL)
        return metadata
    }

    private func buildMetadata(
        for mediaURL: URL,
        provenanceOverride: WallpaperProvenance? = nil
    ) async throws -> WallpaperMetadata {
        let relativePath = try relativePath(for: mediaURL)
        let extensionName = mediaURL.pathExtension.lowercased()
        let isVideo = ["mp4", "mov", "m4v"].contains(extensionName)
        let provenance = provenanceOverride ?? inferredProvenance(relativePath: relativePath)
        let values = try? mediaURL.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        let createdAt = values?.creationDate ?? values?.contentModificationDate ?? Date()
        let dimensions: (Int?, Int?, TimeInterval?)
        if isVideo, let info = try? await VideoAssetValidator.validate(url: mediaURL) {
            dimensions = (info.width, info.height, info.duration)
        } else if !isVideo, let source = CGImageSourceCreateWithURL(mediaURL as CFURL, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            dimensions = (
                properties[kCGImagePropertyPixelWidth] as? Int,
                properties[kCGImagePropertyPixelHeight] as? Int,
                nil
            )
        } else {
            dimensions = (nil, nil, nil)
        }
        let id = try sha256(mediaURL).map { String(format: "%02x", $0) }.joined()
        return WallpaperMetadata(
            id: id,
            mediaRelativePath: relativePath,
            mediaKind: isVideo ? .video : .image,
            title: inferredTitle(for: mediaURL),
            description: inferredDescription(provenance),
            tags: inferredTags(provenance: provenance, width: dimensions.0),
            provenance: provenance,
            width: dimensions.0,
            height: dimensions.1,
            duration: dimensions.2,
            createdAt: createdAt,
            updatedAt: createdAt
        )
    }

    private func sidecarURL(for mediaURL: URL) -> URL {
        mediaURL.appendingPathExtension("paperwall.json")
    }

    private func writeSidecar(_ metadata: WallpaperMetadata, for mediaURL: URL) throws {
        try encoder.encode(metadata).write(to: sidecarURL(for: mediaURL), options: .atomic)
    }

    private func relativePath(for mediaURL: URL) throws -> String {
        let root = PaperwallConfiguration.sharedDataDirectory.standardizedFileURL.path + "/"
        let path = mediaURL.standardizedFileURL.path
        guard path.hasPrefix(root) else {
            throw WallpaperCatalogError.mediaOutsideSharedStorage(mediaURL)
        }
        return String(path.dropFirst(root.count))
    }

    private func inferredProvenance(relativePath: String) -> WallpaperProvenance {
        if relativePath.hasPrefix("Library/Discovery/") { return .discovery }
        if relativePath.hasPrefix("Generation/Upscaled/") { return .upscaled }
        if relativePath.hasPrefix("Generation/") { return .generated }
        return .imported
    }

    private func inferredDescription(_ provenance: WallpaperProvenance) -> String {
        switch provenance {
        case .discovery: "Imported from Discovery."
        case .generated: "Generated by Paperwall."
        case .upscaled: "Paperwall-generated video enhanced to 4K."
        case .imported: "Imported into Paperwall."
        }
    }

    private func inferredTags(provenance: WallpaperProvenance, width: Int?) -> [String] {
        var tags = [provenance.rawValue]
        if let width, width >= 3_840 { tags.append("4k") }
        return tags
    }

    private func inferredTitle(for mediaURL: URL) -> String {
        var name = mediaURL.deletingPathExtension().lastPathComponent
        name = name.replacingOccurrences(
            of: "-[0-9a-f]{12,64}$",
            with: "",
            options: .regularExpression
        )
        name = name.replacingOccurrences(of: "[_-]+", with: " ", options: .regularExpression)
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.range(of: "^[0-9]+$", options: .regularExpression) != nil {
            return "Wallpaper \(name)"
        }
        return name.capitalized
    }

    private func normalizedTags(_ tags: [String]) -> [String] {
        Array(Set(tags.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }.filter { !$0.isEmpty })).sorted()
    }

    private var databaseURL: URL {
        PaperwallConfiguration.applicationSupportDirectory
            .appendingPathComponent("Catalog/catalog.sqlite3")
    }

    private func openDatabaseIfNeeded() throws {
        guard database == nil else { return }
        try fileManager.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var handle: OpaquePointer?
        guard sqlite3_open_v2(
            databaseURL.path,
            &handle,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK, let handle else {
            throw WallpaperCatalogError.database("could not open \(databaseURL.path)")
        }
        database = handle
        try execute("PRAGMA journal_mode=WAL;")
        try execute("PRAGMA synchronous=NORMAL;")
        try execute("""
            CREATE TABLE IF NOT EXISTS wallpapers (
                id TEXT PRIMARY KEY,
                relative_path TEXT NOT NULL UNIQUE,
                media_kind TEXT NOT NULL,
                title TEXT NOT NULL,
                description TEXT NOT NULL,
                tags_json TEXT NOT NULL,
                provenance TEXT NOT NULL,
                source_wallpaper_id TEXT,
                width INTEGER,
                height INTEGER,
                duration REAL,
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL
            );
            """)
        try execute("CREATE INDEX IF NOT EXISTS wallpapers_title ON wallpapers(title COLLATE NOCASE);")
        try execute("CREATE INDEX IF NOT EXISTS wallpapers_provenance ON wallpapers(provenance);")
    }

    private func upsert(_ metadata: WallpaperMetadata) throws {
        let sql = """
            INSERT INTO wallpapers (
                id, relative_path, media_kind, title, description, tags_json, provenance,
                source_wallpaper_id, width, height, duration, created_at, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                relative_path=excluded.relative_path, media_kind=excluded.media_kind,
                title=excluded.title, description=excluded.description, tags_json=excluded.tags_json,
                provenance=excluded.provenance, source_wallpaper_id=excluded.source_wallpaper_id,
                width=excluded.width, height=excluded.height, duration=excluded.duration,
                created_at=excluded.created_at, updated_at=excluded.updated_at;
            """
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        let iso = ISO8601DateFormatter()
        let tagsData = try JSONEncoder().encode(metadata.tags)
        let tagsJSON = String(data: tagsData, encoding: .utf8) ?? "[]"
        bind(metadata.id, to: 1, in: statement)
        bind(metadata.mediaRelativePath, to: 2, in: statement)
        bind(metadata.mediaKind.rawValue, to: 3, in: statement)
        bind(metadata.title, to: 4, in: statement)
        bind(metadata.description, to: 5, in: statement)
        bind(tagsJSON, to: 6, in: statement)
        bind(metadata.provenance.rawValue, to: 7, in: statement)
        bind(metadata.sourceWallpaperID, to: 8, in: statement)
        bind(metadata.width, to: 9, in: statement)
        bind(metadata.height, to: 10, in: statement)
        bind(metadata.duration, to: 11, in: statement)
        bind(iso.string(from: metadata.createdAt), to: 12, in: statement)
        bind(iso.string(from: metadata.updatedAt), to: 13, in: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError() }
    }

    private func fetch(relativePath: String) throws -> WallpaperMetadata? {
        let statement = try prepare("SELECT id, media_kind, title, description, tags_json, provenance, source_wallpaper_id, width, height, duration, created_at, updated_at FROM wallpapers WHERE relative_path = ? LIMIT 1;")
        defer { sqlite3_finalize(statement) }
        bind(relativePath, to: 1, in: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        let tagsData = Data(columnText(statement, 4).utf8)
        let tags = (try? JSONDecoder().decode([String].self, from: tagsData)) ?? []
        let iso = ISO8601DateFormatter()
        guard let kind = WallpaperMediaKind(rawValue: columnText(statement, 1)),
              let provenance = WallpaperProvenance(rawValue: columnText(statement, 5)) else {
            return nil
        }
        return WallpaperMetadata(
            id: columnText(statement, 0),
            mediaRelativePath: relativePath,
            mediaKind: kind,
            title: columnText(statement, 2),
            description: columnText(statement, 3),
            tags: tags,
            provenance: provenance,
            sourceWallpaperID: columnOptionalText(statement, 6),
            width: columnOptionalInt(statement, 7),
            height: columnOptionalInt(statement, 8),
            duration: columnOptionalDouble(statement, 9),
            createdAt: iso.date(from: columnText(statement, 10)) ?? Date(),
            updatedAt: iso.date(from: columnText(statement, 11)) ?? Date()
        )
    }

    private func deleteRows(except ids: Set<String>) throws {
        let statement = try prepare("SELECT id FROM wallpapers;")
        defer { sqlite3_finalize(statement) }
        var stale: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let id = columnText(statement, 0)
            if !ids.contains(id) { stale.append(id) }
        }
        for id in stale {
            let delete = try prepare("DELETE FROM wallpapers WHERE id = ?;")
            bind(id, to: 1, in: delete)
            guard sqlite3_step(delete) == SQLITE_DONE else {
                sqlite3_finalize(delete)
                throw databaseError()
            }
            sqlite3_finalize(delete)
        }
    }

    private func execute(_ sql: String) throws {
        guard let database else { throw WallpaperCatalogError.database("database is closed") }
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &error) == SQLITE_OK else {
            let detail = error.map { String(cString: $0) } ?? "unknown SQLite error"
            sqlite3_free(error)
            throw WallpaperCatalogError.database(detail)
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        guard let database else { throw WallpaperCatalogError.database("database is closed") }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { throw databaseError() }
        return statement
    }

    private func databaseError() -> WallpaperCatalogError {
        guard let database else { return .database("database is closed") }
        return .database(String(cString: sqlite3_errmsg(database)))
    }

    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func bind(_ value: String?, to index: Int32, in statement: OpaquePointer) {
        if let value { sqlite3_bind_text(statement, index, value, -1, transient) }
        else { sqlite3_bind_null(statement, index) }
    }

    private func bind(_ value: Int?, to index: Int32, in statement: OpaquePointer) {
        if let value { sqlite3_bind_int64(statement, index, sqlite3_int64(value)) }
        else { sqlite3_bind_null(statement, index) }
    }

    private func bind(_ value: Double?, to index: Int32, in statement: OpaquePointer) {
        if let value { sqlite3_bind_double(statement, index, value) }
        else { sqlite3_bind_null(statement, index) }
    }

    private func columnText(_ statement: OpaquePointer, _ index: Int32) -> String {
        guard let value = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: value)
    }

    private func columnOptionalText(_ statement: OpaquePointer, _ index: Int32) -> String? {
        sqlite3_column_type(statement, index) == SQLITE_NULL ? nil : columnText(statement, index)
    }

    private func columnOptionalInt(_ statement: OpaquePointer, _ index: Int32) -> Int? {
        sqlite3_column_type(statement, index) == SQLITE_NULL
            ? nil : Int(sqlite3_column_int64(statement, index))
    }

    private func columnOptionalDouble(_ statement: OpaquePointer, _ index: Int32) -> Double? {
        sqlite3_column_type(statement, index) == SQLITE_NULL
            ? nil : sqlite3_column_double(statement, index)
    }

    private func sha256(_ url: URL) throws -> SHA256.Digest {
        SHA256.hash(data: try Data(contentsOf: url, options: [.mappedIfSafe]))
    }
}
