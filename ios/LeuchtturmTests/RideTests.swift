import Foundation
import LeuchtturmCore
import Testing
@testable import Leuchtturm

@MainActor
struct RideTests {
    func trip() -> Trip {
        Trip(id: "t1", deviceID: "me", start: Date(), end: Date().addingTimeInterval(600), distance: 8000,
             topSpeed: 20, hardBrakes: 0, rapidAccelerations: 0, route: [])
    }

    func samples(carPlay: Int = 0, bluetooth: String? = nil, of total: Int = 10) -> CarSamples {
        var samples = CarSamples()
        for i in 0 ..< total {
            samples.add(CarAudio.Reading(carPlay: i < carPlay, bluetooth: bluetooth))
        }
        return samples
    }

    @Test func carPlayMeansThisPhoneDrove() {
        let model = AppModel(usesDeviceServices: false)
        model.carSamples = samples(carPlay: 6)
        let guessed = model.guessDriver(trip())
        #expect(guessed.role == .driver && guessed.reason == .carPlay)
    }

    @Test func onlyKnownCarsCountOverBluetooth() {
        let model = AppModel(usesDeviceServices: false)
        // Headphones or an unknown car: no guess, but the name is kept for the answer.
        model.carSamples = samples(bluetooth: "Golf")
        #expect(model.guessDriver(trip()).role == nil)
        #expect(model.tripCars["t1"] == "Golf")
        model.myCars = ["Golf"]
        model.carSamples = samples(bluetooth: "Golf")
        let guessed = model.guessDriver(trip())
        #expect(guessed.role == .driver && guessed.reason == .bluetooth && guessed.carName == "Golf")
    }

    @Test func briefConnectionsDoNotCount() {
        let model = AppModel(usesDeviceServices: false)
        model.myCars = ["Golf"]
        // Connected for 2 of 10 readings only.
        var mixed = CarSamples()
        for i in 0 ..< 10 { mixed.add(CarAudio.Reading(carPlay: false, bluetooth: i < 2 ? "Golf" : nil)) }
        model.carSamples = mixed
        #expect(model.guessDriver(trip()).role == nil)
    }
}
