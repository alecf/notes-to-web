import Foundation
import Testing
@testable import NotesToWebKit

/// Sends a raw HTTP GET the way a browser would, and returns what came back.
private func get(_ url: URL) async throws -> (status: Int, body: String) {
    var request = URLRequest(url: url)
    request.timeoutInterval = 5
    let (data, response) = try await URLSession.shared.data(for: request)
    let http = response as! HTTPURLResponse
    return (http.statusCode, String(decoding: data, as: UTF8.self))
}

@Suite("OAuth callback listener", .serialized)
struct OAuthCallbackListenerTests {

    @Test("The redirect that arrives in the browser is handed back whole")
    func capturesRedirect() async throws {
        let listener = OAuthCallbackListener(port: 9787)
        let redirectURI = try await listener.start()
        defer { Task { await listener.stop() } }

        #expect(redirectURI.absoluteString == "http://127.0.0.1:9787/oauth/callback")

        async let captured = listener.waitForCallback(timeout: 10)
        _ = try await get(URL(string: "\(redirectURI.absoluteString)?code=abc123&state=xyz")!)

        let url = try await captured
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(items.first { $0.name == "code" }?.value == "abc123")
        #expect(items.first { $0.name == "state" }?.value == "xyz")
    }

    @Test("The browser is left on a page that says it worked")
    func showsAPage() async throws {
        let listener = OAuthCallbackListener(port: 9788)
        let redirectURI = try await listener.start()
        defer { Task { await listener.stop() } }

        async let captured = listener.waitForCallback(timeout: 10)
        let response = try await get(URL(string: "\(redirectURI.absoluteString)?code=abc&state=xyz")!)
        _ = try await captured

        #expect(response.status == 200)
        // A blank tab after signing in reads as a failure even when it worked.
        #expect(response.body.lowercased().contains("notes to web"))
        #expect(response.body.lowercased().contains("</html>"))
    }

    @Test("A code that never arrives times out instead of hanging the sign-in button")
    func timesOut() async throws {
        let listener = OAuthCallbackListener(port: 9789)
        _ = try await listener.start()
        defer { Task { await listener.stop() } }

        await #expect(throws: OAuthError.self) {
            _ = try await listener.waitForCallback(timeout: 0.3)
        }
    }

    @Test("A port already in use is reported as that, not as a failed sign-in")
    func portInUse() async throws {
        let first = OAuthCallbackListener(port: 9790)
        _ = try await first.start()
        defer { Task { await first.stop() } }

        let second = OAuthCallbackListener(port: 9790)
        await #expect(throws: OAuthError.self) {
            _ = try await second.start()
        }
    }

    @Test("Requests to other paths are ignored, so a stray favicon fetch cannot end the wait")
    func ignoresOtherPaths() async throws {
        let listener = OAuthCallbackListener(port: 9791)
        let redirectURI = try await listener.start()
        defer { Task { await listener.stop() } }

        async let captured = listener.waitForCallback(timeout: 10)
        _ = try? await get(URL(string: "http://127.0.0.1:9791/favicon.ico")!)
        _ = try await get(URL(string: "\(redirectURI.absoluteString)?code=real&state=xyz")!)

        let url = try await captured
        #expect(url.absoluteString.contains("code=real"))
    }
}
