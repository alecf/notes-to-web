import Foundation
import Testing
@testable import NotesToWebKit

// MARK: Stub transport

/// Records what the client sent and replays canned replies. No network, no clock.
actor StubTransport {
    struct Reply: Sendable {
        var status: Int
        var body: Data

        static func json(_ string: String, status: Int = 200) -> Reply {
            Reply(status: status, body: Data(string.utf8))
        }
    }

    private var replies: [Reply]
    private let failure: (any Error)?
    private(set) var requests: [URLRequest] = []
    private(set) var sleeps: [TimeInterval] = []

    init(replies: [Reply] = [], failure: (any Error)? = nil) {
        self.replies = replies
        self.failure = failure
    }

    func record(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        if let failure { throw failure }
        let reply = replies.isEmpty ? Reply.json(#"{"success":true,"result":null}"#) : replies.removeFirst()
        let response = HTTPURLResponse(
            url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: nil
        )!
        return (reply.body, response)
    }

    func note(sleep seconds: TimeInterval) { sleeps.append(seconds) }

    var attemptCount: Int { requests.count }

    func api(retryPolicy: RetryPolicy = RetryPolicy()) -> CloudflareAPI {
        CloudflareAPI(
            token: "test-token",
            retryPolicy: retryPolicy,
            executor: { [self] request in try await record(request) },
            sleeper: { [self] seconds in await note(sleep: seconds) }
        )
    }
}

private struct Thing: Decodable, Sendable, Equatable {
    let name: String
}

// MARK: Tests

@Suite("Cloudflare envelope")
struct CloudflareEnvelopeTests {

    @Test("A success envelope yields the result and tolerates null errors")
    func successEnvelope() throws {
        let json = #"{"result":{"name":"widget"},"success":true,"errors":null,"messages":null}"#
        let envelope = try JSONDecoder().decode(
            CloudflareEnvelope<Thing>.self, from: Data(json.utf8)
        )
        #expect(envelope.success)
        #expect(envelope.errors.isEmpty)
        #expect(envelope.result == Thing(name: "widget"))
    }

    @Test("An error envelope keeps every code and message")
    func errorEnvelope() throws {
        let json = """
        {"result":null,"success":false,"errors":[{"code":10000,"message":"Authentication error"},\
        {"code":10021,"message":"Script name is invalid"}],"messages":[]}
        """
        let envelope = try JSONDecoder().decode(
            CloudflareEnvelope<Thing>.self, from: Data(json.utf8)
        )
        #expect(!envelope.success)
        #expect(envelope.result == nil)
        #expect(envelope.errors == [
            CloudflareMessage(code: 10000, message: "Authentication error"),
            CloudflareMessage(code: 10021, message: "Script name is invalid"),
        ])
    }

    @Test("A 200 carrying success:false is still a failure")
    func successFalse() async throws {
        let stub = StubTransport(replies: [
            .json(#"{"success":false,"errors":[{"code":10021,"message":"nope"}],"result":null}"#)
        ])
        await #expect(throws: CloudflareAPIError.self) {
            _ = try await stub.api().get("/thing", as: Thing.self)
        }
    }

    @Test("401 and Cloudflare's code 10000 both name the permission to grant")
    func authErrors() throws {
        let byStatus = CloudflareAPIError.mapping(
            status: 403, messages: [CloudflareMessage(code: 9109, message: "Unauthorized")]
        )
        let byCode = CloudflareAPIError.mapping(
            status: 400, messages: [CloudflareMessage(code: 10000, message: "Authentication error")]
        )
        for error in [byStatus, byCode] {
            let text = try #require(error.errorDescription)
            #expect(text.contains("Workers Scripts: Edit"))
        }
        #expect(byCode == .unauthorized("Authentication error"))
    }

    @Test("Other statuses map to their own sentences")
    func otherErrors() {
        #expect(CloudflareAPIError.mapping(status: 404, messages: []) == .notFound("no explanation given"))
        #expect(CloudflareAPIError.mapping(
            status: 429, messages: [CloudflareMessage(code: 971, message: "slow down")]
        ) == .rateLimited("slow down"))
        if case .serverError(let status, _) = CloudflareAPIError.mapping(status: 503, messages: []) {
            #expect(status == 503)
        } else {
            Issue.record("503 should map to a server error")
        }
        let rejected = CloudflareAPIError.mapping(
            status: 413, messages: [CloudflareMessage(code: 0, message: "too big")]
        )
        #expect(rejected.errorDescription?.contains("too big") == true)
    }

    @Test("Non-JSON error bodies still produce a usable message")
    func htmlErrorBody() {
        let messages = CloudflareAPI.messages(in: Data("<html>502 Bad Gateway</html>".utf8))
        #expect(messages.first?.message.contains("502 Bad Gateway") == true)
    }
}

@Suite("Retry policy")
struct RetryPolicyTests {

    @Test("Backoff grows geometrically and stops at the ceiling")
    func backoff() {
        let policy = RetryPolicy(maxAttempts: 6, initialDelay: 0.5, multiplier: 3, maximumDelay: 10)
        #expect(policy.delay(forAttempt: 1) == 0.5)
        #expect(policy.delay(forAttempt: 2) == 1.5)
        #expect(policy.delay(forAttempt: 3) == 4.5)
        #expect(policy.delay(forAttempt: 4) == 10)
        #expect(policy.delay(forAttempt: 5) == 10)
    }

