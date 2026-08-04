import Foundation
import Testing
@testable import NotesToWebKit

/// The token template URL is the whole of the "make setup less intimidating" fix, so it is
/// checked by decoding the query back into values rather than by matching an encoded string:
/// percent-encoding has several legal spellings and none of them are the thing under test.
@Suite("Cloudflare token template URL")
struct CloudflareTokenTemplateTests {

    private func query(_ url: URL) -> [String: String] {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        return Dictionary(
            (components?.queryItems ?? []).map { ($0.name, $0.value ?? "") },
            uniquingKeysWith: { first, _ in first }
        )
    }

    @Test("Opens the user token form on the Cloudflare dashboard")
    func opensTokenForm() throws {
        let url = CloudflarePublisher.tokenTemplateURL
        #expect(url.host() == "dash.cloudflare.com")
        #expect(url.path() == "/profile/api-tokens")
    }

    @Test("Asks for exactly the permissions publishing needs")
    func permissions() throws {
        let raw = try #require(query(CloudflarePublisher.tokenTemplateURL)["permissionGroupKeys"])
        let decoded = try JSONDecoder().decode(
            [CloudflarePublisher.TokenPermission].self, from: Data(raw.utf8)
        )
        #expect(decoded == [
            CloudflarePublisher.TokenPermission(key: "workers_scripts", type: "edit"),
            CloudflarePublisher.TokenPermission(key: "account_settings", type: "read"),
        ])
    }

    @Test("Scopes the form to every account and zone, which the dashboard requires")
    func scope() throws {
        let items = query(CloudflarePublisher.tokenTemplateURL)
        #expect(items["accountId"] == "*")
        #expect(items["zoneId"] == "all")
    }

    @Test("Names the token so a user can tell later which app asked for it")
    func name() throws {
        #expect(query(CloudflarePublisher.tokenTemplateURL)["name"] == "Notes to Web")
    }

    @Test("The permission JSON is encoded as a query value, not left to break the URL")
    func encoding() throws {
        // A raw `[{"key":…}]` in a query string is what a hand-built URL gets wrong, and the
        // failure is silent: URL(string:) returns nil and the button quietly disappears.
        let raw = CloudflarePublisher.tokenTemplateURL.absoluteString
        #expect(!raw.contains("{"))
        #expect(!raw.contains("\""))
    }
}
