import Foundation
import Testing
@testable import LeuchtturmCore

struct ArrivalWatchTests {
    var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return c
    }

    /// Friday, 2027-01-15, at the given local time.
    func friday(_ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2027, month: 1, day: 15, hour: hour, minute: minute))!
    }

    func watch(_ repeats: ArrivalWatch.Repeat, created: Date) -> ArrivalWatch {
        ArrivalWatch(id: "w", circleID: "c", memberID: "ben", placeID: "school", hour: 8, minute: 15, repeats: repeats, created: created)
    }

    let school = CirclePlace(id: "school", creatorID: "x", name: "Schule", emoji: "🏫", latitude: 53.55, longitude: 9.99, radius: 150)!

    @Test func deadlinesFollowTheRepeatRule() {
        let early = friday(7)
        #expect(watch(.daily, created: early).deadlines(after: early, days: 3, calendar: calendar) == [friday(8, 15), friday(8, 15) + 86400, friday(8, 15) + 2 * 86400])
        // Friday, then Monday (the weekend is skipped).
        #expect(watch(.weekdays, created: early).deadlines(after: early, days: 4, calendar: calendar) == [friday(8, 15), friday(8, 15) + 3 * 86400])
        // Set after today's deadline: once means tomorrow, and only that.
        let late = friday(9)
        #expect(watch(.once, created: late).deadlines(after: late, days: 7, calendar: calendar) == [friday(8, 15) + 86400])
        #expect(watch(.once, created: late).deadlines(after: friday(8, 15) + 86400 + 60, days: 7, calendar: calendar).isEmpty)
    }

    @Test func arrivalOrPresenceSatisfiesTheDeadline() {
        let w = watch(.daily, created: friday(6))
        let deadline = friday(8, 15)
        let atSchool = SharedLocation(latitude: 53.5505, longitude: 9.99, accuracy: 10, timestamp: friday(7, 50))
        let atHome = SharedLocation(latitude: 53.6, longitude: 9.99, accuracy: 10, timestamp: friday(7, 50))
        #expect(w.isSatisfied(deadline: deadline, place: school, location: atSchool, notes: [], calendar: calendar))
        #expect(!w.isSatisfied(deadline: deadline, place: school, location: atHome, notes: [], calendar: calendar))

        let arrival = CircleNote(id: "n", senderID: "ben", recipientID: nil, kind: .arrival, text: "Schule", location: nil, timestamp: friday(8, 5))
        #expect(w.isSatisfied(deadline: deadline, place: school, location: atHome, notes: [arrival], calendar: calendar))
        let yesterday = CircleNote(id: "y", senderID: "ben", recipientID: nil, kind: .arrival, text: "Schule", location: nil, timestamp: friday(8, 5) - 86400)
        #expect(!w.isSatisfied(deadline: deadline, place: school, location: nil, notes: [yesterday], calendar: calendar))
    }
}
