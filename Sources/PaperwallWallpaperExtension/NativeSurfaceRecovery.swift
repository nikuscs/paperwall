import Foundation
import os

/// Tracks live surfaces that WallpaperAgent invalidated without replacing. Each surface is
/// independent: a Settings preview or another Space acquiring must not hide a stale desktop
/// surface. The app inspects this state only during lock/wake transitions.
enum NativeSurfaceRecovery {
    private struct Health: Codable {
        var pendingInvalidations: [String: TimeInterval]
    }

    static let surfaceInvalidatedNotification = "com.paperwall.wallpaper.surfaceInvalidated"

    private static var healthURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            .appendingPathComponent("recovery-health.json")
    }

    private static let state = OSAllocatedUnfairLock(
        initialState: loadPersistedInvalidations()
    )

    static func recordAcquire(surfaceID: UUID) {
        let snapshot = state.withLock { pending -> [String: TimeInterval] in
            pending.removeValue(forKey: surfaceID.uuidString)
            return pending
        }
        persist(snapshot)
    }

    static func recordLiveInvalidation(surfaceID: UUID) {
        let snapshot = state.withLock { pending -> [String: TimeInterval] in
            pending[surfaceID.uuidString] = Date().timeIntervalSince1970
            return pending
        }
        guard persist(snapshot) else { return }
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(surfaceInvalidatedNotification as CFString),
            nil, nil, true,
        )
    }

    private static func loadPersistedInvalidations() -> [String: TimeInterval] {
        guard let data = try? Data(contentsOf: healthURL),
              let health = try? JSONDecoder().decode(Health.self, from: data)
        else { return [:] }
        return health.pendingInvalidations
    }

    @discardableResult
    private static func persist(_ pendingInvalidations: [String: TimeInterval]) -> Bool {
        guard let data = try? JSONEncoder().encode(Health(
            pendingInvalidations: pendingInvalidations
        )) else { return false }
        do {
            try data.write(to: healthURL, options: .atomic)
            return true
        } catch {
            extensionLog("  [recovery] Could not persist surface health: \(error)")
            return false
        }
    }
}
