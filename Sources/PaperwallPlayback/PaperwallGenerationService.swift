import CryptoKit
import Darwin
import Foundation
import ImageIO

public enum PaperwallGenerationService {
    public typealias ApprovalHandler = @Sendable (GenerationQuote) async -> Bool
    public typealias ProgressHandler = @Sendable (String) -> Void

    private static let defaultPrompt =
        "Create extremely slow, subtle ambient motion suitable for a calm seamless wallpaper. " +
        "Keep the camera completely fixed and preserve the composition, geometry, colors, and style."
    private static let constraints =
        "Motion must be minimal and tranquil, approximately quarter-speed, with tiny displacement only. " +
        "Seamless loop; fixed camera; no fast movement, zoom, pan, parallax, flicker, exposure shift, text, " +
        "watermark, duplicated subjects, geometry deformation, or style drift. " +
        "Only mist, water, clouds, light, or foliage may move gently; return silently to the first-frame composition."

    private static var generationDirectory: URL {
        PaperwallConfiguration.generationStateDirectory
    }

    private static var sourcesDirectory: URL {
        PaperwallConfiguration.sharedGenerationDirectory
            .appendingPathComponent("Sources", isDirectory: true)
    }

    private static var jobsDirectory: URL {
        generationDirectory.appendingPathComponent("Jobs", isDirectory: true)
    }

    private static var outputsDirectory: URL {
        PaperwallConfiguration.sharedGenerationDirectory
            .appendingPathComponent("Outputs", isDirectory: true)
    }

    private static var submissionIntentURL: URL {
        generationDirectory.appendingPathComponent("submission-intent.json")
    }

    public static func pendingRequest() -> GenerationRequest? {
        guard let job = try? latestPendingJob() else { return nil }
        return GenerationRequest(
            provider: job.provider,
            prompt: job.prompt,
            imageURL: job.referenceImageURL,
            duration: job.duration,
            seed: job.seed
        )
    }

    public static func quote(for request: GenerationRequest) throws -> GenerationQuote {
        try validate(request)
        return GenerationQuote(
            provider: request.provider,
            duration: request.duration,
            resolution: "1080p",
            estimatedMaximumCostUSD: request.provider.pricePerSecondUSD * Decimal(request.duration)
        )
    }

