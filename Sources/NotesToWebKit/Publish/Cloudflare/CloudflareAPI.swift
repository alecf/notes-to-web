import Foundation

// MARK: - Envelope

/// One entry of Cloudflare's `errors` / `messages` arrays.
public struct CloudflareMessage: Decodable, Sendable, Equatable {
    public let code: Int
    public let message: String

    public init(code: Int, message: String) {
        self.code = code
        self.message = message
    }

    private enum CodingKeys: String, CodingKey { case code, message }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // `code` is absent on some endpoints and on validation errors.
        code = try container.decodeIfPresent(Int.self, forKey: .code) ?? 0
        message = try container.decodeIfPresent(String.self, forKey: .message) ?? ""
    }
}

/// Every Cloudflare v4 response is `{success, errors, messages, result}`.
/// `errors` and `messages` are `null` rather than `[]` on success.
public struct CloudflareEnvelope<Result: Decodable & Sendable>: Decodable, Sendable {
    public let success: Bool
    public let errors: [CloudflareMessage]
    public let messages: [CloudflareMessage]
    public let result: Result?

    private enum CodingKeys: String, CodingKey { case success, errors, messages, result }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        success = try container.decodeIfPresent(Bool.self, forKey: .success) ?? false
        errors = try container.decodeIfPresent([CloudflareMessage].self, forKey: .errors) ?? []
        messages = try container.decodeIfPresent([CloudflareMessage].self, forKey: .messages) ?? []
        result = try container.decodeIfPresent(Result.self, forKey: .result)
    }
}

// MARK: - Errors

public enum CloudflareAPIError: Error, LocalizedError, Equatable {
    case unauthorized(String)
    case notFound(String)
    case rateLimited(String)
    case serverError(status: Int, detail: String)
    case requestRejected(status: Int, detail: String)
    case malformedResponse(String)
    case network(String)

    public var errorDescription: String? {
        switch self {
        case .unauthorized(let detail):
            """
            That API token isn't valid or lacks the Workers Scripts: Edit permission. Create a \
            token at dash.cloudflare.com/profile/api-tokens with Account → Workers Scripts → Edit, \
            scoped to the account you are publishing to. (Cloudflare said: \(detail))
            """
        case .notFound(let detail):
            "Cloudflare could not find that account or Worker. (Cloudflare said: \(detail))"
        case .rateLimited(let detail):
            """
            Cloudflare is rate limiting this account, and retrying did not clear it. Wait a few \
            minutes and publish again. (Cloudflare said: \(detail))
            """
        case .serverError(let status, let detail):
            """
            Cloudflare had a problem on its end (HTTP \(status)) and retrying did not help. \
            Try again shortly. (Cloudflare said: \(detail))
            """
        case .requestRejected(let status, let detail):
            "Cloudflare rejected the request (HTTP \(status)): \(detail)"
        case .malformedResponse(let detail):
            "Cloudflare sent a response this app could not read: \(detail)"
        case .network(let detail):
            "Could not reach Cloudflare: \(detail) Check your internet connection and try again."
        }
    }

    /// Cloudflare reports authentication failures as HTTP 400 with code 10000 about as often
    /// as it uses 401, so the code matters as much as the status.
    static func mapping(status: Int, messages: [CloudflareMessage]) -> CloudflareAPIError {
        let detail = messages.isEmpty
            ? "no explanation given"
            : messages.map(\.message).filter { !$0.isEmpty }.joined(separator: "; ")
        let authCodes: Set<Int> = [10000, 9109, 9106, 9103]
        if status == 401 || status == 403 || messages.contains(where: { authCodes.contains($0.code) }) {
            return .unauthorized(detail)
        }
        switch status {
        case 404: return .notFound(detail)
        case 429: return .rateLimited(detail)
        case 500...: return .serverError(status: status, detail: detail)
        default: return .requestRejected(status: status, detail: detail)
        }
    }
}

// MARK: - Retry

/// Bounded exponential backoff. Split out from the transport so the decision table is
/// testable without a network or a clock.
public struct RetryPolicy: Sendable, Equatable {
    public enum Decision: Sendable, Equatable {
        case retry(after: TimeInterval)
        case giveUp
    }

    public var maxAttempts: Int
    public var initialDelay: TimeInterval
    public var multiplier: Double
    public var maximumDelay: TimeInterval

    public init(
        maxAttempts: Int = 4,
        initialDelay: TimeInterval = 0.5,
        multiplier: Double = 3,
        maximumDelay: TimeInterval = 20
    ) {
        self.maxAttempts = maxAttempts
        self.initialDelay = initialDelay
        self.multiplier = multiplier
        self.maximumDelay = maximumDelay
    }

    public static let none = RetryPolicy(maxAttempts: 1)

    /// `attempt` is 1-based: the delay before the second attempt is `initialDelay`.
    public func delay(forAttempt attempt: Int) -> TimeInterval {
        let exponent = Double(max(0, attempt - 1))
        return min(maximumDelay, initialDelay * pow(multiplier, exponent))
    }

