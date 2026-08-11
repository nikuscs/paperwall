import CryptoKit
import Darwin
import Foundation

public struct UpscaleResult: Sendable {
    public let sourceVideoURL: URL
    public let upscaledVideoURL: URL
    public let resumedExistingOutput: Bool
}

public enum UpscaleError: Error, LocalizedError {
    case missingTool
    case missingInstaller
    case installationFailed(String)
    case processFailed(String)
    case invalidOutput
    case alreadyRunning

    public var errorDescription: String? {
        switch self {
        case .missingTool:
            "The free 4K upscaler is unavailable after setup"
        case .missingInstaller:
            "Paperwall's 4K setup component is missing. Reinstall Paperwall and retry."
        case .installationFailed(let detail):
            "Could not install the free 4K upscaler: \(detail)"
        case .processFailed(let detail):
            "4K upscaling failed: \(detail)"
        case .invalidOutput:
            "The upscaler did not produce a valid 4K video"
        case .alreadyRunning:
            "Another Paperwall upscale is already running"
        }
    }
}

public enum PaperwallUpscaleService {
    private static let toolInstaller = UpscalerToolInstaller()
    private static let pinnedVEnhanceRevision = "2fe41cad6bc32e7d7168689f242282b3b9d4e819"
    private static let dependencyCutoff = "2026-07-28T00:00:00Z"

    private struct Job: Codable {
        let sourceVideoURL: URL
        let outputVideoURL: URL
        var status: String
        var detail: String?
        let createdAt: Date
        var updatedAt: Date
    }

    private static var generationDirectory: URL {
        PaperwallConfiguration.generationStateDirectory
    }

    private static var outputsDirectory: URL {
        PaperwallConfiguration.sharedGenerationDirectory
            .appendingPathComponent("Upscaled", isDirectory: true)
    }

    private static var jobsDirectory: URL {
        generationDirectory.appendingPathComponent("UpscaleJobs", isDirectory: true)
    }

    public static func ensureToolInstalled() async throws {
        try await toolInstaller.ensureInstalled()
    }