    @Test("Only transient failures are retried")
    func decisions() {
        let policy = RetryPolicy(maxAttempts: 3, initialDelay: 0.5, multiplier: 2, maximumDelay: 10)
        #expect(policy.decide(attempt: 1, status: 429, error: nil) == .retry(after: 0.5))
        #expect(policy.decide(attempt: 2, status: 500, error: nil) == .retry(after: 1))
        #expect(policy.decide(attempt: 1, status: 408, error: nil) == .retry(after: 0.5))
        #expect(policy.decide(attempt: 1, status: 400, error: nil) == .giveUp)
        #expect(policy.decide(attempt: 1, status: 401, error: nil) == .giveUp)
        #expect(policy.decide(attempt: 1, status: 200, error: nil) == .giveUp)
        // Attempts are exhausted, however retryable the status is.
        #expect(policy.decide(attempt: 3, status: 500, error: nil) == .giveUp)
        #expect(policy.decide(attempt: 1, status: nil, error: URLError(.timedOut)) == .retry(after: 0.5))
        #expect(policy.decide(attempt: 1, status: nil, error: URLError(.badURL)) == .giveUp)
        #expect(policy.decide(attempt: 1, status: nil, error: CancellationError()) == .giveUp)
    }

    @Test("A 500 then a 200 is one transparent retry, and it sleeps first")
    func retriesThenSucceeds() async throws {
        let stub = StubTransport(replies: [
            .json(#"{"success":false,"errors":[{"code":0,"message":"oops"}]}"#, status: 500),
            .json(#"{"success":true,"result":{"name":"widget"}}"#),
        ])
        let result = try await stub.api().get("/thing", as: Thing.self)
        #expect(result == Thing(name: "widget"))
        #expect(await stub.attemptCount == 2)
        #expect(await stub.sleeps == [0.5])
    }

    @Test("A failing endpoint gives up after maxAttempts and never spins forever")
    func givesUp() async throws {
        let stub = StubTransport(replies: (0..<10).map { _ in .json("{}", status: 503) })
        await #expect(throws: CloudflareAPIError.self) {
            _ = try await stub.api(retryPolicy: RetryPolicy(maxAttempts: 3, initialDelay: 0.1))
                .get("/thing", as: Thing.self)
        }
        #expect(await stub.attemptCount == 3)
    }

    @Test("A 401 is not retried")
    func doesNotRetryAuth() async throws {
        let stub = StubTransport(replies: [.json(#"{"success":false,"errors":[]}"#, status: 401)])
        await #expect(throws: CloudflareAPIError.self) {
            _ = try await stub.api().get("/thing", as: Thing.self)
        }
        #expect(await stub.attemptCount == 1)
    }

    @Test("A dropped connection is retried; a bad URL is not")
    func networkErrors() async throws {
        let flaky = StubTransport(failure: URLError(.networkConnectionLost))
        await #expect(throws: CloudflareAPIError.self) {
            _ = try await flaky.api(retryPolicy: RetryPolicy(maxAttempts: 2, initialDelay: 0.1))
                .get("/thing", as: Thing.self)
        }
        #expect(await flaky.attemptCount == 2)

        let fatal = StubTransport(failure: URLError(.badURL))
        await #expect(throws: CloudflareAPIError.self) {
            _ = try await fatal.api().get("/thing", as: Thing.self)
        }
        #expect(await fatal.attemptCount == 1)
    }
}

@Suite("Multipart form data")
struct MultipartFormDataTests {

    @Test("Bodies are CRLF-delimited with the disposition and type Cloudflare expects")
    func encoding() {
        var form = MultipartFormData(boundary: "BOUNDARY")
        form.append(name: "metadata", body: Data(#"{"a":1}"#.utf8), contentType: "application/json")
        form.append(
            name: "08f1dfda", body: Data("aGk=".utf8), filename: "08f1dfda", contentType: "text/html"
        )

        let expected = [
            "--BOUNDARY\r\n",
            "Content-Disposition: form-data; name=\"metadata\"\r\n",
            "Content-Type: application/json\r\n",
            "\r\n",
            "{\"a\":1}\r\n",
            "--BOUNDARY\r\n",
            "Content-Disposition: form-data; name=\"08f1dfda\"; filename=\"08f1dfda\"\r\n",
            "Content-Type: text/html\r\n",
            "\r\n",
            "aGk=\r\n",
            "--BOUNDARY--\r\n",
        ].joined()

        #expect(String(decoding: form.encoded(), as: UTF8.self) == expected)
        #expect(form.contentTypeHeader == "multipart/form-data; boundary=BOUNDARY")
    }

    @Test("Quotes and newlines in a field name cannot break out of the header")
    func escaping() {
        var form = MultipartFormData(boundary: "B")
        form.append(name: "a\"b\r\nContent-Type: evil", text: "x")
        let encoded = String(decoding: form.encoded(), as: UTF8.self)
        #expect(encoded.contains("name=\"a%22bContent-Type: evil\""))
        // One CRLF each after the boundary, the disposition, the blank line, the body, and
        // the closing boundary: the injected header never became a header.
        #expect(encoded.components(separatedBy: "\r\n").count == 6)
        #expect(!encoded.contains("\r\nContent-Type: evil"))
    }

    @Test("Binary part bodies survive encoding byte for byte")
    func binaryBody() {
        var form = MultipartFormData(boundary: "B")
        let payload = Data([0x00, 0xFF, 0x0D, 0x0A, 0x42])
        form.append(name: "f", body: payload)
        let encoded = form.encoded()
        #expect(encoded.range(of: payload) != nil)
        #expect(form.estimatedByteCount > payload.count)
    }
}
