import Foundation
import Network

/// A loopback HTTP server that exists only to catch one OAuth redirect.
///
/// RFC 8252 ("OAuth 2.0 for Native Apps") calls this the loopback interface redirect, and
/// prefers it to a custom URL scheme: any app on the machine can register `notestoweb://`
/// and steal the callback, whereas only one process can hold a port. Wrangler does the same
/// thing on port 8976, which is also the practical proof that Cloudflare's authorization
/// server is willing to redirect to `http://127.0.0.1`.
///
/// The literal `127.0.0.1` is used rather than `localhost` on the same RFC's advice: the
/// name can resolve to something else, the address cannot.
public actor OAuthCallbackListener {
    /// Fixed, not ephemeral. Cloudflare matches `redirect_uri` against the exact strings
    /// registered with the OAuth client, so the port has to be known when the client is
    /// created — an OS-assigned port could never match.
    public static let defaultPort: UInt16 = 9787
    public static let callbackPath = "/oauth/callback"

    private let port: UInt16
    private var listener: NWListener?
    private var waiter: CheckedContinuation<URL, any Error>?
    private var captured: URL?

    public init(port: UInt16 = OAuthCallbackListener.defaultPort) {
        self.port = port
    }

    public var redirectURI: URL {
        URL(string: "http://127.0.0.1:\(port)\(Self.callbackPath)")!
    }

    // MARK: Lifecycle

    /// Binds the port and returns the redirect URI to send to Cloudflare.
    ///
    /// Binding happens *before* the browser opens so that "something else is on that port"
    /// is reported while the user is still looking at the settings window, rather than
    /// after they have signed in and the answer has nowhere to land. That only works if
    /// this waits for the listener to actually reach `.ready`: `NWListener.start` is
    /// asynchronous, and returning early would hand back a redirect URI nothing is serving.
    @discardableResult
    public func start() async throws -> URL {
        guard listener == nil else { return redirectURI }

        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw OAuthError.callbackFailed("port \(port) is not a usable port number")
        }
        let parameters = NWParameters.tcp
        // Loopback only. Without this the callback server would be reachable from the
        // local network for as long as a sign-in is in progress.
        parameters.requiredInterfaceType = .loopback
        // Deliberately *not* `allowLocalEndpointReuse`: that lets a second listener bind a
        // port this one already holds, so a stale sign-in could silently take the callback
        // meant for a newer one. A clash must be an error, not a race.
        parameters.allowLocalEndpointReuse = false

        let listener: NWListener
        do {
            listener = try NWListener(using: parameters, on: nwPort)
        } catch {
            throw OAuthError.callbackFailed(
                "port \(port) could not be opened (\(error.localizedDescription))"
            )
        }

        listener.newConnectionHandler = { [weak self] connection in
            connection.start(queue: .main)
            Task { await self?.read(connection) }
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            // Resolved exactly once: `NWListener` keeps emitting state after `.ready`, and
            // resuming a continuation twice is a crash rather than a warning.
            let settled = OneShot()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    settled.once { continuation.resume() }
                case .failed(let error), .waiting(let error):
                    // `.waiting` is how "address already in use" arrives: the listener is
                    // not failed, it is politely retrying forever. For a sign-in that is
                    // indistinguishable from broken, so it is treated as an error.
                    settled.once {
                        continuation.resume(throwing: OAuthError.callbackFailed(
                            "port \(self.port) is already in use (\(error.localizedDescription))"
                        ))
                    }
                default:
                    break
                }
            }
            listener.start(queue: .main)
        }

        self.listener = listener
        return redirectURI
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        waiter?.resume(throwing: OAuthError.authorizationDenied(""))
        waiter = nil
    }

    // MARK: Waiting

    /// Resolves with the redirect URL the browser was sent to.
    ///
    /// The timeout matters: a user who closes the browser window instead of signing in
    /// leaves nothing to wait for, and a sign-in button that spins forever is worse than
    /// one that gives up and says so.
    public func waitForCallback(timeout: TimeInterval) async throws -> URL {
        if let captured {
            self.captured = nil
            return captured
        }
        // The listener has to bind before a race with the timeout can even be described.
        if listener == nil { try await start() }

        let timer = Task { [weak self] in
            try await Task.sleep(for: .seconds(timeout))
            await self?.fail(.callbackFailed("no reply arrived within \(Int(timeout)) seconds"))
        }
        defer { timer.cancel() }

        return try await withCheckedThrowingContinuation { continuation in
            self.waiter = continuation
        }
    }

    private func fail(_ error: OAuthError) {
        waiter?.resume(throwing: error)
        waiter = nil
    }

    private func deliver(_ url: URL) {
        guard let waiter else {
            // Arrived before anyone asked; hold it so `waitForCallback` returns immediately.
            captured = url
            return
        }
        waiter.resume(returning: url)
        self.waiter = nil
    }

    // MARK: HTTP

    private func read(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, _ in
            guard let data, let request = String(data: data, encoding: .utf8) else {
                connection.cancel()
                return
            }
            Task { await self.handle(request: request, on: connection) }
        }
    }

    private func handle(request: String, on connection: NWConnection) {
        guard let target = Self.requestTarget(request) else {
            respond(connection, status: "400 Bad Request", body: "")
            return
        }
        // A browser fetches /favicon.ico unprompted. Answering 404 and staying open is the
        // difference between a sign-in that works and one that resolves with no code.
        guard target.hasPrefix(Self.callbackPath) else {
            respond(connection, status: "404 Not Found", body: "")
            return
        }

        respond(connection, status: "200 OK", body: Self.successPage)

        if let url = URL(string: "http://127.0.0.1:\(port)\(target)") {
            deliver(url)
        } else {
            fail(.malformedResponse("the redirect address could not be read"))
        }
    }

    /// The path and query from an HTTP request line: `GET /oauth/callback?code=… HTTP/1.1`.
    static func requestTarget(_ request: String) -> String? {
        guard let line = request.split(separator: "\r\n", maxSplits: 1).first else { return nil }
        let fields = line.split(separator: " ")
        guard fields.count >= 2, fields[0] == "GET" else { return nil }
        return String(fields[1])
    }

    private func respond(_ connection: NWConnection, status: String, body: String) {
        let response = """
        HTTP/1.1 \(status)\r
        Content-Type: text/html; charset=utf-8\r
        Content-Length: \(body.utf8.count)\r
        Connection: close\r
        \r
        \(body)
        """
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    /// Guards a continuation that several `NWListener` state changes could otherwise resume.
    ///
    /// A class rather than an actor because the state handler is synchronous and resuming
    /// from a detached task would reorder `.ready` against `.failed`.
    private final class OneShot: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false

        func once(_ body: () -> Void) {
            lock.lock()
            defer { lock.unlock() }
            guard !done else { return }
            done = true
            body()
        }
    }

    /// Inline styles and no assets: this page is served by a socket that is about to close,
    /// so anything it references would 404.
    static let successPage = """
    <!doctype html>
    <html lang="en">
    <head><meta charset="utf-8"><title>Signed in — Notes to Web</title></head>
    <body style="font: 16px -apple-system, system-ui, sans-serif; margin: 0; display: grid;
                 place-items: center; height: 100vh; color: #1d1d1f; background: #f5f5f7;">
      <main style="text-align: center; padding: 2rem;">
        <h1 style="font-size: 1.4rem; margin: 0 0 0.5rem;">You're signed in</h1>
        <p style="margin: 0; color: #6e6e73;">Notes to Web is connected. You can close this tab.</p>
      </main>
    </body>
    </html>
    """
}
