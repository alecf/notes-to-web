import Foundation
import Testing
@testable import NotesToWebKit

// MARK: Routing stub

/// Replies based on method and path, and keeps every request for inspection.
/// Shared with `CloudflareDiscoveryTests`.
actor RoutingTransport {
    typealias Route = @Sendable (URLRequest) -> (Int, String)?

    private let routes: [Route]
    private(set) var requests: [(method: String, url: URL, body: Data)] = []

    init(routes: [Route]) { self.routes = routes }

    func handle(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        requests.append((request.httpMethod ?? "", request.url!, request.httpBody ?? Data()))
        for route in routes {
            if let (status, body) = route(request) {
                return (
                    Data(body.utf8),
                    HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
                )
            }
        }
        return (
            Data(#"{"success":false,"errors":[{"code":0,"message":"unrouted"}]}"#.utf8),
            HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!
        )
    }

    func api() -> CloudflareAPI {
        CloudflareAPI(
            token: "token",
            retryPolicy: RetryPolicy(maxAttempts: 2, initialDelay: 0),
            executor: { [self] request in try await handle(request) },
            sleeper: { _ in }
        )
    }

    func request(_ method: String, matching fragment: String) -> (method: String, url: URL, body: Data)? {
        requests.first { $0.method == method && $0.url.absoluteString.contains(fragment) }
    }

    var paths: [String] { requests.map { "\($0.method) \($0.url.path)" } }
}

func route(_ method: String, _ fragment: String, _ body: String, status: Int = 200) -> RoutingTransport.Route {
    { request in
        guard request.httpMethod == method, request.url!.absoluteString.contains(fragment) else { return nil }
        return (status, body)
    }
}

private func makeSite() throws -> URL {
    let root = URL(filePath: NSTemporaryDirectory())
        .appending(path: "notes-to-web-publish-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
        at: root.appending(path: "assets"), withIntermediateDirectories: true
    )
    try Data("<!doctype html><title>Hi</title>\n".utf8)
        .write(to: root.appending(path: "index.html"))
    try Data("body{}".utf8).write(to: root.appending(path: "assets/style.css"))
    try Data("pretend movie".utf8).write(to: root.appending(path: "assets/clip.mp4"))
    return root
}

private func file(_ path: String, size: Int64) -> SiteFile {
    SiteFile(
        path: path,
        localURL: URL(filePath: "/dev/null"),
        hash: String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(32)).lowercased(),
        size: size,
        contentType: "application/octet-stream"
    )
}

// MARK: Tests

@Suite("Cloudflare publisher")
struct CloudflarePublisherTests {

