import Foundation
import HealthKit

struct DailyHealthSummary: Codable {
    let date: String
    let steps: Double?
    let activeEnergyKcal: Double?
    let avgHeartRate: Double?
    let restingHeartRate: Double?
    let hrvSdnn: Double?
    let sleepMinutes: Double?
    let napMinutes: Double?
    let workoutMinutes: Double?
    let source: String

    enum CodingKeys: String, CodingKey {
        case date
        case steps
        case activeEnergyKcal = "active_energy_kcal"
        case avgHeartRate = "avg_heart_rate"
        case restingHeartRate = "resting_heart_rate"
        case hrvSdnn = "hrv_sdnn"
        case sleepMinutes = "sleep_minutes"
        case napMinutes = "nap_minutes"
        case workoutMinutes = "workout_minutes"
        case source
    }
}

private struct SleepBreakdown {
    let mainSleepMinutes: Double?
    let napMinutes: Double?
}

@MainActor
final class HealthKitManager: ObservableObject {
    @Published var authorizationMessage = "尚未授权。"

    private let store = HKHealthStore()
    private let calendar = Calendar.current
    private var observerQueries: [HKObserverQuery] = []

    func requestAuthorization() async throws {
        guard HKHealthStore.isHealthDataAvailable() else {
            throw HealthBridgeError.healthDataUnavailable
        }

        var readTypes = Set<HKObjectType>()
        Self.quantityTypes
            .compactMap { HKObjectType.quantityType(forIdentifier: $0) }
            .forEach { readTypes.insert($0) }
        [HKObjectType.categoryType(forIdentifier: .sleepAnalysis), HKObjectType.workoutType()]
            .compactMap { $0 }
            .forEach { readTypes.insert($0) }

        try await store.requestAuthorization(toShare: [], read: readTypes)
        authorizationMessage = "已授权，可以同步今天的数据。"
    }

    func enableBackgroundDelivery(onHealthChange: @escaping @Sendable () -> Void) async {
        guard HKHealthStore.isHealthDataAvailable() else { return }

        for sampleType in Self.sampleTypes {
            observerQueries.removeAll { $0.objectType == sampleType }

            let query = HKObserverQuery(sampleType: sampleType, predicate: nil) { _, completionHandler, error in
                if error == nil {
                    onHealthChange()
                }
                completionHandler()
            }

            observerQueries.append(query)
            store.execute(query)

            do {
                try await store.enableBackgroundDelivery(for: sampleType, frequency: .daily)
            } catch {
                // Some HealthKit types may not support background delivery on every device.
            }
        }
    }

    func readRecentSummaries(days: Int = 7) async throws -> [DailyHealthSummary] {
        guard HKHealthStore.isHealthDataAvailable() else {
            throw HealthBridgeError.healthDataUnavailable
        }

        let dayCount = max(1, days)
        let now = Date()
        var summaries: [DailyHealthSummary] = []

        for offset in stride(from: dayCount - 1, through: 0, by: -1) {
            let day = calendar.date(byAdding: .day, value: -offset, to: now) ?? now
            let summary = try await readSummary(for: day, endingAt: now)
            summaries.append(summary)
        }

        return summaries
    }

    func readTodaySummary() async throws -> DailyHealthSummary {
        guard let summary = try await readRecentSummaries(days: 1).first else {
            throw HealthBridgeError.noSummaryCreated
        }
        return summary
    }

    private func readSummary(for day: Date, endingAt now: Date) async throws -> DailyHealthSummary {
        let startOfDay = calendar.startOfDay(for: day)
        let nextDay = calendar.date(byAdding: .day, value: 1, to: startOfDay) ?? now
        let end = min(nextDay, now)
        let sleepStart = calendar.date(byAdding: .hour, value: -6, to: startOfDay) ?? startOfDay
        let date = Self.dateFormatter.string(from: day)

        async let steps = optionalMetric { try await self.sumQuantity(.stepCount, unit: .count(), start: startOfDay, end: end) }
        async let activeEnergy = optionalMetric { try await self.sumQuantity(.activeEnergyBurned, unit: .kilocalorie(), start: startOfDay, end: end) }
        async let averageHeartRate = optionalMetric { try await self.averageQuantity(.heartRate, unit: HKUnit.count().unitDivided(by: .minute()), start: startOfDay, end: end) }
        async let restingHeartRate = optionalMetric { try await self.latestQuantity(.restingHeartRate, unit: HKUnit.count().unitDivided(by: .minute()), start: startOfDay, end: end) }
        async let hrv = optionalMetric { try await self.latestQuantity(.heartRateVariabilitySDNN, unit: .secondUnit(with: .milli), start: startOfDay, end: end) }
        async let sleep = optionalSleepBreakdown { try await self.sleepBreakdown(start: sleepStart, end: end) }
        async let exercise = optionalMetric { try await self.sumQuantity(.appleExerciseTime, unit: .minute(), start: startOfDay, end: end) }

        let sleepBreakdown = await sleep
        return await DailyHealthSummary(
            date: date,
            steps: steps,
            activeEnergyKcal: activeEnergy,
            avgHeartRate: averageHeartRate,
            restingHeartRate: restingHeartRate,
            hrvSdnn: hrv,
            sleepMinutes: sleepBreakdown?.mainSleepMinutes,
            napMinutes: sleepBreakdown?.napMinutes,
            workoutMinutes: exercise,
            source: "HermesHealthBridge"
        )
    }

    private func optionalMetric(_ read: @escaping () async throws -> Double?) async -> Double? {
        do {
            return try await read()
        } catch {
            return nil
        }
    }

    private func optionalSleepBreakdown(_ read: @escaping () async throws -> SleepBreakdown) async -> SleepBreakdown? {
        do {
            return try await read()
        } catch {
            return nil
        }
    }

