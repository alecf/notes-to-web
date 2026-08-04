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
        _accountID = defaults.string(forKey: Key.accountID) ?? ""
        _accountName = defaults.string(forKey: Key.accountName) ?? ""
        _lastSite = defaults.string(forKey: Key.lastSite)
        _workersSubdomain = defaults.string(forKey: Key.workersSubdomain) ?? ""
        _usesOAuth = defaults.bool(forKey: Key.usesOAuth)
    }

    private enum Key {
        static let compressVideo = "video.compress"
        static let quality = "video.quality"
        static let codec = "video.codec"
        static let enforceSizeBudget = "video.enforceSizeBudget"
        static let siteRootPath = "export.defaultFolder"
        static let providerID = "publish.providerID"
        // Discovered from the token rather than typed, but still worth remembering
        // so the app does not re-interrogate Cloudflare on every launch.
        static let accountID = "publish.accountID"
        static let accountName = "publish.accountName"
        static let lastSite = "publish.lastSite"
        static let workersSubdomain = "publish.workersSubdomain"
        // Which half of the credential story this account was connected with. Without it,
        // a user holding both a pasted token and a browser sign-in gets whichever the
        // lookup order happens to find, which is not necessarily the one they chose.
        static let usesOAuth = "publish.usesOAuth"
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

    // MARK: Sites

    /// The folder holding every site, one subfolder each.
    private var _siteRootPath: String?
    var defaultExportFolder: URL? {
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

    private var _accountID: String
    var accountID: String {
        get { _accountID }
        set { _accountID = newValue; defaults.set(newValue, forKey: Key.accountID) }
    }

    private var _accountName: String
    var accountName: String {
        get { _accountName }
        set { _accountName = newValue; defaults.set(newValue, forKey: Key.accountName) }
    }

    /// The site the last export went to, so the picker defaults somewhere sensible.
    private var _lastSite: String?
    var lastSite: String? {
        get { _lastSite }
        set { _lastSite = newValue; defaults.set(newValue, forKey: Key.lastSite) }
    }

    /// The account's workers.dev subdomain, so the export sheet can show the
    /// real address before publishing rather than a placeholder.
    private var _workersSubdomain: String
    var workersSubdomain: String {
        get { _workersSubdomain.isEmpty ? "workers.dev" : "\(_workersSubdomain).workers.dev" }
        set {
            _workersSubdomain = newValue
            defaults.set(newValue, forKey: Key.workersSubdomain)
        }
    }

    var isConnected: Bool { !accountID.isEmpty }

    /// True when the connection came from a browser sign-in rather than a pasted token.
    private var _usesOAuth: Bool
    var usesOAuth: Bool {
        get { _usesOAuth }
        set { _usesOAuth = newValue; defaults.set(newValue, forKey: Key.usesOAuth) }
    }
}
