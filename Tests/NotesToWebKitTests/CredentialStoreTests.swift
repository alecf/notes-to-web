import Foundation
import Testing
@testable import NotesToWebKit

/// Touches the real login keychain, so it is opt-in and uses its own service name.
/// Run with `NOTES_TO_WEB_KEYCHAIN=1 swift test`.
@Suite(
    "Credential store",
    .enabled(if: ProcessInfo.processInfo.environment["NOTES_TO_WEB_KEYCHAIN"] == "1"),
    .serialized
)
struct CredentialStoreTests {
    private static let service = "com.alecf.notes-to-web.tests"
    private let store = CredentialStore(service: CredentialStoreTests.service)
    private let provider = "cloudflare-workers-test"

    @Test("A missing credential reads as nil rather than throwing")
    func missingIsNil() throws {
        try store.delete(provider: provider)
        #expect(try store.read(provider: provider) == nil)
    }

    @Test("Write, read back, overwrite, delete")
    func roundTrip() throws {
        defer { try? store.delete(provider: provider) }

        try store.write("first-token", provider: provider)
        #expect(try store.read(provider: provider) == "first-token")

        try store.write("second-token", provider: provider)
        #expect(try store.read(provider: provider) == "second-token")

        try store.delete(provider: provider)
        #expect(try store.read(provider: provider) == nil)
        // Deleting twice is not an error.
        try store.delete(provider: provider)
    }

    @Test("Providers do not see each other's secrets")
    func isolation() throws {
        defer {
            try? store.delete(provider: provider)
            try? store.delete(provider: "other-provider")
        }
        try store.write("mine", provider: provider)
        try store.write("theirs", provider: "other-provider")
        #expect(try store.read(provider: provider) == "mine")
        #expect(try store.read(provider: "other-provider") == "theirs")
    }
}

@Suite("Credential store errors")
struct CredentialStoreErrorTests {

    @Test("Keychain failures explain themselves and never echo the secret")
    func messages() throws {
        let write = try #require(CredentialStoreError.couldNotWrite(errSecAuthFailed).errorDescription)
        #expect(write.contains("keychain"))
        #expect(write.contains("try again"))

        let read = try #require(CredentialStoreError.couldNotRead(errSecItemNotFound).errorDescription)
        #expect(!read.isEmpty)

        let damaged = try #require(CredentialStoreError.notText.errorDescription)
        #expect(damaged.contains("damaged"))
    }

    @Test("The default service is the app's identifier")
    func defaults() {
        #expect(CredentialStore.defaultService == "com.alecf.notes-to-web")
        #expect(CredentialStore().service == "com.alecf.notes-to-web")
        #expect(CloudflarePublisher.providerID == "cloudflare-workers")
    }
}