    public static func generateAndSelect(
        request: GenerationRequest,
        token: String,
        timeout: TimeInterval = 1_200,
        approve: ApprovalHandler,
        progress: @escaping ProgressHandler = { _ in }
    ) async throws -> GenerationResult {
        try createDirectories()
        let lockURL = generationDirectory.appendingPathComponent("generation.lock")
        let lockDescriptor = open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard lockDescriptor >= 0 else { throw GenerationError.generationAlreadyRunning }
        guard flock(lockDescriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(lockDescriptor)
            throw GenerationError.generationAlreadyRunning
        }
        defer {
            _ = flock(lockDescriptor, LOCK_UN)
            close(lockDescriptor)
        }

        let client = ReplicateClient(token: token)
        if let pending = try latestPendingJob() {
            try? FileManager.default.removeItem(at: submissionIntentURL)
            progress("Resuming Replicate prediction \(pending.predictionID) without a new paid request")
            return try await resume(
                job: pending,
                client: client,
                timeout: timeout,
                resumed: true,
                progress: progress
            )
        }
        guard !FileManager.default.fileExists(atPath: submissionIntentURL.path) else {
            throw GenerationError.unresolvedSubmission
        }

        let quote = try quote(for: request)
        guard await approve(quote) else { throw GenerationError.approvalDeclined }
        let prepared = try preserveReferenceImage(in: request)
        let input = try modelInput(for: prepared)
        try saveIntent(for: prepared)
        progress("Submitting one paid \(request.provider.displayName) prediction")
        let prediction: ReplicatePrediction
        do {
            prediction = try await client.submit(modelID: request.provider.modelID, input: input)
        } catch let error as GenerationError {
            if case .api = error {
                try? FileManager.default.removeItem(at: submissionIntentURL)
            }
            throw error
        }
        guard let getURL = prediction.urls.get else { throw GenerationError.invalidResponse }

        var job = GenerationJob(
            predictionID: prediction.id,
            predictionURL: getURL,
            provider: prepared.provider,
            prompt: composedPrompt(prepared.prompt),
            referenceImageURL: prepared.imageURL,
            duration: prepared.duration,
            seed: prepared.seed,
            status: prediction.status,
            outputRemoteURL: prediction.output?.outputURL,
            outputLocalURL: nil,
            createdAt: Date(),
            updatedAt: Date()
        )
        try save(job)
        try FileManager.default.removeItem(at: submissionIntentURL)
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
        job original: GenerationJob,
        client: ReplicateClient,
        timeout: TimeInterval,
        resumed: Bool,
        progress: @escaping ProgressHandler
    ) async throws -> GenerationResult {
        var job = original
        if let local = job.outputLocalURL, FileManager.default.fileExists(atPath: local.path) {
            progress("Installing previously downloaded generation")
            try await FirstFrameExporter.exportLibraryFrameIfNeeded(for: local)
            _ = try await PaperwallService.selectWallpaper(from: local)
            job.status = "installed"
            job.updatedAt = Date()
            try save(job)
            return GenerationResult(
                provider: job.provider,
                predictionID: job.predictionID,
                generatedVideoURL: local,
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
                progress("Prediction \(prediction.id): \(prediction.status)")
                try await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }

        guard let remoteOutput else { throw GenerationError.missingOutput }
        progress("Downloading generated video")
        let output = try await download(
            remoteOutput,
            provider: job.provider,
            predictionID: job.predictionID
        )
        _ = try await VideoAssetValidator.validate(url: output)
        try await FirstFrameExporter.exportLibraryFrameIfNeeded(for: output)
        _ = try? await WallpaperCatalog.shared.enrich(
            mediaURL: output,
            description: job.prompt,
            tags: ["generated", job.provider.rawValue],
            provenance: .generated
        )
        job.outputRemoteURL = remoteOutput
        job.outputLocalURL = output
        job.status = "downloaded"
        job.updatedAt = Date()
        try save(job)

        progress("Installing generated wallpaper")
        _ = try await PaperwallService.selectWallpaper(from: output)
        job.status = "installed"
        job.updatedAt = Date()
        try save(job)
        return GenerationResult(
            provider: job.provider,
            predictionID: job.predictionID,
            generatedVideoURL: output,
            resumedExistingJob: resumed
        )
    }

    private static func validate(_ request: GenerationRequest) throws {
        let prompt = request.prompt?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !(prompt?.isEmpty ?? true) || request.imageURL != nil else {
            throw GenerationError.missingInput
        }
        guard request.provider.validDuration.contains(request.duration) else {
            throw GenerationError.invalidDuration(provider: request.provider, duration: request.duration)
        }
        guard (0...2_147_483_637).contains(request.seed) else { throw GenerationError.invalidSeed }
        if let image = request.imageURL {
            guard FileManager.default.fileExists(atPath: image.path) else {
                throw GenerationError.missingImage(image)
            }
            guard ["png", "jpg", "jpeg", "webp"].contains(image.pathExtension.lowercased()),
                  let data = try? Data(contentsOf: image, options: [.mappedIfSafe]),
                  CGImageSourceCreateWithData(data as CFData, nil) != nil else {
                throw GenerationError.invalidImage(image)
            }
        }
    }

    private static func preserveReferenceImage(in request: GenerationRequest) throws -> GenerationRequest {
        guard let source = request.imageURL else { return request }
        let sourceData = try Data(contentsOf: source, options: [.mappedIfSafe])
        guard CGImageSourceCreateWithData(sourceData as CFData, nil) != nil,
              ["png", "jpg", "jpeg", "webp"].contains(source.pathExtension.lowercased()) else {
            throw GenerationError.invalidImage(source)
        }
        let digest = SHA256.hash(data: sourceData).map { String(format: "%02x", $0) }.joined()
        let ext = source.pathExtension.lowercased() == "jpeg" ? "jpg" : source.pathExtension.lowercased()
        let destination = sourcesDirectory
            .appendingPathComponent("\(source.deletingPathExtension().lastPathComponent)-\(digest.prefix(12))")
            .appendingPathExtension(ext)
        if FileManager.default.fileExists(atPath: destination.path) {
            let existing = try Data(contentsOf: destination, options: [.mappedIfSafe])
            guard SHA256.hash(data: existing) == SHA256.hash(data: sourceData) else {
                throw GenerationError.invalidImage(source)
            }
        } else {
            try sourceData.write(to: destination, options: .atomic)
        }
        return GenerationRequest(
            provider: request.provider,
            prompt: request.prompt,
            imageURL: destination,
            duration: request.duration,
            seed: request.seed
        )
    }

    static func modelInput(for request: GenerationRequest) throws -> [String: JSONValue] {
        var input: [String: JSONValue] = [
            "prompt": .string(composedPrompt(request.prompt)),
            "duration": .number(Double(request.duration)),
            "seed": .number(Double(request.seed)),
            "resolution": .string("1080p"),
        ]
        if let image = request.imageURL {
            let uri = try imageDataURI(image)
            input["image"] = .string(uri)
            input["last_frame_image"] = .string(uri)
        }
        switch request.provider {
        case .pruna:
            input["fps"] = .number(24)
            input["draft"] = .bool(true)
            input["save_audio"] = .bool(false)
            input["prompt_upsampling"] = .bool(false)
            input["aspect_ratio"] = .string("16:9")
        case .seedance15:
            input["fps"] = .number(24)
            input["camera_fixed"] = .bool(true)
            input["generate_audio"] = .bool(false)
            input["aspect_ratio"] = .string("16:9")
        case .seedance20:
            input["generate_audio"] = .bool(false)
            input["aspect_ratio"] = .string("16:9")
        }
        return input
    }

    private static func composedPrompt(_ prompt: String?) -> String {
        let base = prompt?.trimmingCharacters(in: .whitespacesAndNewlines)
        return "\((base?.isEmpty == false ? base : defaultPrompt)!) \(constraints)"
    }

    private static func imageDataURI(_ url: URL) throws -> String {
        let mime: String
        switch url.pathExtension.lowercased() {
        case "png": mime = "image/png"
        case "webp": mime = "image/webp"
        default: mime = "image/jpeg"
        }
        return "data:\(mime);base64,\(try Data(contentsOf: url).base64EncodedString())"
    }

    private static func outputURL(from prediction: ReplicatePrediction) throws -> URL {
        guard let url = prediction.output?.outputURL else { throw GenerationError.missingOutput }
        return url
    }

    private static func download(
        _ remoteURL: URL,
        provider: GenerationProvider,
        predictionID: String
    ) async throws -> URL {
        let safeID = predictionID.replacingOccurrences(
            of: "[^A-Za-z0-9_-]",
            with: "-",
            options: .regularExpression
        )
        let destination = outputsDirectory
            .appendingPathComponent("\(provider.rawValue)-\(safeID)")
            .appendingPathExtension("mp4")
        if FileManager.default.fileExists(atPath: destination.path) {
            do {
                _ = try await VideoAssetValidator.validate(url: destination)
                return destination
            } catch {
                try? FileManager.default.removeItem(
                    at: FirstFrameExporter.frameURL(for: destination)
                )
                try FileManager.default.removeItem(at: destination)
            }
        }

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

    private static func createDirectories() throws {
        try PaperwallStorageMigrator.migrateSynchronouslyIfNeeded()
        for directory in [sourcesDirectory, jobsDirectory, outputsDirectory] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    private static func latestPendingJob() throws -> GenerationJob? {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: jobsDirectory,
            includingPropertiesForKeys: nil
        )) ?? []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try urls.compactMap { url -> GenerationJob? in
            let job = try decoder.decode(GenerationJob.self, from: Data(contentsOf: url))
            return ["starting", "processing", "downloaded"].contains(job.status) ? job : nil
        }.max { $0.updatedAt < $1.updatedAt }
    }

    private static func saveIntent(for request: GenerationRequest) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let intent = GenerationIntent(
            provider: request.provider,
            prompt: request.prompt,
            referenceImageURL: request.imageURL,
            duration: request.duration,
            seed: request.seed,
            createdAt: Date()
        )
        try encoder.encode(intent).write(to: submissionIntentURL, options: .atomic)
    }

    private static func save(_ job: GenerationJob) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let url = jobsDirectory.appendingPathComponent(job.predictionID).appendingPathExtension("json")
        try encoder.encode(job).write(to: url, options: .atomic)
    }
}

private struct GenerationIntent: Codable {
    let provider: GenerationProvider
    let prompt: String?
    let referenceImageURL: URL?
    let duration: Int
    let seed: Int
    let createdAt: Date
}

private struct GenerationJob: Codable {
    let predictionID: String
    let predictionURL: URL
    let provider: GenerationProvider
    let prompt: String
    let referenceImageURL: URL?
    let duration: Int
    let seed: Int
    var status: String
    var outputRemoteURL: URL?
    var outputLocalURL: URL?
    let createdAt: Date
    var updatedAt: Date
}
