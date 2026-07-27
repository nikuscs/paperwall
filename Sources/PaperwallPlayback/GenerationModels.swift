import Foundation

public enum GenerationProvider: String, CaseIterable, Codable, Sendable {
    case pruna
    case seedance15 = "seedance-1.5"
    case seedance20 = "seedance-2.0"

    public init(alias: String) throws {
        switch alias.lowercased() {
        case "pruna", "prune", "p-video", "pvideo": self = .pruna
        case "seedance-1.5", "seedance-1.5-pro", "seedance15": self = .seedance15
        case "seedance-2.0", "seedance20": self = .seedance20
        default: throw GenerationError.unknownProvider(alias)
        }
    }

    public var modelID: String {
        switch self {
        case .pruna: "prunaai/p-video"
        case .seedance15: "bytedance/seedance-1.5-pro"
        case .seedance20: "bytedance/seedance-2.0"
        }
    }

    public var displayName: String {
        switch self {
        case .pruna: "Pruna P-Video Draft"
        case .seedance15: "Seedance 1.5 Pro"
        case .seedance20: "Seedance 2.0"
        }
    }

    var pricePerSecondUSD: Decimal {
        switch self {
        case .pruna: Decimal(string: "0.01")!
        case .seedance15: Decimal(string: "0.058")!
        case .seedance20: Decimal(string: "0.45")!
        }
    }

    var validDuration: ClosedRange<Int> {
        switch self {
        case .pruna: 1...20
        case .seedance15: 2...12
        case .seedance20: 1...15
        }
    }
}

public struct GenerationRequest: Codable, Equatable, Sendable {
    public let provider: GenerationProvider
    public let prompt: String?
    public let imageURL: URL?
    public let duration: Int
    public let seed: Int

    public init(
        provider: GenerationProvider = .pruna,
        prompt: String? = nil,
        imageURL: URL? = nil,
        duration: Int = 4,
        seed: Int = Int.random(in: 0...2_147_483_637)
    ) {
        self.provider = provider
        self.prompt = prompt?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.imageURL = imageURL
        self.duration = duration
        self.seed = seed
    }
}

public struct GenerationQuote: Equatable, Sendable {
    public let provider: GenerationProvider
    public let duration: Int
    public let resolution: String
    public let estimatedMaximumCostUSD: Decimal

    public var formattedCost: String {
        let number = NSDecimalNumber(decimal: estimatedMaximumCostUSD)
        return String(format: "$%.2f", number.doubleValue)
    }

    public var approvalPhrase: String {
        "GENERATE \(provider.rawValue) FOR \(formattedCost)"
    }
}

public struct GenerationResult: Sendable {
    public let provider: GenerationProvider
    public let predictionID: String
    public let generatedVideoURL: URL
    public let resumedExistingJob: Bool
}

public enum GenerationError: Error, LocalizedError, Equatable {
    case unknownProvider(String)
    case missingInput
    case invalidDuration(provider: GenerationProvider, duration: Int)
    case invalidSeed
    case missingImage(URL)
    case invalidImage(URL)
    case missingToken
    case generationAlreadyRunning
    case approvalDeclined
    case unresolvedSubmission
    case submissionOutcomeUnknown
    case invalidResponse
    case api(status: Int, detail: String)
    case predictionFailed(String)
    case predictionCanceled
    case predictionTimedOut
    case missingOutput
    case downloadFailed

    public var errorDescription: String? {
        switch self {
        case .unknownProvider(let alias): "Unknown provider alias: \(alias)"
        case .missingInput: "Provide a prompt, an image, or both"
        case .invalidDuration(let provider, let duration):
            "Duration \(duration)s is invalid for \(provider.rawValue)"
        case .invalidSeed: "Seed must be between 0 and 2147483637"
        case .missingImage(let url): "Reference image does not exist: \(url.path)"
        case .invalidImage(let url): "Reference image is not a valid PNG, JPEG, or WebP file: \(url.path)"
        case .missingToken: "REPLICATE_API_TOKEN is unavailable; configure it in the Paperwall UI"
        case .generationAlreadyRunning: "Another Paperwall generation is already running"
        case .approvalDeclined: "Generation was not approved; no paid request was made"
        case .unresolvedSubmission:
            "A previous paid submission has an unknown outcome. Check Replicate billing, then remove Generation/submission-intent.json only after confirming whether it ran"
        case .submissionOutcomeUnknown:
            "The submission response was lost, so Paperwall will not retry and risk duplicate charges"
        case .invalidResponse: "Replicate returned an invalid response"
        case .api(let status, let detail): "Replicate returned HTTP \(status): \(detail)"
        case .predictionFailed(let detail): "Generation failed: \(detail)"
        case .predictionCanceled: "Generation was canceled"
        case .predictionTimedOut: "Generation timed out; the saved job can resume without a new paid request"
        case .missingOutput: "Replicate completed without a video output"
        case .downloadFailed: "Generated video could not be downloaded"
        }
    }
}
