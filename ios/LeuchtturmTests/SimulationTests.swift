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

    @Test func demoCircleHasPlaces() async throws {
        let (model, _) = try await simulatedModel()
        await model.createDemoCircle()
        let ref = try #require(model.circles.first?.ref)
        let details = try #require(await model.mapDetails(for: ref))
        #expect(Set(details.places.map(\.name)) == ["Zuhause", "Café am See", "Büro"])
        #expect(details.members.count == 4)
    }

    @Test func simulatedPeopleShareHistory() async throws {
        let (model, world) = try await simulatedModel()
        await model.createDemoCircle()
        let ref = try #require(model.circles.first?.ref)
        _ = await model.mapDetails(for: ref)
        let anna = world.people[0].client.deviceID
        let clara = world.people[2].client.deviceID
        let annasDays = try #require(await model.run { try await $0.history(of: anna, in: ref) })
        #expect(annasDays.first?.points.count ?? 0 > 10)
        #expect(await model.run { try await $0.history(of: clara, in: ref) }?.isEmpty == true)
    }

    @Test func demoWeekHasALeaderboard() async throws {
        let (model, world) = try await simulatedModel()
        await model.createDemoCircle()
        let ref = try #require(model.circles.first?.ref)
        _ = await model.mapDetails(for: ref) // the owner's device confirms the new members
        let trips = try #require(await model.run { try await $0.trips(in: ref, since: Date().addingTimeInterval(-7 * 86400)) })
        #expect(trips.count == 6)
        let board = DriverStats.leaderboard(trips)
        #expect(board.map(\.deviceID) == [world.people[1].client.deviceID, world.people[2].client.deviceID])
    }

    @Test func sosAndCrashCheck() async throws {
        let (model, world) = try await simulatedModel()
        await model.createDemoCircle()
        let ref = try #require(model.circles.first?.ref)
        _ = await model.mapDetails(for: ref)

        // "Mir geht's gut" stops the countdown: no SOS.
        model.startCrashCheck()
        #expect(model.crashCheckDeadline != nil)
        model.cancelCrashCheck()
        #expect(model.crashCheckDeadline == nil && model.sosSentAt == nil)

        // "Hilfe rufen" alerts the circle; others see it with the reason.
        await model.confirmCrashHelp()
        #expect(model.sosSentAt != nil)
        let annasView = try await world.people[0].client.circle(try #require(try await world.people[0].client.circles().first).ref)
        let sos = try #require(annasView.notes.first { $0.kind == .sos })
        #expect(sos.text == "Möglicher Unfall erkannt") // no GPS in unit tests, so no position here

        await model.sendAllClear()
        #expect(model.sosSentAt == nil)
    }

    @Test func claraWarnsAboutHerBattery() async throws {
        let (model, world) = try await simulatedModel()
        await model.createDemoCircle()
        let ref = try #require(model.circles.first?.ref)
        _ = await model.mapDetails(for: ref)
        let details = try #require(await model.mapDetails(for: ref))
        let clara = world.people[2].client.deviceID
        let warnings = details.notes.filter { $0.kind == .lowBattery && $0.senderID == clara }
        #expect(warnings.map(\.text) == ["9"])
    }

    @Test func arrivalWatchesCanBeSetAndRemoved() async throws {
        let (model, world) = try await simulatedModel()
        await model.createDemoCircle()
        let ref = try #require(model.circles.first?.ref)
        let details = try #require(await model.mapDetails(for: ref))
        let ben = try #require(details.members.first { $0.id == world.people[1].client.deviceID })
        let office = try #require(model.places(inCircle: ref.circleID).first { $0.name == "Büro" })

        await model.addArrivalWatch(member: ben, place: office, circleID: ref.circleID, hour: 8, minute: 15, repeats: .weekdays)
        #expect(model.arrivalWatches.map(\.placeID) == [office.id])
        await model.removeArrivalWatch(model.arrivalWatches[0].id)
        #expect(model.arrivalWatches.isEmpty)
    }

    @Test func demoSuggestsTheSportsClub() async throws {
        let (model, _) = try await simulatedModel()
        await model.createDemoCircle()
        let ref = try #require(model.circles.first?.ref)
        _ = await model.mapDetails(for: ref)
        let suggestions = model.placeSuggestions(inCircle: ref.circleID)
        #expect(suggestions.map(\.visits) == [3])
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
