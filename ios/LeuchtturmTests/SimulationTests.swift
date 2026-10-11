#if DEBUG
import Foundation
import LeuchtturmCore
import Testing
@testable import Leuchtturm

@MainActor
struct SimulationTests {
    private func simulatedModel() async throws -> (AppModel, SimulatedWorld) {
        let model = AppModel(usesDeviceServices: false)
        model.startSimulation()
        let world = try #require(model.simulation)
        #expect(await model.setUp(name: "Tim"))
        return (model, world)
    }

    @Test func personJoinsWithInviteAndIsConfirmed() async throws {
        let (model, world) = try await simulatedModel()
        let ref = try #require(await model.createCircle(name: "Familie"))
        let link = try #require(await model.run { try await $0.createInvite(for: ref) })
        await model.simulate { try await $0.join(world.people[0], using: link) }

        let details = try #require(await model.run { try await $0.circle(ref) })
        let anna = try #require(details.members.first { $0.name == "Anna" })
        #expect(!anna.isPending)
        #expect(await world.people(notIn: ref.circleID).map(\.name) == ["Ben", "Clara"])
    }

    @Test func invitationFromPersonCanBeAccepted() async throws {
        let (model, world) = try await simulatedModel()
        let ben = world.people[1]
        let link = try #require(await model.simulate { try await $0.invitation(from: ben) })
        let ref = try #require(await model.join(link))
        #expect(model.circles.map(\.name) == ["Bens Kreis"])

        // Ben's device confirms the new member and sees the name.
        await world.tick()
        let bensRef = try #require(try await ben.client.circles().first?.ref)
        #expect(bensRef.circleID == ref.circleID)
        let bensView = try await ben.client.circle(bensRef)
        #expect(bensView.members.contains { $0.name == "Tim" && !$0.isPending })
    }

    @Test func leavingPersonDisappears() async throws {
        let (model, world) = try await simulatedModel()
        let ref = try #require(await model.createCircle(name: "Familie"))
        let link = try #require(await model.run { try await $0.createInvite(for: ref) })
        await model.simulate { try await $0.join(world.people[2], using: link) }
        await model.simulate { try await $0.leave(world.people[2], circleID: ref.circleID) }

        let details = try #require(await model.run { try await $0.circle(ref) })
        #expect(details.members.map(\.name) == ["Tim"])
    }

    @Test func peopleShowUpOnTheMap() async throws {
        let (model, world) = try await simulatedModel()
        let ref = try #require(await model.createCircle(name: "Familie"))
        let link = try #require(await model.run { try await $0.createInvite(for: ref) })
        await model.simulate { try await $0.join(world.people[1], using: link) }

        let details = try #require(await model.mapDetails(for: ref))
        let ben = try #require(details.members.first { $0.name == "Ben" }?.location)
        let home = SimulatedWorld.fallbackHome
        #expect(abs(ben.latitude - home.latitude) < 0.05 && abs(ben.longitude - home.longitude) < 0.05)
    }

    @Test func peopleAnswerReactions() async throws {
        let (model, world) = try await simulatedModel()
        await model.createDemoCircle()
        let ref = try #require(model.circles.first?.ref)
        let anna = world.people[0]
        #expect(await model.send(.reaction, text: "❤️", to: anna.client.deviceID, in: ref))

        let details = try #require(await model.mapDetails(for: ref))
        let me = try #require(model.client?.deviceID)
        #expect(details.notes.contains { $0.senderID == anna.client.deviceID && $0.recipientID == me && $0.text == "😊" })
        #expect(details.notes.contains { $0.senderID == me && $0.text == "❤️" })
    }

    @Test func fogBlocksCheckIns() async throws {
        let (model, _) = try await simulatedModel()
        await model.createDemoCircle()
        let ref = try #require(model.circles.first?.ref)
        await model.startFog(radius: 1000, hours: 1)
        #expect(model.activeFog?.radius == 1000)
        #expect(!(await model.send(.checkIn, in: ref)))
        await model.endFog()
        #expect(model.activeFog == nil)
    }

    @Test func strangerWithShareLinkIsUnverified() async throws {
        let (model, _) = try await simulatedModel()
        let ref = try #require(await model.createCircle(name: "Familie"))
        await model.simulate { try await $0.strangerOpensShareLink(of: ref) }

        let details = try #require(await model.run { try await $0.circle(ref) })
        #expect(details.unverifiedUserIDs.count == 1)
        #expect(details.members.count == 1)
    }

    @Test func realSetupStaysUntouched() async throws {
        let savedName = UserDefaults.standard.string(forKey: "displayName")
        let keychainAccounts = try? KeychainSecretStore().accounts()

        let (model, _) = try await simulatedModel()
        _ = await model.createCircle(name: "Familie")
        model.resetLocal()
        model.endSimulation()

        #expect(!model.isSimulation)
        #expect(UserDefaults.standard.string(forKey: "displayName") == savedName)
        let keychainAccountsAfter = try? KeychainSecretStore().accounts()
        #expect(keychainAccountsAfter == keychainAccounts)
    }
}
#endif