    public func decide(attempt: Int, status: Int?, error: (any Error)?) -> Decision {
        guard attempt < maxAttempts else { return .giveUp }
        if let status, Self.isRetryable(status: status) { return .retry(after: delay(forAttempt: attempt)) }
        if let error, Self.isRetryable(error: error) { return .retry(after: delay(forAttempt: attempt)) }
        return .giveUp
    }

    /// Overload, throttling, and anything the origin admits is its own fault.
    public static func isRetryable(status: Int) -> Bool {
        status == 408 || status == 425 || status == 429 || status >= 500
    }

    /// Transient transport failures only. A bad host or a cancelled task must not spin.
    public static func isRetryable(error: any Error) -> Bool {
        if error is CancellationError { return false }
        guard let url = error as? URLError else { return false }
        switch url.code {
        case .timedOut, .cannotConnectToHost, .networkConnectionLost, .notConnectedToInternet,
             .dnsLookupFailed, .cannotFindHost, .resourceUnavailable, .requestBodyStreamExhausted,
             .internationalRoamingOff, .callIsActive, .dataNotAllowed, .secureConnectionFailed:
            return true
        default:
            return false
        }
    }
}

// MARK: - Multipart

/// Minimal `multipart/form-data` writer. Cloudflare's asset upload wants one part per file
/// named for the file's hash, and the script upload wants a single JSON part named `metadata`.
public struct MultipartFormData: Sendable, Equatable {
    public struct Part: Sendable, Equatable {
        public let name: String
        public let filename: String?
        public let contentType: String?
        public let body: Data
    }

    public let boundary: String
    public private(set) var parts: [Part] = []

    public init(boundary: String = "notes-to-web-\(UUID().uuidString)") {
        self.boundary = boundary
    }

    public var contentTypeHeader: String { "multipart/form-data; boundary=\(boundary)" }

    public var isEmpty: Bool { parts.isEmpty }

    public mutating func append(
        name: String,
        body: Data,
        filename: String? = nil,
        contentType: String? = nil
    ) {
        parts.append(Part(name: name, filename: filename, contentType: contentType, body: body))
    }

    public mutating func append(
        name: String,
        text: String,
        filename: String? = nil,
        contentType: String? = nil
    ) {
        append(name: name, body: Data(text.utf8), filename: filename, contentType: contentType)
    }

    public func encoded() -> Data {
        var data = Data()
        for part in parts {
            data.append(Data("--\(boundary)\r\n".utf8))
            var disposition = "Content-Disposition: form-data; name=\"\(Self.escape(part.name))\""
            if let filename = part.filename {
                disposition += "; filename=\"\(Self.escape(filename))\""
            }
            data.append(Data("\(disposition)\r\n".utf8))
            if let contentType = part.contentType {
                data.append(Data("Content-Type: \(contentType)\r\n".utf8))
            }
            data.append(Data("\r\n".utf8))
            data.append(part.body)
            data.append(Data("\r\n".utf8))
        }
        data.append(Data("--\(boundary)--\r\n".utf8))
        return data
    }

    /// Rough size of the encoded body, for batching decisions, without building it.
    public var estimatedByteCount: Int {
        parts.reduce(boundary.utf8.count + 6) { total, part in
            total + part.body.count + part.name.utf8.count
                + (part.filename?.utf8.count ?? 0) + (part.contentType?.utf8.count ?? 0)
                + boundary.utf8.count + 80
        }
    }

    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "\"", with: "%22")
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "")
    }
}

// MARK: - Transport

/// HTTP plumbing for the Cloudflare v4 API and nothing else: base URL, bearer auth, the
/// response envelope, retries, and turning failures into sentences. No publishing policy —
/// paths and payloads belong to the caller.
public struct CloudflareAPI: Sendable {
    public typealias Executor = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    public typealias Sleeper = @Sendable (TimeInterval) async throws -> Void

    /// Which bearer token to send: the user's long-lived API token, or a short-lived JWT
    /// handed out by an upload session.
    public enum Credential: Sendable {
        case accountToken
        case bearer(String)
    }

    public static let defaultBaseURL = URL(string: "https://api.cloudflare.com/client/v4")!

    public let baseURL: URL
    public let retryPolicy: RetryPolicy
    /// Never logged, never interpolated into an error.
    private let token: String
    private let execute: Executor
    private let sleep: Sleeper

    public init(
        token: String,
        baseURL: URL = CloudflareAPI.defaultBaseURL,
        retryPolicy: RetryPolicy = RetryPolicy(),
        executor: Executor? = nil,
        sleeper: Sleeper? = nil
    ) {
        self.token = token
        self.baseURL = baseURL
        self.retryPolicy = retryPolicy
        self.execute = executor ?? CloudflareAPI.urlSessionExecutor
        self.sleep = sleeper ?? { seconds in
            try await Task.sleep(for: .seconds(seconds))
        }
    }

