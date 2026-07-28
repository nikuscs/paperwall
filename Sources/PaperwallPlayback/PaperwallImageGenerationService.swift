import Darwin
import Foundation

public struct ImageGenerationQuote: Equatable, Sendable {
    public let modelName: String
    public let estimatedMaximumCostUSD: Decimal

    public var formattedCost: String {
        String(format: "$%.2f", NSDecimalNumber(decimal: estimatedMaximumCostUSD).doubleValue)
    }
}

public struct ImageGenerationResult: Sendable {
    public let predictionID: String
    public let imageURL: URL
    public let resumedExistingJob: Bool
}

public enum PaperwallImageGenerationService {
    public typealias ProgressHandler = @Sendable (String) -> Void

    public static let modelName = "FLUX 1.1 Pro"
    private static let modelID = "black-forest-labs/flux-1.1-pro"

    private static var generationDirectory: URL {
        PaperwallConfiguration.generationStateDirectory
    }

    private static var jobsDirectory: URL {
        generationDirectory.appendingPathComponent("ImageJobs", isDirectory: true)
    }

    private static var imagesDirectory: URL {
        PaperwallConfiguration.sharedGenerationDirectory
            .appendingPathComponent("Images", isDirectory: true)
    }

    private static var intentURL: URL {
        generationDirectory.appendingPathComponent("image-submission-intent.json")
    }

    public static func pendingPrompt() -> String? {
        try? latestPendingJob()?.prompt
    }

