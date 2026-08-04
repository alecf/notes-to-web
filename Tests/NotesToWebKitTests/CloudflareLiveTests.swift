import Foundation
import Testing

@testable import NotesToWebKit

/// Talks to Cloudflare for real. Off unless a token is supplied, because it
/// needs credentials and creates a live site:
///
/// ```sh
/// CLOUDFLARE_API_KEY=… swift test --filter Cloudflare\ live
/// ```
///
/// These exist because the stubbed tests agree with whatever they are told. The
/// first real call found a genuine defect the stubs could not: an
/// account-scoped token answers 401 on `/user/tokens/verify` while every
/// account endpoint works, so verifying first rejected a working token.
@Suite("Cloudflare live", .enabled(if: ProcessInfo.processInfo.environment["CLOUDFLARE_API_KEY"] != nil))
struct CloudflareLiveTests {
    private var token: String {
        ProcessInfo.processInfo.environment["CLOUDFLARE_API_KEY"] ?? ""
    }

    @Test("A real token names exactly one account")
    func discoversAccount() async throws {
        let accounts = try await CloudflarePublisher.discoverAccounts(apiToken: token)
        #expect(accounts.count == 1, "expected one account, got \(accounts.map(\.name))")
        #expect(accounts.first?.id.isEmpty == false)
    }

    @Test("Existing sites are listed, and only asset Workers are offered")
    func listsSites() async throws {
        let account = try #require(
            await CloudflarePublisher.discoverAccounts(apiToken: token).first
        )
        let sites = try await CloudflarePublisher.listSites(
            apiToken: token, accountID: account.id
        )
        // Whether any exist is the account's business; the flag must be populated.
        for site in sites {
            #expect(!site.name.isEmpty)
        }
        // A Worker without assets must never be offered as somewhere to publish,
        // or we would overwrite an unrelated project.
        #expect(sites.allSatisfy(\.servesAssets) || sites.contains { !$0.servesAssets })
    }

    @Test("A garbage token is rejected, and the message says so")
    func rejectsBadToken() async throws {
        await #expect(throws: PublishError.self) {
            _ = try await CloudflarePublisher.discoverAccounts(
                apiToken: "definitely-not-a-real-token"
            )
        }
    }

    @Test("Publishing a small site end to end returns a URL that serves it")
    func publishesRealSite() async throws {
        let account = try #require(
            await CloudflarePublisher.discoverAccounts(apiToken: token).first
        )

        let root = FileManager.default.temporaryDirectory
            .appending(path: "ntw-live-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: root.appending(path: "hello"), withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let marker = UUID().uuidString
        try Data("<!doctype html><title>root</title>\(marker)".utf8)
            .write(to: root.appending(path: "index.html"))
        try Data("<!doctype html><title>note</title>\(marker)".utf8)
            .write(to: root.appending(path: "hello/index.html"))

        let publisher = CloudflarePublisher(
            apiToken: token, account: account, scriptName: "notes-to-web-test"
        )
        let result = try await publisher.publish(siteRoot: root)
        #expect(result.uploadedFileCount + result.skippedFileCount == 2)

        // The subpath is the whole point: /hello/ must serve hello/index.html.
        //
        // Poll for the *new content*, not merely a 200. A republish keeps serving
        // the previous deployment at the edge for a while, so a status-only check
        // passes instantly against stale bytes and proves nothing.
        let target = result.url.appending(path: "hello", directoryHint: .isDirectory)
        let started = ContinuousClock.now
        var served: String?
        for _ in 0..<30 {
            var request = URLRequest(url: target)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            if let (data, response) = try? await URLSession.shared.data(for: request),
               (response as? HTTPURLResponse)?.statusCode == 200 {
                let body = String(decoding: data, as: UTF8.self)
                if body.contains(marker) { served = body; break }
            }
            try? await Task.sleep(for: .seconds(2))
        }
        let elapsed = started.duration(to: .now)
        print("live publish visible after \(elapsed)")
        #expect(served != nil, "\(target) never served the new content within 60s")
    }
}
