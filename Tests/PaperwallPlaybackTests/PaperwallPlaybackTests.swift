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

@Test func predictionStatusRejectsUntrustedCredentialDestination() async {
    let transport = MockGenerationTransport([])
    let client = ReplicateClient(
        token: "test-token",
        transport: transport,
        retryDelaysNanoseconds: []
    )
    do {
        _ = try await client.fetchPrediction(
            url: URL(string: "https://example.com/steal-token")!
        )
        Issue.record("Expected an untrusted prediction URL to be rejected")
    } catch let error as GenerationError {
        #expect(error == .invalidResponse)
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
    #expect(await transport.calls() == 0)
}

@Test func defaultAssetLocation() {
    let configuration = PaperwallConfiguration()
    #expect(configuration.assetURL.path.hasSuffix(
        "/Library/Application Support/Paperwall/current.mov"
    ))
}

@Test func sharedMediaLocation() {
    #expect(PaperwallConfiguration.sharedDataDirectory.path.hasSuffix("/.config/paperwall"))
    #expect(PaperwallConfiguration.sharedImportsDirectory.path.hasSuffix(
        "/.config/paperwall/Library/Imports"
    ))
    #expect(PaperwallConfiguration.generationStateDirectory.path.contains(
        "/Library/Application Support/Paperwall/Generation"
    ))
}

@Test func wallpaperMetadataRoundTrips() throws {
    let metadata = WallpaperMetadata(
        id: "abc123",
        mediaRelativePath: "Library/Imports/forest.mp4",
        mediaKind: .video,
        title: "Quiet Forest",
        description: "Slow mist and subtle foliage movement.",
        tags: ["forest", "calm"],
        provenance: .imported,
        width: 3840,
        height: 2160,
        duration: 8,
        createdAt: Date(timeIntervalSince1970: 1_000_000),
        updatedAt: Date(timeIntervalSince1970: 1_000_000)
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    #expect(try decoder.decode(WallpaperMetadata.self, from: encoder.encode(metadata)) == metadata)
}

@Test func discoveryFindsOnlyImmediateWallpaperDirectoriesAndValidVideos() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let sourceDirectory = root
        .appendingPathComponent("UnrelatedCache", isDirectory: true)
        .appendingPathComponent("Wallpapers", isDirectory: true)
    let ignoredDirectory = root
        .appendingPathComponent("OtherCache", isDirectory: true)
        .appendingPathComponent("Previews", isDirectory: true)
    try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: ignoredDirectory, withIntermediateDirectories: true)
    let source = try fixtureURL("tiny-video", extension: "mp4")
    let discoveredURL = sourceDirectory.appendingPathComponent("quiet-scene.mp4")
    let ignoredURL = ignoredDirectory.appendingPathComponent("preview.mp4")
    try FileManager.default.copyItem(at: source, to: discoveredURL)
    try FileManager.default.copyItem(at: source, to: ignoredURL)

    let defaultDiscovery = await AssetLibrary.discoverCachedWallpapers(in: root)
    #expect(defaultDiscovery.isEmpty)
    let discovered = await AssetLibrary.discoverCachedWallpapers(
        in: root,
        minimumWidth: 64,
        minimumHeight: 36
    )

    #expect(discovered.count == 1)
    #expect(
        discovered.first?.url.resolvingSymlinksInPath().standardizedFileURL
            == discoveredURL.resolvingSymlinksInPath().standardizedFileURL
    )
    #expect(discovered.first?.title == "Quiet Scene")
    #expect(discovered.first?.id.count == 12)
}

@Test func legacyLibraryMigrationCopiesOnlyMediaNonDestructively() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let legacy = root.appendingPathComponent("Library/Previous", isDirectory: true)
    let imports = root.appendingPathComponent("Shared/Library/Imports", isDirectory: true)
    try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
    let source = legacy.appendingPathComponent("forest.mp4")
    try FileManager.default.copyItem(
        at: try fixtureURL("tiny-video", extension: "mp4"),
        to: source
    )
    try Data("legacy metadata".utf8).write(
        to: source.appendingPathExtension("paperwall.json")
    )

    try PaperwallStorageMigrator.migrateLibraryMedia(from: [legacy], to: imports)

    #expect(FileManager.default.fileExists(atPath: source.path))
    #expect(FileManager.default.fileExists(atPath: imports.appendingPathComponent("forest.mp4").path))
    #expect(!FileManager.default.fileExists(
        atPath: imports.appendingPathComponent("forest.mp4.paperwall.json").path
    ))
}

