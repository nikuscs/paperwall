import Foundation

public struct PaperwallWorkItem: Identifiable, Sendable, Equatable {
    public enum Kind: String, Sendable {
        case image = "Image"
        case video = "Video"
        case upscale = "4K upscale"
    }

    public let id: String
    public let kind: Kind
    public let title: String
    public let status: String
    public let updatedAt: Date
    public let outputURL: URL?

    public var isActive: Bool {
        ["submitting", "starting", "processing", "downloaded"].contains(status.lowercased())
    }

    public var isFailed: Bool {
        ["failed", "canceled"].contains(status.lowercased())
    }
}

public enum PaperwallWorkQueue {
    public static func items(limit: Int = 30) -> [PaperwallWorkItem] {
        var result: [PaperwallWorkItem] = []
        let root = PaperwallConfiguration.generationStateDirectory
        result += loadJobs(in: root.appendingPathComponent("ImageJobs"), kind: .image)
        result += loadJobs(in: root.appendingPathComponent("Jobs"), kind: .video)
        result += loadJobs(in: root.appendingPathComponent("UpscaleJobs"), kind: .upscale)
        result += loadIntent(
            at: root.appendingPathComponent("image-submission-intent.json"),
            kind: .image
        )
        result += loadIntent(
            at: root.appendingPathComponent("submission-intent.json"),
            kind: .video
        )
        return Array(result.sorted { $0.updatedAt > $1.updatedAt }.prefix(max(0, limit)))
    }

    public static var hasActiveItems: Bool {
        items().contains(where: \.isActive)
    }

    private static func loadJobs(in directory: URL, kind: PaperwallWorkItem.Kind) -> [PaperwallWorkItem] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return urls.compactMap { parseJob(at: $0, kind: kind) }
    }

    private static func parseJob(at url: URL, kind: PaperwallWorkItem.Kind) -> PaperwallWorkItem? {
        guard url.pathExtension == "json",
              let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        let status = json["status"] as? String ?? "unknown"
        let prompt = (json["prompt"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = urlValue(json["sourceVideoURL"])
        let output = urlValue(json["outputLocalURL"]) ?? urlValue(json["outputVideoURL"])
        let title: String
        if let prompt, !prompt.isEmpty {
            title = prompt
        } else if let source {
            title = source.deletingPathExtension().lastPathComponent
        } else {
            title = kind.rawValue
        }
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        return PaperwallWorkItem(
            id: "\(kind.rawValue)-\(url.deletingPathExtension().lastPathComponent)",
            kind: kind,
            title: title,
            status: status,
            updatedAt: dateValue(json["updatedAt"]) ?? modified,
            outputURL: output
        )
    }

    private static func loadIntent(at url: URL, kind: PaperwallWorkItem.Kind) -> [PaperwallWorkItem] {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [] }
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
        let title = (json["prompt"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return [PaperwallWorkItem(
            id: "intent-\(kind.rawValue)",
            kind: kind,
            title: title?.isEmpty == false ? title! : kind.rawValue,
            status: "submitting",
            updatedAt: dateValue(json["createdAt"]) ?? modified,
            outputURL: nil
        )]
    }

    private static func dateValue(_ value: Any?) -> Date? {
        if let string = value as? String {
            return ISO8601DateFormatter().date(from: string)
        }
        guard let seconds = value as? Double else { return nil }
        return Date(timeIntervalSinceReferenceDate: seconds)
    }

    private static func urlValue(_ value: Any?) -> URL? {
        guard let string = value as? String else { return nil }
        return URL(string: string)
    }
}
