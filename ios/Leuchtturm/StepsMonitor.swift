import Foundation
import HealthKit

/// Step counts from Health (today and the last 7 days), only if the user
/// shares them. Asked at most every 10 minutes.
@MainActor
final class StepsMonitor {
    private let store = HKHealthStore()
    private var lastFetch: Date?
    private(set) var today: Int?
    private(set) var week: Int?

    static var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    func requestAccess() async {
        guard Self.isAvailable else { return }
        try? await store.requestAuthorization(toShare: [], read: [HKQuantityType(.stepCount)])
        lastFetch = nil
        await refresh()
    }

    func refresh() async {
        guard Self.isAvailable else { return }
        if let lastFetch, Date().timeIntervalSince(lastFetch) < 600 { return }
        lastFetch = Date()
        let startOfDay = Calendar.current.startOfDay(for: Date())
        today = await sum(since: startOfDay)
        week = await sum(since: Calendar.current.date(byAdding: .day, value: -6, to: startOfDay) ?? startOfDay)
    }

    func reset() {
        today = nil
        week = nil
        lastFetch = nil
    }

    private func sum(since start: Date) async -> Int? {
        let predicate = HKQuery.predicateForSamples(withStart: start, end: Date())
        let descriptor = HKStatisticsQueryDescriptor(
            predicate: HKSamplePredicate.quantitySample(type: HKQuantityType(.stepCount), predicate: predicate),
            options: .cumulativeSum
        )
        return (try? await descriptor.result(for: store))?.sumQuantity().map { Int($0.doubleValue(for: .count())) }
    }
}
