import CryptoKit
import Foundation

@MainActor
enum BundledComponentInstaller {
    private static var embeddedDirectory: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("Installer", isDirectory: true)
    }

    private static var cliDestination: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/bin/paperwall")
    }

    private static var saverDestination: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Screen Savers/Paperwall.saver", isDirectory: true)
    }

    static func installIfNeeded() throws {
        guard let embeddedDirectory else { throw ComponentInstallError.missingEmbeddedComponents }
        let cli = embeddedDirectory.appendingPathComponent("paperwall")
        let saver = embeddedDirectory.appendingPathComponent("Paperwall.saver", isDirectory: true)
        guard FileManager.default.isExecutableFile(atPath: cli.path),
              FileManager.default.fileExists(atPath: saver.path) else {
            throw ComponentInstallError.missingEmbeddedComponents
        }

        if try executableHash(cli) != executableHash(cliDestination) {
            try install(cli, at: cliDestination, executable: true)
        }
        let embeddedSaverExecutable = saver.appendingPathComponent("Contents/MacOS/Paperwall")
        let installedSaverExecutable = saverDestination.appendingPathComponent("Contents/MacOS/Paperwall")
        if try executableHash(embeddedSaverExecutable) != executableHash(installedSaverExecutable) {
            try install(saver, at: saverDestination, executable: false)
        }
    }

    private static func install(_ source: URL, at destination: URL, executable: Bool) throws {
        let fileManager = FileManager.default
        let parent = destination.deletingLastPathComponent()
        try assertSafeParentChain(parent)
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        let stage = parent.appendingPathComponent(".\(destination.lastPathComponent).stage-\(UUID().uuidString)")
        let backup = parent.appendingPathComponent(".\(destination.lastPathComponent).backup-\(UUID().uuidString)")
        defer {
            try? fileManager.removeItem(at: stage)
            try? fileManager.removeItem(at: backup)
        }

        try fileManager.copyItem(at: source, to: stage)
        if executable {
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stage.path)
        }
        let expected = try executableHash(
            executable ? source : source.appendingPathComponent("Contents/MacOS/Paperwall")
        )
        let staged = try executableHash(
            executable ? stage : stage.appendingPathComponent("Contents/MacOS/Paperwall")
        )
        guard expected == staged else { throw ComponentInstallError.verificationFailed }

        var backedUp = false
        if fileManager.fileExists(atPath: destination.path) || isSymbolicLink(destination) {
            try fileManager.moveItem(at: destination, to: backup)
            backedUp = true
        }
        do {
            try fileManager.moveItem(at: stage, to: destination)
        } catch {
            if backedUp, !fileManager.fileExists(atPath: destination.path) {
                try? fileManager.moveItem(at: backup, to: destination)
            }
            throw error
        }
    }

    private static func executableHash(_ url: URL) throws -> SHA256.Digest? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return SHA256.hash(data: try Data(contentsOf: url, options: [.mappedIfSafe]))
    }

    private static func assertSafeParentChain(_ parent: URL) throws {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        var current = parent.standardizedFileURL
        guard current.path == home.path || current.path.hasPrefix(home.path + "/") else {
            throw ComponentInstallError.unsafeDestination(parent)
        }
        while current.path != home.path {
            if isSymbolicLink(current) { throw ComponentInstallError.unsafeDestination(current) }
            current.deleteLastPathComponent()
        }
    }

    private static func isSymbolicLink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }
}

enum ComponentInstallError: Error, LocalizedError {
    case missingEmbeddedComponents
    case unsafeDestination(URL)
    case verificationFailed

    var errorDescription: String? {
        switch self {
        case .missingEmbeddedComponents:
            "This Paperwall build does not contain its CLI and screen saver components"
        case .unsafeDestination(let url):
            "Refusing an unsafe component destination: \(url.path)"
        case .verificationFailed:
            "An embedded component failed verification"
        }
    }
}
