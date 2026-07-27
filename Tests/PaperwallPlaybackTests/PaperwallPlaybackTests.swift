import AppKit
import AVFoundation
import Foundation
import Testing
@testable import PaperwallPlayback

private final class FixtureMarker: NSObject {}

private actor MockGenerationTransport: GenerationHTTPTransport {
    enum Reply: Sendable {
        case failure(URLError.Code)
        case response(status: Int, data: Data)
    }

    private var replies: [Reply]
    private var callCount = 0

    init(_ replies: [Reply]) {
        self.replies = replies
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        callCount += 1
        let reply = replies.removeFirst()
        switch reply {
        case .failure(let code):
            throw URLError(code)
        case .response(let status, let data):
            let response = try #require(HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: nil,
                headerFields: nil
            ))
            return (data, response)
        }
    }

    func calls() -> Int { callCount }
}

private func fixtureURL(_ name: String, extension ext: String) throws -> URL {
    try #require(Bundle(for: FixtureMarker.self).url(forResource: name, withExtension: ext))
}

@Test func generationProviderAliasesAndQuotes() throws {
    #expect(try GenerationProvider(alias: "seedance-1.5-pro") == .seedance15)
    #expect(try GenerationProvider(alias: "seedance-2.0") == .seedance20)
    #expect(GenerationProvider.availableCases == [.seedance15, .seedance20])
    #expect(GenerationRequest(prompt: "waves").provider == .seedance15)
    #expect(throws: GenerationError.unknownProvider("pruna")) {
        try GenerationProvider(alias: "pruna")
    }

    let seedance15 = try PaperwallGenerationService.quote(for: GenerationRequest(
        provider: .seedance15,
        prompt: "waves",
        duration: 4,
        seed: 1
    ))
    let seedance20 = try PaperwallGenerationService.quote(for: GenerationRequest(
        provider: .seedance20,
        prompt: "waves",
        duration: 4,
        seed: 1
    ))
    #expect(seedance15.formattedCost == "$0.23")
    #expect(seedance20.formattedCost == "$1.80")

    let image = try PaperwallImageGenerationService.quote(prompt: "emerald anime valley")
    #expect(image.modelName == "FLUX 1.1 Pro")
    #expect(image.formattedCost == "$0.04")
    #expect(throws: GenerationError.missingInput) {
        try PaperwallImageGenerationService.quote(prompt: "   ")
    }
}

@Test func providersEmitWallpaperSafeModelInputs() throws {
    let seedance15 = try PaperwallGenerationService.modelInput(for: GenerationRequest(
        provider: .seedance15,
        prompt: "waves",
        duration: 4,
        seed: 1
    ))
    let seedance20 = try PaperwallGenerationService.modelInput(for: GenerationRequest(
        provider: .seedance20,
        prompt: "waves",
        duration: 4,
        seed: 1
    ))

    #expect(seedance15["camera_fixed"] == .bool(true))
    #expect(seedance15["generate_audio"] == .bool(false))
    if case .string(let prompt) = seedance15["prompt"] {
        #expect(prompt.contains("quarter-speed"))
        #expect(prompt.contains("tiny displacement"))
    } else {
        Issue.record("Seedance prompt was not emitted")
    }
    #expect(seedance20["generate_audio"] == .bool(false))
    #expect(seedance20["fps"] == nil)
}

