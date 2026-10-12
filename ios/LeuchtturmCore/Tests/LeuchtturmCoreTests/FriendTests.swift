import Foundation
import Testing
@testable import LeuchtturmCore

/// Friend codes, cards and requests, and a friendship from start to end.
struct FriendTests {
    @Test func codesAreTypoTolerant() throws {
        let code = FriendCode.generate()
        #expect(code.value.count == 12)
        #expect(code.description.count == 14)
        #expect(FriendCode(code.description) == code)
        #expect(FriendCode(code.description.lowercased()) == code)
        #expect(FriendCode(code.url.absoluteString) == code)
        let typed = try #require(FriendCode("k7qm 2xrb 9fda"))
        #expect(FriendCode("K7QM-2XRB-9FDA") == typed)
        #expect(FriendCode("O0IL-0000-0000")?.value == "001100000000")
        #expect(FriendCode("K7QM-2XRB") == nil)
        #expect(FriendCode("K7QM-2XRB-9FD!") == nil)
        #expect(FriendCode.generate() != code)
        #expect(code.recordName.hasPrefix("fc-") && !code.recordName.contains(code.value))
    }

    @Test func cardOpensOnlyWithTheCode() throws {
        let identity = DeviceIdentity.generate()
        let code = FriendCode.generate()
        let card = FriendCard(mailbox: CircleCrypto.newCircleID(), name: "Tim", agreementKey: identity.agreementPublicKey, signingKey: identity.signingPublicKey)
        let blob = try CircleCrypto.sealFriendCard(card, code: code)
        #expect(try CircleCrypto.openFriendCard(blob, code: code) == card)
        #expect(throws: (any Error).self) { try CircleCrypto.openFriendCard(blob, code: FriendCode.generate()) }
    }

    @Test func requestOpensOnlyForTheRecipient() throws {
        let tim = DeviceIdentity.generate()
        let card = FriendCard(mailbox: CircleCrypto.newCircleID(), name: "Tim", agreementKey: tim.agreementPublicKey, signingKey: tim.signingPublicKey)
        let ruslana = DeviceIdentity.generate()
        let invite = InviteLink(shareURL: URL(string: "https://www.icloud.com/share/0abc#Leuchtturm")!, inviteID: CircleCrypto.newCircleID(), secret: randomBytes(32))
        let request = FriendRequest(name: "Ruslana", invite: invite.url, agreementKey: ruslana.agreementPublicKey, signingKey: ruslana.signingPublicKey, timestamp: Date())
        let blob = try CircleCrypto.sealFriendRequest(request, to: card)
        #expect(try CircleCrypto.openFriendRequest(blob, mailbox: card.mailbox, recipient: tim) == request)
        #expect(throws: (any Error).self) { try CircleCrypto.openFriendRequest(blob, mailbox: card.mailbox, recipient: DeviceIdentity.generate()) }
        #expect(throws: (any Error).self) { try CircleCrypto.openFriendRequest(blob, mailbox: CircleCrypto.newCircleID(), recipient: tim) }
    }

    @Test func friendshipIsACircleOfTwo() async throws {
        let cloud = InMemoryCloud()
        let tim = try LeuchtturmClient(backend: cloud.backend(for: "tim"), secrets: InMemorySecretStore(), displayName: "Tim")
        let ruslana = try LeuchtturmClient(backend: cloud.backend(for: "ruslana"), secrets: InMemorySecretStore(), displayName: "Ruslana")
        // Ruslana typed Tim's code: she starts the friendship and sends the invite.
        let ref = try await ruslana.createCircle(name: "Tim", isFriendship: true)
        let invite = try await ruslana.createInvite(for: ref)
        let timsRef = try await tim.join(invite)
        _ = try await ruslana.circle(ref)

        let timsView = try await tim.circle(timsRef)
        #expect(timsView.isFriendship)
        #expect(Set(timsView.members.compactMap(\.name)) == ["Tim", "Ruslana"])
        #expect(try await tim.circles().first?.isFriendship == true)
        // Renaming keeps it a friendship.
        try await ruslana.rename(ref, to: "Tim S.")
        #expect(try await tim.circle(timsRef).isFriendship)
    }

    @Test func addingAFriendByCode() async throws {
        let cloud = InMemoryCloud()
        let publicStore = InMemoryPublicStore()
        let clock = TestClock()
        let tim = try LeuchtturmClient(backend: cloud.backend(for: "tim"), secrets: InMemorySecretStore(), displayName: "Tim", now: { clock.now })
        let ruslana = try LeuchtturmClient(backend: cloud.backend(for: "ruslana"), secrets: InMemorySecretStore(), displayName: "Ruslana", now: { clock.now })
        let timsDB = publicStore.database(for: "tim")
        let ruslanasDB = publicStore.database(for: "ruslana")

        let setup = FriendSetup.generate()
        try await tim.publishFriendCard(setup, in: timsDB)
        let code = try #require(setup.friendCode)

        // Ruslana types Tim's code, sees his name and sends a request.
        let card = try #require(try await ruslana.lookUpFriend(code, in: ruslanasDB))
        #expect(card.name == "Tim" && card.safetyCode == tim.safetyCode)
        #expect(try await ruslana.lookUpFriend(FriendCode.generate(), in: ruslanasDB) == nil)
        let sent = try await ruslana.sendFriendRequest(to: card, in: ruslanasDB)
        #expect(try await ruslana.tidyFriendRequests([sent], in: ruslanasDB) == [sent])

        // Someone else cannot delete or replace it.
        await #expect(throws: BackendError.permissionDenied) { try await timsDB.delete(sent.id) }

        // Tim sees it, with her safety code, and accepts.
        let incoming = try await tim.friendRequests(for: setup, in: timsDB)
        #expect(incoming.map(\.request.name) == ["Ruslana"])
        #expect(incoming.first?.request.safetyCode == ruslana.safetyCode)
        let first = try #require(incoming.first)
        let ref = try await tim.accept(first)
        #expect(try await tim.circle(ref).isFriendship)

        // Her device sees him joined and deletes the request.
        #expect(try await ruslana.tidyFriendRequests([sent], in: ruslanasDB).isEmpty)
        #expect(try await tim.friendRequests(for: setup, in: timsDB).isEmpty)
    }

    @Test func unansweredRequestsRunOut() async throws {
        let cloud = InMemoryCloud()
        let publicStore = InMemoryPublicStore()
        let clock = TestClock()
        let tim = try LeuchtturmClient(backend: cloud.backend(for: "tim"), secrets: InMemorySecretStore(), displayName: "Tim", now: { clock.now })
        let ben = try LeuchtturmClient(backend: cloud.backend(for: "ben"), secrets: InMemorySecretStore(), displayName: "Ben", now: { clock.now })
        let setup = FriendSetup.generate()
        try await tim.publishFriendCard(setup, in: publicStore.database(for: "tim"))
        let code = try #require(setup.friendCode)
        let card = try #require(try await ben.lookUpFriend(code, in: publicStore.database(for: "ben")))
        let sent = try await ben.sendFriendRequest(to: card, in: publicStore.database(for: "ben"))
        clock.advance(by: FriendRequest.lifetime + 60)
        #expect(try await tim.friendRequests(for: setup, in: publicStore.database(for: "tim")).isEmpty)
        #expect(try await ben.tidyFriendRequests([sent], in: publicStore.database(for: "ben")).isEmpty)
        #expect(try await ben.circles().isEmpty)
    }
}
