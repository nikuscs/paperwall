import Foundation

public enum PaperwallPlayback {
    public static var applicationSupportDirectory: URL {
        PaperwallConfiguration.applicationSupportDirectory
    }

    public static var defaultAssetURL: URL {
        PaperwallConfiguration.defaultAssetURL
    }
}