    @Test("A whole publish run hits the documented endpoints in order and returns the site URL")
    func fullRun() async throws {
        let root = try makeSite()
        defer { try? FileManager.default.removeItem(at: root) }

        let manifest = try SiteManifest.build(root: root, pathPrefix: "workout-1")
        let wanted = manifest.files.filter { $0.path != "/workout-1/assets/style.css" }.map(\.hash)

        let transport = RoutingTransport(routes: [
            route("POST", "assets-upload-session", """
            {"success":true,"errors":null,"result":{"jwt":"session-jwt","buckets":[["\(wanted[0])","\(wanted[1])"]]}}
            """),
            route("POST", "workers/assets/upload", #"{"success":true,"result":{"jwt":"completion-jwt"}}"#),
            route("POST", "scripts/alecs-notes/subdomain", #"{"success":true,"result":{"enabled":true}}"#),
            route("PUT", "workers/scripts/alecs-notes", #"{"success":true,"result":{"id":"alecs-notes"}}"#),
            route("GET", "workers/subdomain", #"{"success":true,"result":{"subdomain":"alecf"}}"#),
        ])

        let publisher = CloudflarePublisher(
            api: await transport.api(),
            accountID: "acct123",
            scriptName: "alecs-notes",
            pathPrefix: "workout-1"
        )

        let result = try await publisher.publish(siteRoot: root, progress: { _ in })

        #expect(result.url.absoluteString == "https://alecs-notes.alecf.workers.dev/workout-1/")
        #expect(result.uploadedFileCount == 2)
        #expect(result.skippedFileCount == 1)
        #expect(result.warnings.isEmpty)
        #expect(await transport.paths == [
            "POST /client/v4/accounts/acct123/workers/scripts/alecs-notes/assets-upload-session",
            "POST /client/v4/accounts/acct123/workers/assets/upload",
            "PUT /client/v4/accounts/acct123/workers/scripts/alecs-notes",
            "POST /client/v4/accounts/acct123/workers/scripts/alecs-notes/subdomain",
            "GET /client/v4/accounts/acct123/workers/subdomain",
        ])
    }

    @Test("The upload session posts the documented manifest shape")
    func manifestBody() async throws {
        let root = try makeSite()
        defer { try? FileManager.default.removeItem(at: root) }

        let transport = RoutingTransport(routes: [
            route("POST", "assets-upload-session", #"{"success":true,"result":{"jwt":"j","buckets":[]}}"#),
            route("PUT", "workers/scripts/site", #"{"success":true,"result":{}}"#),
            route("POST", "subdomain", #"{"success":true,"result":{"enabled":true}}"#),
            route("GET", "workers/subdomain", #"{"success":true,"result":{"subdomain":"alecf"}}"#),
        ])
        let publisher = CloudflarePublisher(
            api: await transport.api(), accountID: "acct", scriptName: "site"
        )
        _ = try await publisher.publish(siteRoot: root, progress: { _ in })

        let sent = try #require(await transport.request("POST", matching: "assets-upload-session"))
        let json = try JSONSerialization.jsonObject(with: sent.body) as? [String: Any]
        let entries = try #require(json?["manifest"] as? [String: [String: Any]])
        #expect(Set(entries.keys) == ["/index.html", "/assets/style.css", "/assets/clip.mp4"])
        let index = try #require(entries["/index.html"])
        #expect(index["hash"] as? String == "924c3bc4b1b97972f6620ed497a7159c")
        #expect(index["size"] as? Int == 33)
    }

    @Test("Assets upload as base64 parts named for their hash, under the session JWT")
    func uploadRequest() async throws {
        let root = try makeSite()
        defer { try? FileManager.default.removeItem(at: root) }

        let manifest = try SiteManifest.build(root: root)
        let cssHash = try #require(manifest.files.first { $0.path == "/assets/style.css" }?.hash)

        let transport = RoutingTransport(routes: [
            route("POST", "assets-upload-session", """
            {"success":true,"result":{"jwt":"session-jwt","buckets":[["\(cssHash)"]]}}
            """),
            route("POST", "workers/assets/upload", #"{"success":true,"result":{"jwt":"done"}}"#),
            route("PUT", "workers/scripts/site", #"{"success":true,"result":{}}"#),
            route("POST", "subdomain", #"{"success":true,"result":{"enabled":true}}"#),
            route("GET", "workers/subdomain", #"{"success":true,"result":{"subdomain":"alecf"}}"#),
        ])
        let publisher = CloudflarePublisher(
            api: await transport.api(), accountID: "acct", scriptName: "site"
        )
        _ = try await publisher.publish(siteRoot: root, progress: { _ in })

        let upload = try #require(await transport.request("POST", matching: "workers/assets/upload"))
        #expect(upload.url.query == "base64=true")
        let body = String(decoding: upload.body, as: UTF8.self)
        #expect(body.contains("name=\"\(cssHash)\"; filename=\"\(cssHash)\""))
        #expect(body.contains("Content-Type: text/css"))
        // "body{}" base64-encoded — the endpoint refuses raw bytes.
        #expect(body.contains(Data("body{}".utf8).base64EncodedString()))
    }

    @Test("Deployment metadata is assets-only with directory-index handling")
    func deployMetadata() async throws {
        let root = try makeSite()
        defer { try? FileManager.default.removeItem(at: root) }

        let transport = RoutingTransport(routes: [
            route("POST", "assets-upload-session", #"{"success":true,"result":{"jwt":"session-jwt","buckets":[]}}"#),
            route("PUT", "workers/scripts/site", #"{"success":true,"result":{}}"#),
            route("POST", "subdomain", #"{"success":true,"result":{"enabled":true}}"#),
            route("GET", "workers/subdomain", #"{"success":true,"result":{"subdomain":"alecf"}}"#),
        ])
        let publisher = CloudflarePublisher(
            api: await transport.api(), accountID: "acct", scriptName: "site"
        )
        _ = try await publisher.publish(siteRoot: root, progress: { _ in })

        let put = try #require(await transport.request("PUT", matching: "workers/scripts/site"))
        let body = String(decoding: put.body, as: UTF8.self)
        #expect(body.contains("name=\"metadata\""))
        #expect(body.contains("Content-Type: application/json"))
        #expect(!body.contains("main_module"))
        #expect(body.contains("\"html_handling\":\"auto-trailing-slash\""))
        #expect(body.contains("\"not_found_handling\":\"none\""))
        // Nothing was uploaded, so the session JWT stands in for a completion token.
        #expect(body.contains("\"jwt\":\"session-jwt\""))

        let toggle = try #require(await transport.request("POST", matching: "scripts/site/subdomain"))
        #expect(String(decoding: toggle.body, as: UTF8.self) == #"{"enabled":true}"#)
    }

    @Test("Progress is reported in bytes, monotonically, ending at 1")
    func progressIsByteBased() async throws {
        let root = try makeSite()
        defer { try? FileManager.default.removeItem(at: root) }

        let manifest = try SiteManifest.build(root: root)
        let hashes = manifest.files.map(\.hash)
        let transport = RoutingTransport(routes: [
            route("POST", "assets-upload-session", """
            {"success":true,"result":{"jwt":"j","buckets":[["\(hashes[0])"],["\(hashes[1])"],["\(hashes[2])"]]}}
            """),
            route("POST", "workers/assets/upload", #"{"success":true,"result":{"jwt":"done"}}"#),
            route("PUT", "workers/scripts/site", #"{"success":true,"result":{}}"#),
            route("POST", "subdomain", #"{"success":true,"result":{"enabled":true}}"#),
            route("GET", "workers/subdomain", #"{"success":true,"result":{"subdomain":"alecf"}}"#),
        ])
        let publisher = CloudflarePublisher(
            api: await transport.api(), accountID: "acct", scriptName: "site"
        )

        let recorder = ProgressRecorder()
        _ = try await publisher.publish(siteRoot: root, progress: { recorder.add($0) })

        let steps = recorder.steps
        #expect(steps.map(\.fraction) == steps.map(\.fraction).sorted())
        #expect(steps.last?.fraction == 1)
        #expect(steps.contains { $0.totalBytes == manifest.totalByteCount })
        #expect(steps.last?.message == "Published")
    }

    @Test("An oversized file is refused by name and size before anything is uploaded")
    func oversizedFilePreflight() async throws {
        let root = URL(filePath: NSTemporaryDirectory())
            .appending(path: "notes-to-web-big-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("<!doctype html>".utf8).write(to: root.appending(path: "index.html"))
        try Data(count: 26 * 1024 * 1024).write(to: root.appending(path: "clip.mp4"))

        let transport = RoutingTransport(routes: [])
        let publisher = CloudflarePublisher(
            api: await transport.api(), accountID: "acct", scriptName: "site"
        )

        await #expect(throws: PublishError.self) {
            _ = try await publisher.publish(siteRoot: root, progress: { _ in })
        }
        // Nothing may go out before the refusal.
        #expect(await transport.requests.isEmpty)

        let error = PublishError.fileTooLarge(
            path: "/clip.mp4", size: 26 * 1024 * 1024, limit: 25 * 1024 * 1024,
            provider: CloudflarePublisher.displayName
        )
        let text = try #require(error.errorDescription)
        #expect(text.contains("/clip.mp4"))
        #expect(text.contains("27.3 MB"))
        #expect(text.contains("26.2 MB"))
        #expect(text.contains("Nothing was uploaded"))
    }

    @Test("Preflight also refuses more files than the plan allows")
    func fileCountPreflight() throws {
        let publisher = CloudflarePublisher(
            apiToken: "t", accountID: "acct", scriptName: "site"
        )
        let manifest = SiteManifest(
            root: URL(filePath: "/tmp"),
            files: (0..<20_001).map { file("/f\($0)", size: 1) }
        )
        #expect(throws: PublishError.self) { try publisher.preflight(manifest) }
    }

    @Test("Batches stay under the request ceiling but never drop a large file")
    func batching() {
        let files = [
            file("/a", size: 8 * 1024 * 1024),
            file("/b", size: 8 * 1024 * 1024),
            file("/c", size: 8 * 1024 * 1024),
            file("/huge", size: 24 * 1024 * 1024),
            file("/d", size: 1),
        ]
        let batches = CloudflarePublisher.batches(of: files, maxBytes: 20 * 1024 * 1024)
        #expect(batches.map(\.count) == [2, 1, 1, 1])
        #expect(batches.flatMap { $0 }.map(\.path) == files.map(\.path))
        #expect(batches[2].first?.path == "/huge")
    }

    @Test("Worker names are checked before any network call")
    func nameValidation() {
        for bad in ["", "Alecs Notes", "alecs_notes", "-leading", "trailing-"] {
            let publisher = CloudflarePublisher(apiToken: "t", accountID: "a", scriptName: bad)
            #expect(throws: PublishError.self) { try publisher.validateScriptName() }
        }
        for good in ["alecs-notes", "notes2", "a"] {
            let publisher = CloudflarePublisher(apiToken: "t", accountID: "a", scriptName: good)
            #expect(throws: Never.self) { try publisher.validateScriptName() }
        }
    }

    @Test("An expired token is reported as such, not as a mystery failure")
    func inactiveToken() async throws {
        let transport = RoutingTransport(routes: [
            route("GET", "user/tokens/verify", #"{"success":true,"result":{"id":"x","status":"expired"}}"#)
        ])
        let publisher = CloudflarePublisher(
            api: await transport.api(), accountID: "acct", scriptName: "site"
        )
        await #expect(throws: PublishError.self) { _ = try await publisher.validateCredentials() }
    }

    @Test("A valid token names the account it can reach")
    func validCredentials() async throws {
        let transport = RoutingTransport(routes: [
            route("GET", "user/tokens/verify", #"{"success":true,"result":{"id":"x","status":"active"}}"#),
            route("GET", "/accounts?", #"{"success":true,"result":[{"id":"acct","name":"Alec's Account"}]}"#),
        ])
        let publisher = CloudflarePublisher(
            api: await transport.api(), accountID: "acct", scriptName: "site"
        )
        #expect(try await publisher.validateCredentials() == "Alec's Account (acct)")
    }

    @Test("A token without Account Settings: Read still validates")
    func narrowTokenStillValidates() async throws {
        let transport = RoutingTransport(routes: [
            route("GET", "user/tokens/verify", #"{"success":true,"result":{"id":"x","status":"active"}}"#),
            route("GET", "/accounts?", #"{"success":false,"errors":[{"code":9109,"message":"no"}]}"#, status: 403),
        ])
        let publisher = CloudflarePublisher(
            api: await transport.api(), accountID: "acct", scriptName: "site"
        )
        #expect(try await publisher.validateCredentials() == "Cloudflare account acct")
    }

    @Test("A subdomain that cannot be switched on is a warning, not a failed publish")
    func subdomainWarning() async throws {
        let root = try makeSite()
        defer { try? FileManager.default.removeItem(at: root) }

        let transport = RoutingTransport(routes: [
            route("POST", "assets-upload-session", #"{"success":true,"result":{"jwt":"j","buckets":[]}}"#),
            route("PUT", "workers/scripts/site", #"{"success":true,"result":{}}"#),
            route("POST", "scripts/site/subdomain", #"{"success":false,"errors":[{"code":10000,"message":"nope"}]}"#, status: 403),
            route("GET", "workers/subdomain", #"{"success":true,"result":{"subdomain":"alecf"}}"#),
        ])
        let publisher = CloudflarePublisher(
            api: await transport.api(), accountID: "acct", scriptName: "site"
        )
        let result = try await publisher.publish(siteRoot: root, progress: { _ in })
        #expect(result.url.absoluteString == "https://site.alecf.workers.dev/")
        #expect(result.warnings.count == 1)
        #expect(result.warnings[0].contains("workers.dev"))
    }

    @Test("An empty folder is refused before the network is touched")
    func emptySite() async throws {
        let root = URL(filePath: NSTemporaryDirectory())
            .appending(path: "notes-to-web-empty-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let transport = RoutingTransport(routes: [])
        let publisher = CloudflarePublisher(
            api: await transport.api(), accountID: "acct", scriptName: "site"
        )
        await #expect(throws: PublishError.self) {
            _ = try await publisher.publish(siteRoot: root, progress: { _ in })
        }
        #expect(await transport.requests.isEmpty)
    }
}

/// Progress callbacks arrive on whatever executor the publisher is running on.
private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [PublishProgress] = []

    func add(_ progress: PublishProgress) {
        lock.lock()
        storage.append(progress)
        lock.unlock()
    }

    var steps: [PublishProgress] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