@Test func legacyLibraryCleanupRescuesOnlyUnsyncedMediaThenDeletes() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let legacy = root.appendingPathComponent("Legacy/Library", isDirectory: true)
    let shared = root.appendingPathComponent("Shared/Library", isDirectory: true)
    let imports = shared.appendingPathComponent("Imports", isDirectory: true)
    try FileManager.default.createDirectory(
        at: legacy.appendingPathComponent("Wallspace"), withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
        at: shared.appendingPathComponent("Wallspace"), withIntermediateDirectories: true
    )

    // Synced: identical bytes on both sides. Unsynced: exists only in legacy.
    // Stale name twin: same name as a shared file but different bytes.
    let video = try fixtureURL("tiny-video", extension: "mp4")
    for path in ["Legacy/Library/Wallspace/synced.mp4", "Shared/Library/Wallspace/synced.mp4"] {
        try FileManager.default.copyItem(at: video, to: root.appendingPathComponent(path))
    }
    try FileManager.default.copyItem(
        at: video, to: legacy.appendingPathComponent("Wallspace/unsynced.mp4")
    )
    try Data("different bytes".utf8).write(
        to: legacy.appendingPathComponent("Wallspace/twin.mp4")
    )
    try FileManager.default.copyItem(
        at: video, to: shared.appendingPathComponent("Wallspace/twin.mp4")
    )
    try Data("sidecar".utf8).write(
        to: legacy.appendingPathComponent("Wallspace/synced.mp4.paperwall.json")
    )

    try PaperwallStorageMigrator.removeLegacyLibrary(
        at: legacy, sharedLibrary: shared, rescueDestination: imports
    )

    #expect(!FileManager.default.fileExists(atPath: legacy.path))
    #expect(FileManager.default.fileExists(atPath: imports.appendingPathComponent("unsynced.mp4").path))
    #expect(FileManager.default.fileExists(atPath: imports.appendingPathComponent("twin.mp4").path))
    #expect(!FileManager.default.fileExists(atPath: imports.appendingPathComponent("synced.mp4").path))
    #expect(FileManager.default.fileExists(
        atPath: shared.appendingPathComponent("Wallspace/synced.mp4").path
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

@Test func libraryFirstFrameIsNativeResolutionJPEG() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let video = directory.appendingPathComponent("wallpaper.mp4")
    try FileManager.default.copyItem(
        at: fixtureURL("tiny-video", extension: "mp4"),
        to: video
    )

    try await FirstFrameExporter.exportLibraryFrameIfNeeded(for: video)

    let frame = FirstFrameExporter.frameURL(for: video)
    #expect(frame.lastPathComponent == "wallpaper.mp4.frame.jpg")
    let representation = try #require(NSBitmapImageRep(data: Data(contentsOf: frame)))
    #expect(representation.pixelsWide == 64)
    #expect(representation.pixelsHigh == 36)
}

@Test func frameBackfillSkipsExistingFrames() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let pending = root.appendingPathComponent("pending.mp4")
    try FileManager.default.copyItem(
        at: fixtureURL("tiny-video", extension: "mp4"),
        to: pending
    )
    let skipped = root.appendingPathComponent("skipped.mp4")
    try Data("not a video".utf8).write(to: skipped)
    let existingFrame = FirstFrameExporter.frameURL(for: skipped)
    let existingData = Data("existing frame".utf8)
    try existingData.write(to: existingFrame)
    let marker = root.appendingPathComponent("Markers/frame-backfill-v1.complete")

    let exported = try await PaperwallStorageMigrator.backfillFrames(
        in: root,
        markerURL: marker
    )

    #expect(exported == 1)
    #expect(FileManager.default.fileExists(
        atPath: FirstFrameExporter.frameURL(for: pending).path
    ))
    #expect(try Data(contentsOf: existingFrame) == existingData)
    #expect(FileManager.default.fileExists(atPath: marker.path))
    #expect(try await PaperwallStorageMigrator.backfillFrames(in: root, markerURL: marker) == 0)
}

@Test func catalogDiscoveryIgnoresFrameSidecars() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let video = root.appendingPathComponent("scene.mp4")
    try FileManager.default.copyItem(
        at: fixtureURL("tiny-video", extension: "mp4"),
        to: video
    )
    try Data("frame".utf8).write(to: FirstFrameExporter.frameURL(for: video))

    let discovered = await WallpaperCatalog().discoverMedia(in: root)

    #expect(discovered.map { $0.standardizedFileURL.resolvingSymlinksInPath() } == [
        video.standardizedFileURL.resolvingSymlinksInPath()
    ])
}

@Test func nativeWallpaperRecoveryRequiresRecentUnresolvedInvalidation() {
    let transition = Date(timeIntervalSince1970: 1_000)
    let surfaceID = UUID().uuidString
    let invalidated = NativeWallpaperRecoveryHealth(
        pendingInvalidations: [surfaceID: 1_005]
    )
    #expect(NativeWallpaperRecovery.shouldRecover(
        health: invalidated,
        transitionStartedAt: transition,
        now: Date(timeIntervalSince1970: 1_007)
    ))

    let reacquired = NativeWallpaperRecoveryHealth()
    #expect(!NativeWallpaperRecovery.shouldRecover(
        health: reacquired,
        transitionStartedAt: transition,
        now: Date(timeIntervalSince1970: 1_007)
    ))
}

@Test func nativeWallpaperRecoveryTracksSurfacesIndependently() {
    let staleSurface = UUID().uuidString
    let otherSurface = UUID().uuidString
    let expected: [String: TimeInterval] = [staleSurface: 1_005, otherSurface: 1_006]
    let health = NativeWallpaperRecoveryHealth(
        pendingInvalidations: [staleSurface: 1_005]
    )

    #expect(NativeWallpaperRecovery.unresolvedInvalidations(
        in: health,
        expected: expected
    ) == [staleSurface: 1_005])
}

@Test func nativeWallpaperRecoveryRejectsOldInvalidations() {
    let stale = NativeWallpaperRecoveryHealth(
        pendingInvalidations: [UUID().uuidString: 900]
    )
    #expect(!NativeWallpaperRecovery.shouldRecover(
        health: stale,
        transitionStartedAt: Date(timeIntervalSince1970: 1_000),
        now: Date(timeIntervalSince1970: 1_007)
    ))
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