    public static func latestResumableVideoURL() -> URL? {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: jobsDirectory,
            includingPropertiesForKeys: nil
        )) ?? []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return urls.compactMap { url -> Job? in
            guard let data = try? Data(contentsOf: url),
                  let job = try? decoder.decode(Job.self, from: data),
                  ["processing", "failed"].contains(job.status),
                  FileManager.default.fileExists(atPath: job.sourceVideoURL.path) else {
                return nil
            }
            return job
        }
        .max { $0.updatedAt < $1.updatedAt }?
        .sourceVideoURL
    }

    public static func upscaleTo4K(videoURL: URL) async throws -> UpscaleResult {
        let sourceInfo = try await VideoAssetValidator.validate(url: videoURL)
        if sourceInfo.width >= 3_840, sourceInfo.height >= 2_160 {
            return UpscaleResult(
                sourceVideoURL: videoURL,
                upscaledVideoURL: videoURL,
                resumedExistingOutput: true
            )
        }
        try await ensureToolInstalled()
        try await PaperwallStorageMigrator.migrateLegacySharedAssetsIfNeeded()
        try FileManager.default.createDirectory(at: outputsDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: jobsDirectory, withIntermediateDirectories: true)

        let digest = SHA256.hash(data: try Data(contentsOf: videoURL, options: [.mappedIfSafe]))
            .map { String(format: "%02x", $0) }
            .joined()
        let jobID = String(digest.prefix(16))
        let outputURL = outputsDirectory
            .appendingPathComponent("\(videoURL.deletingPathExtension().lastPathComponent)-4k-\(jobID)")
            .appendingPathExtension("mp4")
        let jobURL = jobsDirectory.appendingPathComponent(jobID).appendingPathExtension("json")

        if FileManager.default.fileExists(atPath: outputURL.path),
           let info = try? await VideoAssetValidator.validate(url: outputURL),
           info.width >= 3_840, info.height >= 2_160 {
            try await FirstFrameExporter.exportLibraryFrameIfNeeded(for: outputURL)
            return UpscaleResult(
                sourceVideoURL: videoURL,
                upscaledVideoURL: outputURL,
                resumedExistingOutput: true
            )
        }

        let lockURL = generationDirectory.appendingPathComponent("upscale.lock")
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw UpscaleError.alreadyRunning }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            throw UpscaleError.alreadyRunning
        }
        defer {
            _ = flock(descriptor, LOCK_UN)
            close(descriptor)
        }

        guard let executable = venhanceExecutableURL() else { throw UpscaleError.missingTool }
        let stageURL = outputsDirectory
            .appendingPathComponent(".\(jobID)-partial")
            .appendingPathExtension("mp4")
        try? FileManager.default.removeItem(at: stageURL)

        var job = Job(
            sourceVideoURL: videoURL,
            outputVideoURL: outputURL,
            status: "processing",
            detail: nil,
            createdAt: Date(),
            updatedAt: Date()
        )
        try save(job, to: jobURL)

        do {
            let logURL = jobsDirectory.appendingPathComponent("\(jobID).log")
            let terminationStatus = try await runUpscaler(
                executable: executable,
                input: videoURL,
                output: stageURL,
                logURL: logURL
            )
            guard terminationStatus == 0 else {
                let detail = (try? String(contentsOf: logURL, encoding: .utf8).suffix(2_000))
                    .map(String.init) ?? "process exited with status \(terminationStatus)"
                throw UpscaleError.processFailed(detail)
            }
            let info = try await VideoAssetValidator.validate(url: stageURL)
            guard info.width >= 3_840, info.height >= 2_160 else {
                throw UpscaleError.invalidOutput
            }
            try? FileManager.default.removeItem(at: FirstFrameExporter.frameURL(for: outputURL))
            try? FileManager.default.removeItem(at: outputURL)
            try FileManager.default.moveItem(at: stageURL, to: outputURL)
            try await FirstFrameExporter.exportLibraryFrameIfNeeded(for: outputURL)
            let sourceMetadata = try? await WallpaperCatalog.shared.metadata(for: videoURL)
            _ = try? await WallpaperCatalog.shared.enrich(
                mediaURL: outputURL,
                description: sourceMetadata?.description ?? "Paperwall 4K upscale.",
                tags: (sourceMetadata?.tags ?? []) + ["upscaled", "4k"],
                provenance: .upscaled,
                sourceWallpaperID: sourceMetadata?.id
            )
            job.status = "completed"
            job.updatedAt = Date()
            try save(job, to: jobURL)
            return UpscaleResult(
                sourceVideoURL: videoURL,
                upscaledVideoURL: outputURL,
                resumedExistingOutput: false
            )
        } catch {
            try? FileManager.default.removeItem(at: stageURL)
            job.status = "failed"
            job.detail = error.localizedDescription
            job.updatedAt = Date()
            try? save(job, to: jobURL)
            throw error
        }
    }

    fileprivate static func venhanceExecutableURL() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            home.appendingPathComponent(".local/bin/venhance"),
            URL(fileURLWithPath: "/opt/homebrew/bin/venhance"),
            URL(fileURLWithPath: "/usr/local/bin/venhance"),
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    fileprivate static func uvExecutableURL() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let bundled = Bundle.main.resourceURL?
            .appendingPathComponent("Tools/uv")
        let candidates = [
            bundled,
            Optional(home.appendingPathComponent(".local/bin/uv")),
            Optional(URL(fileURLWithPath: "/opt/homebrew/bin/uv")),
            Optional(URL(fileURLWithPath: "/usr/local/bin/uv")),
        ]
        return candidates.compactMap { $0 }.first {
            FileManager.default.isExecutableFile(atPath: $0.path)
        }
    }

    fileprivate static func installVEnhance(using uv: URL) async throws -> Int32 {
        let dependencies = generationDirectory.appendingPathComponent("Dependencies", isDirectory: true)
        try FileManager.default.createDirectory(at: dependencies, withIntermediateDirectories: true)
        let logURL = dependencies.appendingPathComponent("venhance-install.log")
        return try await Task.detached(priority: .utility) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
            let log = try FileHandle(forWritingTo: logURL)
            defer { try? log.close() }

            let process = Process()
            process.executableURL = uv
            process.environment = childProcessEnvironment()
            process.arguments = [
                "tool", "install",
                "git+https://github.com/TomPenguin/venhance.git@\(pinnedVEnhanceRevision)",
                "--with", "numpy==2.5.1",
                "--with", "rich==15.0.0",
                "--with", "torch==2.13.0",
                "--with", "typer==0.27.0",
                "--exclude-newer", dependencyCutoff,
                "--force",
            ]
            process.standardOutput = log
            process.standardError = log
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        }.value
    }

    fileprivate static func installationLogTail() -> String {
        let url = generationDirectory
            .appendingPathComponent("Dependencies/venhance-install.log")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return "uv exited without diagnostic output"
        }
        return String(text.suffix(2_000))
    }

    private static func runUpscaler(
        executable: URL,
        input: URL,
        output: URL,
        logURL: URL
    ) async throws -> Int32 {
        try await Task.detached(priority: .utility) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
            let log = try FileHandle(forWritingTo: logURL)
            defer { try? log.close() }

            let process = Process()
            process.executableURL = executable
            process.environment = childProcessEnvironment()
            process.arguments = [
                "upscale", input.path,
                "--scale", "2",
                "--model", "realesr-anime",
                "--codec", "h264",
                "--quality", "80",
                "--device", "mps",
                "--output", output.path,
            ]
            process.standardOutput = log
            process.standardError = log
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        }.value
    }

    private static func childProcessEnvironment() -> [String: String] {
        ProcessInfo.processInfo.environment.filter { key, _ in
            let key = key.uppercased()
            return !key.contains("TOKEN")
                && !key.contains("PASSWORD")
                && !key.contains("SECRET")
                && !key.hasSuffix("_KEY")
                && !key.contains("PRIVATE_KEY")
        }
    }

    private static func save(_ job: Job, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(job).write(to: url, options: .atomic)
    }
}

private actor UpscalerToolInstaller {
    func ensureInstalled() async throws {
        if PaperwallUpscaleService.venhanceExecutableURL() != nil { return }
        guard let uv = PaperwallUpscaleService.uvExecutableURL() else {
            throw UpscaleError.missingInstaller
        }
        let status = try await PaperwallUpscaleService.installVEnhance(using: uv)
        guard status == 0 else {
            throw UpscaleError.installationFailed(
                PaperwallUpscaleService.installationLogTail()
            )
        }
        guard PaperwallUpscaleService.venhanceExecutableURL() != nil else {
            throw UpscaleError.missingTool
        }
    }
}
