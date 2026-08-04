import Foundation
import Testing
@testable import NotesToWebKit

private let activeToken = route(
    "GET", "user/tokens/verify", #"{"success":true,"result":{"id":"x","status":"active"}}"#
)

@Suite("Cloudflare account discovery")
struct CloudflareAccountDiscoveryTests {

    @Test("One account is discovered, so the user never types an ID")
    func singleAccount() async throws {
        let transport = RoutingTransport(routes: [
            activeToken,
            route("GET", "/accounts?", #"{"success":true,"result":[{"id":"acct1","name":"Alec's Account"}]}"#),
        ])
        let accounts = try await CloudflarePublisher.discoverAccounts(api: await transport.api())
        #expect(accounts == [CloudflareAccount(id: "acct1", name: "Alec's Account")])
        #expect(accounts[0].label == "Alec's Account (acct1)")
    }

    @Test("Several accounts all come back, in the order Cloudflare listed them")
    func multipleAccounts() async throws {
        let transport = RoutingTransport(routes: [
            activeToken,
            route("GET", "/accounts?", """
            {"success":true,"result":[
              {"id":"acct1","name":"Personal"},
              {"id":"acct2","name":"Work"},
              {"id":"acct3","name":"Client"}
            ]}
            """),
        ])
        let accounts = try await CloudflarePublisher.discoverAccounts(api: await transport.api())
        #expect(accounts.map(\.id) == ["acct1", "acct2", "acct3"])
        #expect(accounts.map(\.name) == ["Personal", "Work", "Client"])
    }

    @Test("A token that can list neither accounts nor memberships returns none, not an error")
    func enumerationRefused() async throws {
        for status in [401, 403] {
            let refused = #"{"success":false,"errors":[{"code":9109,"message":"Unauthorized to access requested resource"}]}"#
            let transport = RoutingTransport(routes: [
                activeToken,
                route("GET", "/accounts?", refused, status: status),
                route("GET", "/memberships?", refused, status: status),
            ])
            let accounts = try await CloudflarePublisher.discoverAccounts(api: await transport.api())
            #expect(accounts.isEmpty)
            // Enumeration is tried first; verify runs only afterwards, to decide
            // whether an empty result means "bad token" or "token too narrow".
            #expect(await transport.paths == [
                "GET /client/v4/accounts",
                "GET /client/v4/memberships",
                "GET /client/v4/user/tokens/verify",
            ])
        }
    }

    @Test("A token refused by /accounts still discovers through /memberships, as wrangler does")
    func membershipsFallback() async throws {
        let transport = RoutingTransport(routes: [
            activeToken,
            route(
                "GET", "/accounts?",
                #"{"success":false,"errors":[{"code":9109,"message":"Unauthorized to access requested resource"}]}"#,
                status: 403
            ),
            route("GET", "/memberships?", """
            {"success":true,"result":[
              {"id":"m1","status":"accepted","account":{"id":"acct1","name":"Alec's Account"}},
              {"id":"m2","status":"pending","account":{"id":"acct9","name":"Not Mine Yet"}}
            ]}
            """),
        ])
        let accounts = try await CloudflarePublisher.discoverAccounts(api: await transport.api())
        // A membership still waiting to be accepted cannot be published to.
        #expect(accounts == [CloudflareAccount(id: "acct1", name: "Alec's Account")])
    }

    @Test("/memberships is not called when /accounts already answered")
    func membershipsSkipped() async throws {
        let transport = RoutingTransport(routes: [
            activeToken,
            route("GET", "/accounts?", #"{"success":true,"result":[{"id":"acct1","name":"Personal"}]}"#),
        ])
        _ = try await CloudflarePublisher.discoverAccounts(api: await transport.api())
        // Nothing else is needed once an account is known — not even verify.
        #expect(await transport.paths == ["GET /client/v4/accounts"])
    }

    @Test("An account list that is merely empty is also not an error")
    func emptyAccountList() async throws {
        let transport = RoutingTransport(routes: [
            activeToken,
            route("GET", "/accounts?", #"{"success":true,"result":[]}"#),
            route("GET", "/memberships?", #"{"success":true,"result":[]}"#),
        ])
        #expect(try await CloudflarePublisher.discoverAccounts(api: await transport.api()).isEmpty)
    }

    @Test("A genuinely invalid token is an authentication failure")
    func invalidToken() async throws {
        let rejected = #"{"success":false,"errors":[{"code":1000,"message":"Invalid API Token"}]}"#
        let transport = RoutingTransport(routes: [
            route("GET", "user/tokens/verify", rejected, status: 401),
            route("GET", "/accounts?", rejected, status: 401),
            route("GET", "/memberships?", rejected, status: 401),
        ])
        await #expect(throws: PublishError.self) {
            _ = try await CloudflarePublisher.discoverAccounts(api: await transport.api())
        }
    }

    /// Regression: measured against a real account-owned token, `/user/tokens/verify`
    /// answers 401 while every account endpoint works. Verifying first rejected it.
    @Test("An account-scoped token is accepted even though it cannot verify itself")
    func accountScopedTokenIsAccepted() async throws {
        let transport = RoutingTransport(routes: [
            route(
                "GET", "user/tokens/verify",
                #"{"success":false,"errors":[{"code":1000,"message":"Invalid API Token"}]}"#,
                status: 401
            ),
            route("GET", "/accounts?", #"{"success":true,"result":[{"id":"acct1","name":"Personal"}]}"#),
        ])
        let accounts = try await CloudflarePublisher.discoverAccounts(api: await transport.api())
        #expect(accounts.map(\.id) == ["acct1"])
        #expect(await transport.paths == ["GET /client/v4/accounts"], "verify must not be consulted")
    }

    @Test("A malformed token — Cloudflare's 400 — reads as a credential problem, not a mystery")
    func malformedToken() async throws {
        let transport = RoutingTransport(routes: [
            route(
                "GET", "user/tokens/verify",
                #"{"success":false,"errors":[{"code":6003,"message":"Invalid request headers"}]}"#,
                status: 400
            ),
        ])
        let error = await #expect(throws: PublishError.self) {
            _ = try await CloudflarePublisher.discoverAccounts(api: await transport.api())
        }
        let text = try #require(error?.errorDescription)
        #expect(text.contains("would not accept that API token"))
        #expect(!text.contains("token-value-abc"))
    }

    @Test("An inactive token is named as such")
    func expiredToken() async throws {
        let transport = RoutingTransport(routes: [
            route("GET", "user/tokens/verify", #"{"success":true,"result":{"id":"x","status":"expired"}}"#),
        ])
        let error = await #expect(throws: PublishError.self) {
            _ = try await CloudflarePublisher.discoverAccounts(api: await transport.api())
        }
        #expect(error?.errorDescription?.contains("expired") == true)
    }

    @Test("An outage during discovery is reported, not silently swallowed as a bad token")
    func serverErrorOnVerify() async throws {
        let transport = RoutingTransport(routes: [
            route("GET", "user/tokens/verify", #"{"success":false,"errors":[{"code":0,"message":"oops"}]}"#, status: 503),
        ])
        await #expect(throws: CloudflareAPIError.self) {
            _ = try await CloudflarePublisher.discoverAccounts(api: await transport.api())
        }
    }

    @Test("The token never appears in any message a user could see")
    func tokenIsNeverEchoed() async throws {
        let transport = RoutingTransport(routes: [
            route("GET", "user/tokens/verify", #"{"success":false,"errors":[{"code":1000,"message":"Invalid API Token"}]}"#, status: 401),
        ])
        let api = CloudflareAPI(
            token: "s3cret-token-value",
            retryPolicy: RetryPolicy(maxAttempts: 1),
            executor: { request in try await transport.handle(request) },
            sleeper: { _ in }
        )
        let error = await #expect(throws: PublishError.self) {
            _ = try await CloudflarePublisher.discoverAccounts(api: api)
        }
        #expect(error?.errorDescription?.contains("s3cret") == false)
    }
}

@Suite("Cloudflare site listing")
struct CloudflareSiteListingTests {

    @Test("Workers come back newest first, with asset-serving ones flagged")
    func listSites() async throws {
        let transport = RoutingTransport(routes: [
            route("GET", "workers/scripts", """
            {"success":true,"result":[
              {"id":"api-worker","modified_on":"2025-03-01T10:00:00.000000Z","has_assets":false},
              {"id":"alecs-notes","modified_on":"2025-06-14T09:30:00.123456Z","has_assets":true},
              {"id":"old-thing","modified_on":"2024-01-05T08:00:00Z","has_assets":true}
            ]}
            """),
        ])
        let sites = try await CloudflarePublisher.listSites(api: await transport.api(), accountID: "acct1")

        #expect(sites.map(\.name) == ["alecs-notes", "api-worker", "old-thing"])
        #expect(sites.map(\.servesAssets) == [true, false, true])
        #expect(sites[0].id == "alecs-notes")
        // Fractional seconds and whole seconds both parse.
        #expect(sites[0].modifiedAt != nil)
        #expect(sites[2].modifiedAt != nil)
        #expect(await transport.paths == ["GET /client/v4/accounts/acct1/workers/scripts"])
    }

    @Test("A list that does not say whether a Worker serves assets is read conservatively")
    func unknownAssetFlag() async throws {
        let transport = RoutingTransport(routes: [
            route("GET", "workers/scripts", """
            {"success":true,"result":[{"id":"mystery","created_on":"2025-01-01T00:00:00Z"}]}
            """),
        ])
        let sites = try await CloudflarePublisher.listSites(api: await transport.api(), accountID: "a")
        #expect(sites.count == 1)
        #expect(sites[0].servesAssets == false)
        #expect(sites[0].modifiedAt == nil)
    }

    @Test("An account with no Workers lists nothing rather than failing")
    func emptyAccount() async throws {
        let transport = RoutingTransport(routes: [
            route("GET", "workers/scripts", #"{"success":true,"result":[]}"#),
        ])
        #expect(try await CloudflarePublisher.listSites(api: await transport.api(), accountID: "a").isEmpty)
    }

    @Test("A token that cannot read Workers surfaces the failure — this one is not optional")
    func listingRefused() async throws {
        let transport = RoutingTransport(routes: [
            route("GET", "workers/scripts", #"{"success":false,"errors":[{"code":10000,"message":"no"}]}"#, status: 403),
        ])
        await #expect(throws: CloudflareAPIError.self) {
            _ = try await CloudflarePublisher.listSites(api: await transport.api(), accountID: "a")
        }
    }
}

@Suite("Cloudflare site names")
struct CloudflareSiteNameTests {

    @Test("Realistic good names are accepted", arguments: [
        "alecs-notes", "notes", "n", "workout-log-2026", "a1", "2026-notes",
        String(repeating: "a", count: 63),
    ])
    func validNames(name: String) {
        #expect(CloudflarePublisher.validateSiteName(name) == nil)
    }

    @Test("Realistic bad names are rejected with a reason that names the problem")
    func invalidNames() throws {
        let cases: [(String, String)] = [
            ("", "Enter a name"),
            ("Alecs Notes", "lowercase"),
            ("alecs notes", "space"),
            ("alecs_notes", "_"),
            ("alecs.notes", "."),
            ("alecs/notes", "/"),
            ("notes!", "!"),
            ("café-notes", "é"),
            ("-leading", "start or end with a dash"),
            ("trailing-", "start or end with a dash"),
            (String(repeating: "a", count: 64), "63 characters"),
        ]
        for (name, expected) in cases {
            let reason = try #require(
                CloudflarePublisher.validateSiteName(name), "expected “\(name)” to be refused"
            )
            #expect(reason.contains(expected), "“\(name)” → \(reason)")
        }
    }

    @Test("An invalid name reaching publish is refused before any request, with the reason")
    func publishRefusesBadName() async throws {
        let publisher = CloudflarePublisher(apiToken: "t", accountID: "a", scriptName: "Alecs Notes")
        let error = #expect(throws: PublishError.self) { try publisher.validateScriptName() }
        let text = try #require(error?.errorDescription)
        #expect(text.contains("Alecs Notes"))
        #expect(text.contains("lowercase"))
    }
}

@Suite("Cloudflare site name availability")
struct CloudflareSiteAvailabilityTests {

    private func transport() -> RoutingTransport {
        RoutingTransport(routes: [
            route("GET", "workers/scripts", """
            {"success":true,"result":[
              {"id":"alecs-notes","modified_on":"2025-06-14T09:30:00Z","has_assets":true},
              {"id":"api-worker","modified_on":"2025-03-01T10:00:00Z","has_assets":false}
            ]}
            """),
        ])
    }

    @Test("A free name is available")
    func freeName() async throws {
        let stub = transport()
        #expect(try await CloudflarePublisher.isSiteNameAvailable(
            "workout-log", api: await stub.api(), accountID: "acct1"
        ))
    }

    @Test("A name already used by any Worker — assets or not — is taken")
    func takenNames() async throws {
        for taken in ["alecs-notes", "api-worker"] {
            let stub = transport()
            #expect(try await CloudflarePublisher.isSiteNameAvailable(
                taken, api: await stub.api(), accountID: "acct1"
            ) == false)
        }
    }

    @Test("An invalid name is unavailable without asking Cloudflare")
    func invalidNameSkipsNetwork() async throws {
        let stub = transport()
        #expect(try await CloudflarePublisher.isSiteNameAvailable(
            "Alecs Notes", api: await stub.api(), accountID: "acct1"
        ) == false)
        #expect(await stub.requests.isEmpty)
    }
}