    public static func quote(prompt: String) throws -> ImageGenerationQuote {
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GenerationError.missingInput
        }
        return ImageGenerationQuote(
            modelName: modelName,
            estimatedMaximumCostUSD: Decimal(string: "0.04")!
        )
    }

    public static func generate(
        prompt: String,
        token: String,
        timeout: TimeInterval = 600,
        progress: @escaping ProgressHandler = { _ in }
    ) async throws -> ImageGenerationResult {
        let prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try quote(prompt: prompt)
        try createDirectories()

        let lockURL = generationDirectory.appendingPathComponent("image-generation.lock")
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw GenerationError.generationAlreadyRunning }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            throw GenerationError.generationAlreadyRunning
        }
        defer {
            _ = flock(descriptor, LOCK_UN)
            close(descriptor)
        }

        let client = ReplicateClient(token: token)
        if let pending = try latestPendingJob() {
            try? FileManager.default.removeItem(at: intentURL)
            progress("Resuming image prediction \(pending.predictionID) without a new paid request")
            return try await resume(
                job: pending,
                client: client,
                timeout: timeout,
                resumed: true,
                progress: progress
            )
        }
        guard !FileManager.default.fileExists(atPath: intentURL.path) else {
            throw GenerationError.unresolvedSubmission
        }

        try saveIntent(prompt: prompt)
        progress("Submitting one paid \(modelName) image prediction")
        let prediction: ReplicatePrediction
        do {
            prediction = try await client.submit(
                modelID: modelID,
                input: [
                    "prompt": .string(prompt),
                    "aspect_ratio": .string("16:9"),
                    "output_format": .string("png"),
                    "prompt_upsampling": .bool(false),
                    "safety_tolerance": .number(2),
                ]
            )
        } catch let error as GenerationError {
            if case .api = error { try? FileManager.default.removeItem(at: intentURL) }
            throw error
        }
        guard let predictionURL = prediction.urls.get else {
            throw GenerationError.invalidResponse
        }

        var job = ImageGenerationJob(
            predictionID: prediction.id,
            predictionURL: predictionURL,
            prompt: prompt,
            status: prediction.status,
            outputRemoteURL: prediction.output?.outputURL,
            outputLocalURL: nil,
            createdAt: Date(),
            updatedAt: Date()
        )
        try save(job)
        try FileManager.default.removeItem(at: intentURL)
        if prediction.status == "succeeded" {
            job.outputRemoteURL = try outputURL(from: prediction)
            try save(job)
        }
        return try await resume(
            job: job,
            client: client,
            timeout: timeout,
            resumed: false,
            progress: progress
        )
    }

    private static func resume(
        job original: ImageGenerationJob,
        client: ReplicateClient,
        timeout: TimeInterval,
        resumed: Bool,
        progress: @escaping ProgressHandler
    ) async throws -> ImageGenerationResult {
        var job = original
        if let local = job.outputLocalURL, FileManager.default.fileExists(atPath: local.path) {
            return ImageGenerationResult(
                predictionID: job.predictionID,
                imageURL: local,
                resumedExistingJob: true
            )
        }

        let deadline = Date().addingTimeInterval(timeout)
        var remoteOutput = job.outputRemoteURL
        while remoteOutput == nil {
            guard Date() < deadline else { throw GenerationError.predictionTimedOut }
            let prediction = try await client.fetchPrediction(url: job.predictionURL)
            job.status = prediction.status
            job.updatedAt = Date()
            job.outputRemoteURL = prediction.output?.outputURL
            try save(job)
            switch prediction.status {
            case "succeeded": remoteOutput = try outputURL(from: prediction)
            case "failed": throw GenerationError.predictionFailed(prediction.error ?? "No error detail")
            case "canceled": throw GenerationError.predictionCanceled
            default:
                progress("Image prediction \(prediction.id): \(prediction.status)")
                try await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }

        guard let remoteOutput else { throw GenerationError.missingOutput }
        progress("Downloading generated image")
        let local = try await download(remoteOutput, predictionID: job.predictionID)
        _ = try? await WallpaperCatalog.shared.enrich(
            mediaURL: local,
            description: job.prompt,
            tags: ["generated", "source-image", "flux-1.1-pro"],
            provenance: .generated
        )
        job.outputRemoteURL = remoteOutput
        job.outputLocalURL = local
        job.status = "ready"
        job.updatedAt = Date()
        try save(job)
        return ImageGenerationResult(
            predictionID: job.predictionID,
            imageURL: local,
            resumedExistingJob: resumed
        )
    }

    private static func createDirectories() throws {
        try PaperwallStorageMigrator.migrateSynchronouslyIfNeeded()
        for directory in [jobsDirectory, imagesDirectory] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    private static func latestPendingJob() throws -> ImageGenerationJob? {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: jobsDirectory,
            includingPropertiesForKeys: nil
        )) ?? []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try urls.compactMap { url -> ImageGenerationJob? in
            let job = try decoder.decode(ImageGenerationJob.self, from: Data(contentsOf: url))
            return ["starting", "processing"].contains(job.status) ? job : nil
        }.max { $0.updatedAt < $1.updatedAt }
    }

    private static func saveIntent(prompt: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(ImageGenerationIntent(prompt: prompt, createdAt: Date()))
            .write(to: intentURL, options: .atomic)
    }

    private static func save(_ job: ImageGenerationJob) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(job).write(
            to: jobsDirectory.appendingPathComponent(job.predictionID).appendingPathExtension("json"),
            options: .atomic
        )
    }

    private static func outputURL(from prediction: ReplicatePrediction) throws -> URL {
        guard let url = prediction.output?.outputURL else { throw GenerationError.missingOutput }
        return url
    }

    private static func download(_ remoteURL: URL, predictionID: String) async throws -> URL {
        let destination = imagesDirectory
            .appendingPathComponent("flux-\(predictionID)")
            .appendingPathExtension("png")
        if FileManager.default.fileExists(atPath: destination.path) { return destination }

        var lastError: Error?
        for attempt in 0..<3 {
            do {
                var request = URLRequest(url: remoteURL, timeoutInterval: 300)
                request.setValue("paperwall/1", forHTTPHeaderField: "User-Agent")
                let (temporary, response) = try await URLSession.shared.download(for: request)
                guard let http = response as? HTTPURLResponse,
                      (200...299).contains(http.statusCode) else {
                    throw GenerationError.downloadFailed
                }
                try FileManager.default.moveItem(at: temporary, to: destination)
                return destination
            } catch {
                lastError = error
                if attempt < 2 { try await Task.sleep(nanoseconds: UInt64(500_000_000 * (1 << attempt))) }
            }
        }
        _ = lastError
        throw GenerationError.downloadFailed
    }
}

private struct ImageGenerationIntent: Codable {
    let prompt: String
    let createdAt: Date
}

private struct ImageGenerationJob: Codable {
    let predictionID: String
    let predictionURL: URL
    let prompt: String
    var status: String
    var outputRemoteURL: URL?
    var outputLocalURL: URL?
    let createdAt: Date
    var updatedAt: Date
}