@Test func paidSubmissionIsNeverRetriedAfterTransportFailure() async {
    let transport = MockGenerationTransport([
        .failure(.timedOut),
        .response(status: 200, data: Data())
    ])
    let client = ReplicateClient(
        token: "test-token",
        transport: transport,
        retryDelaysNanoseconds: [0, 0]
    )
    do {
        _ = try await client.submit(modelID: "owner/model", input: ["prompt": .string("test")])
        Issue.record("Expected ambiguous submission failure")
    } catch let error as GenerationError {
        #expect(error == .submissionOutcomeUnknown)
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
    #expect(await transport.calls() == 1)
}

@Test func paidSubmissionHTTPFailureIsNotRetried() async {
    let transport = MockGenerationTransport([
        .response(status: 500, data: Data("provider unavailable".utf8)),
        .response(status: 200, data: Data())
    ])
    let client = ReplicateClient(
        token: "test-token",
        transport: transport,
        retryDelaysNanoseconds: [0, 0]
    )
    do {
        _ = try await client.submit(modelID: "owner/model", input: ["prompt": .string("test")])
        Issue.record("Expected API failure")
    } catch let error as GenerationError {
        guard case .api(let status, _) = error else {
            Issue.record("Unexpected generation error: \(error)")
            return
        }
        #expect(status == 500)
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
    #expect(await transport.calls() == 1)
}

@Test func predictionStatusReadsRetryTransientFailures() async throws {
    let prediction = Data("""
    {"id":"job-1","status":"processing","output":null,"error":null,
     "urls":{"get":"https://api.replicate.com/v1/predictions/job-1","web":null}}
    """.utf8)
    let transport = MockGenerationTransport([
        .response(status: 500, data: Data("temporary".utf8)),
        .response(status: 429, data: Data("rate limited".utf8)),
        .response(status: 200, data: prediction)
    ])
    let client = ReplicateClient(
        token: "test-token",
        transport: transport,
        retryDelaysNanoseconds: [0, 0]
    )
    let result = try await client.fetchPrediction(
        url: URL(string: "https://api.replicate.com/v1/predictions/job-1")!
    )
    #expect(result.id == "job-1")
    #expect(await transport.calls() == 3)
}

@Test func defaultAssetLocation() {
    let configuration = PaperwallConfiguration()
    #expect(configuration.assetURL.path.hasSuffix(
        "/Library/Application Support/Paperwall/current.mov"
    ))
}

@Test func sharedMediaLocation() {
    #expect(PaperwallConfiguration.sharedDataDirectory.path.hasSuffix("/.config/paperwall"))
    #expect(PaperwallConfiguration.sharedLibraryDirectory.path.hasSuffix(
        "/.config/paperwall/Library/Wallspace"
    ))
    #expect(PaperwallConfiguration.generationStateDirectory.path.contains(
        "/Library/Application Support/Paperwall/Generation"
    ))
}

@Test func customAssetLocation() {
    let url = URL(fileURLWithPath: "/tmp/custom-paperwall.mov")
    #expect(PaperwallConfiguration(assetURL: url).assetURL == url)
}

@Test func missingAssetIsRejected() async {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension("mov")
    do {
        _ = try await VideoAssetValidator.validate(url: url)
        Issue.record("Expected missing asset validation to fail")
    } catch let error as VideoAssetValidationError {
        #expect(error == .missing(url))
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
}

@Test func invalidAssetIsRejected() async throws {
    let url = try fixtureURL("invalid-video", extension: "mov")
    await #expect(throws: (any Error).self) {
        _ = try await VideoAssetValidator.validate(url: url)
    }
}

@Test func videoDimensionsAreLoaded() async throws {
    let info = try await VideoAssetValidator.validate(
        url: fixtureURL("tiny-video", extension: "mp4")
    )
    #expect(info.width == 64)
    #expect(info.height == 36)
    #expect(info.duration >= 0.9)
}

@MainActor
@Test func staticPosterIsGeneratedFromVideo() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let poster = directory.appendingPathComponent("fallback.jpg")

    try await StaticWallpaperManager.generatePoster(
        for: fixtureURL("tiny-video", extension: "mp4"),
        to: poster
    )

    let representation = try #require(NSBitmapImageRep(data: Data(contentsOf: poster)))
    #expect(representation.pixelsWide == 64)
    #expect(representation.pixelsHigh == 36)
}

@MainActor
@Test func loopingPlayerTearsDownDeterministically() throws {
    let player = LoopingPlayer(assetURL: try fixtureURL("tiny-video", extension: "mp4"))
    #expect(player.isPrepared)

    for _ in 0..<3 {
        player.start()
        player.stop()
    }

    player.tearDown()
    #expect(!player.isPrepared)
    #expect(player.player.items().isEmpty)
}
