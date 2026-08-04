import Foundation
import NotesToWebKit
import Observation

/// Everything the app remembers between launches. Secrets are deliberately not
/// here — those live in the Keychain via `CredentialStore`. This holds only
/// non-sensitive settings, which is why plain `UserDefaults` is fine.
@MainActor
@Observable
final class Preferences {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        _compressVideo = defaults.object(forKey: Key.compressVideo) as? Bool ?? true
        _quality = VideoQuality(rawValue: defaults.string(forKey: Key.quality) ?? "") ?? .balanced
        _codec = VideoCodec(rawValue: defaults.string(forKey: Key.codec) ?? "") ?? .h264
        _enforceSizeBudget = defaults.object(forKey: Key.enforceSizeBudget) as? Bool ?? true
        _siteRootPath = defaults.string(forKey: Key.siteRootPath)
        _providerID = defaults.string(forKey: Key.providerID)
        _cloudflareAccountID = defaults.string(forKey: Key.cloudflareAccountID) ?? ""
        _cloudflareProjectName = defaults.string(forKey: Key.cloudflareProjectName) ?? ""
    }

    private enum Key {
        static let compressVideo = "video.compress"
        static let quality = "video.quality"
        static let codec = "video.codec"
        static let enforceSizeBudget = "video.enforceSizeBudget"
        static let siteRootPath = "site.rootPath"
        static let providerID = "publish.providerID"
        static let cloudflareAccountID = "publish.cloudflare.accountID"
        static let cloudflareProjectName = "publish.cloudflare.projectName"
    }

    // MARK: Video

    private var _compressVideo: Bool
    var compressVideo: Bool {
        get { _compressVideo }
        set { _compressVideo = newValue; defaults.set(newValue, forKey: Key.compressVideo) }
    }

    private var _quality: VideoQuality
    var quality: VideoQuality {
        get { _quality }
        set { _quality = newValue; defaults.set(newValue.rawValue, forKey: Key.quality) }
    }

    private var _codec: VideoCodec
    var codec: VideoCodec {
        get { _codec }
        set { _codec = newValue; defaults.set(newValue.rawValue, forKey: Key.codec) }
    }

    /// Cap every video at the host's per-file limit. Off means "encode at the
    /// quality I picked and let the files land where they land".
    private var _enforceSizeBudget: Bool
    var enforceSizeBudget: Bool {
        get { _enforceSizeBudget }
        set { _enforceSizeBudget = newValue; defaults.set(newValue, forKey: Key.enforceSizeBudget) }
    }

    // MARK: Site

    private var _siteRootPath: String?
    var siteRoot: URL? {
        get { _siteRootPath.map { URL(filePath: $0, directoryHint: .isDirectory) } }
        set {
            _siteRootPath = newValue?.path(percentEncoded: false)
            defaults.set(_siteRootPath, forKey: Key.siteRootPath)
        }
    }

    // MARK: Publishing

    private var _providerID: String?
    var providerID: String? {
        get { _providerID }
        set { _providerID = newValue; defaults.set(newValue, forKey: Key.providerID) }
    }

    private var _cloudflareAccountID: String
    var cloudflareAccountID: String {
        get { _cloudflareAccountID }
        set { _cloudflareAccountID = newValue; defaults.set(newValue, forKey: Key.cloudflareAccountID) }
    }

    private var _cloudflareProjectName: String
    var cloudflareProjectName: String {
        get { _cloudflareProjectName }
        set { _cloudflareProjectName = newValue; defaults.set(newValue, forKey: Key.cloudflareProjectName) }
    }
}