    static let urlSessionExecutor: Executor = { request in
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CloudflareAPIError.malformedResponse("the reply was not an HTTP response")
        }
        return (data, http)
    }

    // MARK: Verbs

    public func get<T: Decodable & Sendable>(
        _ path: String,
        as type: T.Type = T.self,
        credential: Credential = .accountToken
    ) async throws -> T? {
        try await send(request(path, method: "GET", credential: credential), as: type)
    }

    public func postJSON<Body: Encodable & Sendable, T: Decodable & Sendable>(
        _ path: String,
        body: Body,
        as type: T.Type = T.self,
        credential: Credential = .accountToken
    ) async throws -> T? {
        var urlRequest = request(path, method: "POST", credential: credential)
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try encoder.encode(body)
        return try await send(urlRequest, as: type)
    }

    public func postMultipart<T: Decodable & Sendable>(
        _ path: String,
        form: MultipartFormData,
        as type: T.Type = T.self,
        credential: Credential = .accountToken
    ) async throws -> T? {
        try await sendMultipart(path, method: "POST", form: form, as: type, credential: credential)
    }

    public func putMultipart<T: Decodable & Sendable>(
        _ path: String,
        form: MultipartFormData,
        as type: T.Type = T.self,
        credential: Credential = .accountToken
    ) async throws -> T? {
        try await sendMultipart(path, method: "PUT", form: form, as: type, credential: credential)
    }

    /// Unwraps a `result` the caller cannot proceed without.
    public static func require<T>(_ value: T?, _ what: String) throws -> T {
        guard let value else {
            throw CloudflareAPIError.malformedResponse("the reply carried no \(what)")
        }
        return value
    }

    /// Percent-encodes a path segment (account IDs and script names come from user input).
    public static func segment(_ raw: String) -> String {
        raw.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(.init(charactersIn: "-_.~")))
            ?? raw
    }

    // MARK: Internals

    private var encoder: JSONEncoder { JSONEncoder() }

    private func sendMultipart<T: Decodable & Sendable>(
        _ path: String,
        method: String,
        form: MultipartFormData,
        as type: T.Type,
        credential: Credential
    ) async throws -> T? {
        var urlRequest = request(path, method: method, credential: credential)
        urlRequest.setValue(form.contentTypeHeader, forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = form.encoded()
        return try await send(urlRequest, as: type)
    }

    private func request(_ path: String, method: String, credential: Credential) -> URLRequest {
        let url = URL(string: baseURL.absoluteString + path) ?? baseURL
        var request = URLRequest(url: url)
        request.httpMethod = method
        switch credential {
        case .accountToken: request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        case .bearer(let jwt): request.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private func send<T: Decodable & Sendable>(_ request: URLRequest, as type: T.Type) async throws -> T? {
        var attempt = 1
        while true {
            try Task.checkCancellation()
            do {
                let (data, http) = try await execute(request)
                if (200..<300).contains(http.statusCode) {
                    return try decode(data, as: type)
                }
                let messages = Self.messages(in: data)
                if case .retry(let pause) = retryPolicy.decide(
                    attempt: attempt, status: http.statusCode, error: nil
                ) {
                    try await sleep(pause)
                    attempt += 1
                    continue
                }
                throw CloudflareAPIError.mapping(status: http.statusCode, messages: messages)
            } catch let error as CloudflareAPIError {
                throw error
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if case .retry(let pause) = retryPolicy.decide(attempt: attempt, status: nil, error: error) {
                    try await sleep(pause)
                    attempt += 1
                    continue
                }
                throw CloudflareAPIError.network(error.localizedDescription)
            }
        }
    }

    private func decode<T: Decodable & Sendable>(_ data: Data, as type: T.Type) throws -> T? {
        // A 200 with an empty body happens; treat it as "no result", not as a parse failure.
        guard !data.isEmpty else { return nil }
        let envelope: CloudflareEnvelope<T>
        do {
            envelope = try JSONDecoder().decode(CloudflareEnvelope<T>.self, from: data)
        } catch {
            throw CloudflareAPIError.malformedResponse(error.localizedDescription)
        }
        // Cloudflare can answer 200 with success:false.
        guard envelope.success else {
            throw CloudflareAPIError.mapping(status: 200, messages: envelope.errors)
        }
        return envelope.result
    }

    /// Best-effort error extraction: failures sometimes arrive as HTML or as a bare string.
    static func messages(in data: Data) -> [CloudflareMessage] {
        guard !data.isEmpty else { return [] }
        if let envelope = try? JSONDecoder().decode(CloudflareEnvelope<EmptyResult>.self, from: data),
           !envelope.errors.isEmpty {
            return envelope.errors
        }
        let text = String(decoding: data.prefix(400), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? [] : [CloudflareMessage(code: 0, message: text)]
    }
}

/// Placeholder for endpoints whose `result` we do not care about.
public struct EmptyResult: Decodable, Sendable {
    public init() {}
    public init(from decoder: any Decoder) throws {}
}