    private func sumQuantity(_ identifier: HKQuantityTypeIdentifier, unit: HKUnit, start: Date, end: Date) async throws -> Double? {
        guard let type = HKQuantityType.quantityType(forIdentifier: identifier) else { return nil }
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)

        return try await withCheckedThrowingContinuation { continuation in
            let query = HKStatisticsQuery(quantityType: type, quantitySamplePredicate: predicate, options: .cumulativeSum) { _, result, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: result?.sumQuantity()?.doubleValue(for: unit))
            }
            store.execute(query)
        }
    }

    private func averageQuantity(_ identifier: HKQuantityTypeIdentifier, unit: HKUnit, start: Date, end: Date) async throws -> Double? {
        guard let type = HKQuantityType.quantityType(forIdentifier: identifier) else { return nil }
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)

        return try await withCheckedThrowingContinuation { continuation in
            let query = HKStatisticsQuery(quantityType: type, quantitySamplePredicate: predicate, options: .discreteAverage) { _, result, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: result?.averageQuantity()?.doubleValue(for: unit))
            }
            store.execute(query)
        }
    }

    private func latestQuantity(_ identifier: HKQuantityTypeIdentifier, unit: HKUnit, start: Date, end: Date) async throws -> Double? {
        guard let type = HKQuantityType.quantityType(forIdentifier: identifier) else { return nil }
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)

        return try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(sampleType: type, predicate: predicate, limit: 1, sortDescriptors: [sort]) { _, samples, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                let value = (samples?.first as? HKQuantitySample)?.quantity.doubleValue(for: unit)
                continuation.resume(returning: value)
            }
            store.execute(query)
        }
    }

    private func sleepBreakdown(start: Date, end: Date) async throws -> SleepBreakdown {
        guard let type = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else {
            return SleepBreakdown(mainSleepMinutes: nil, napMinutes: nil)
        }
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: [])
        let detailedAsleepValues = Set([
            HKCategoryValueSleepAnalysis.asleepCore.rawValue,
            HKCategoryValueSleepAnalysis.asleepDeep.rawValue,
            HKCategoryValueSleepAnalysis.asleepREM.rawValue
        ])
        let fallbackAsleepValues = detailedAsleepValues.union([
            HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue
        ])

        return try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(sampleType: type, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, samples, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                let sleepSamples = samples?
                    .compactMap { $0 as? HKCategorySample }
                    .filter { fallbackAsleepValues.contains($0.value) } ?? []

                let hasDetailedSleep = sleepSamples.contains { detailedAsleepValues.contains($0.value) }
                let valuesToUse = hasDetailedSleep ? detailedAsleepValues : fallbackAsleepValues

                let intervals = sleepSamples
                    .filter { valuesToUse.contains($0.value) }
                    .map { (max($0.startDate, start), min($0.endDate, end)) }
                    .filter { $0.0 < $0.1 }
                    .sorted { $0.0 < $1.0 }

                var merged: [(Date, Date)] = []
                for interval in intervals {
                    guard let last = merged.last else {
                        merged.append(interval)
                        continue
                    }
                    if interval.0 <= last.1 {
                        merged[merged.count - 1] = (last.0, max(last.1, interval.1))
                    } else {
                        merged.append(interval)
                    }
                }

                var sessions: [[(Date, Date)]] = []
                for interval in merged {
                    guard var current = sessions.last, let last = current.last else {
                        sessions.append([interval])
                        continue
                    }

                    let gapMinutes = interval.0.timeIntervalSince(last.1) / 60.0
                    if gapMinutes <= 90 {
                        current.append(interval)
                        sessions[sessions.count - 1] = current
                    } else {
                        sessions.append([interval])
                    }
                }

                let sessionSummaries = sessions.map { session in
                    let total = session.reduce(0.0) { $0 + $1.1.timeIntervalSince($1.0) / 60.0 }
                    let start = session.first?.0 ?? Date.distantPast
                    return (start: start, total: total)
                }
                let calendar = Calendar.current
                let napSessions = sessionSummaries.filter { session in
                        guard session.total >= 10, session.total <= 180 else { return false }
                        let hour = calendar.component(.hour, from: session.start)
                        return hour >= 10 && hour <= 18
                }
                let mainSleep = sessionSummaries
                    .filter { session in
                        !napSessions.contains { $0.start == session.start && $0.total == session.total }
                    }
                    .max { $0.total < $1.total }
                let mainSleepMinutes = mainSleep?.total
                let napMinutes = napSessions.reduce(0.0) { $0 + $1.total }

                continuation.resume(returning: SleepBreakdown(
                    mainSleepMinutes: mainSleepMinutes,
                    napMinutes: napMinutes > 0 ? napMinutes : nil
                ))
            }
            store.execute(query)
        }
    }

    private static let quantityTypes: [HKQuantityTypeIdentifier] = [
        .stepCount,
        .activeEnergyBurned,
        .heartRate,
        .restingHeartRate,
        .heartRateVariabilitySDNN,
        .appleExerciseTime
    ]

    private static var sampleTypes: [HKSampleType] {
        let quantityTypes = Self.quantityTypes.compactMap {
            HKObjectType.quantityType(forIdentifier: $0)
        }
        let categoryTypes = [HKObjectType.categoryType(forIdentifier: .sleepAnalysis)].compactMap { $0 }
        return quantityTypes + categoryTypes
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

enum HealthBridgeError: LocalizedError {
    case healthDataUnavailable
    case noSummaryCreated

    var errorDescription: String? {
        switch self {
        case .healthDataUnavailable:
            return "这台设备无法读取健康数据，请在 iPhone 上运行这个 App。"
        case .noSummaryCreated:
            return "暂时无法生成健康摘要。"
        }
    }
}
