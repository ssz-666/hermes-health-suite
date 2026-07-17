import BackgroundTasks
import Foundation

@MainActor
final class BackgroundSyncService {
    static let shared = BackgroundSyncService()

    private let healthStore = HealthKitManager()
    private let taskIdentifier = "com.ssz.HermesHealthBridge.refresh"
    private var didRegisterBackgroundTasks = false
    private var didConfigureHealthKitDelivery = false

    private init() {}

    func registerBackgroundTasks() {
        guard !didRegisterBackgroundTasks else { return }
        didRegisterBackgroundTasks = true

        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskIdentifier, using: nil) { task in
            guard let appRefreshTask = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }

            Task { @MainActor in
                await self.handle(appRefreshTask)
            }
        }
    }

    func configureAutomaticSync() async {
        guard !didConfigureHealthKitDelivery else {
            scheduleAppRefresh()
            return
        }

        didConfigureHealthKitDelivery = true
        await healthStore.enableBackgroundDelivery {
            Task { @MainActor in
                _ = try? await BackgroundSyncService.shared.syncRecentDays(reason: "healthkit")
            }
        }
        scheduleAppRefresh()
    }

    @discardableResult
    func syncRecentDays(reason: String) async throws -> Int {
        let endpoint = UserDefaults.standard.string(forKey: "collectorURL") ?? "http://192.168.3.7:8765/health/daily"
        let summaries = try await healthStore.readRecentSummaries(days: 7)

        var uploaded = 0
        for summary in summaries {
            guard summary.hasMeaningfulMeasurements else {
                continue
            }
            do {
                try await HermesCollectorClient.post(summary: summary, to: endpoint)
            } catch CollectorError.serverError(400, let body)
                where body.localizedCaseInsensitiveContains("no non-zero health measurements") {
                continue
            }
            uploaded += 1
        }

        UserDefaults.standard.set(Date(), forKey: "lastAutomaticSyncAt")
        UserDefaults.standard.set(reason, forKey: "lastAutomaticSyncReason")
        scheduleAppRefresh()
        return uploaded
    }

    private func handle(_ task: BGAppRefreshTask) async {
        scheduleAppRefresh()

        let syncTask = Task { @MainActor in
            try await syncRecentDays(reason: "background-refresh")
        }

        task.expirationHandler = {
            syncTask.cancel()
        }

        do {
            _ = try await syncTask.value
            task.setTaskCompleted(success: true)
        } catch {
            task.setTaskCompleted(success: false)
        }
    }

    private func scheduleAppRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: taskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 60 * 60 * 6)

        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            // iOS may reject scheduling until background refresh is available for the app.
        }
    }
}

private extension DailyHealthSummary {
    var hasMeaningfulMeasurements: Bool {
        [
            steps,
            activeEnergyKcal,
            avgHeartRate,
            restingHeartRate,
            hrvSdnn,
            sleepMinutes,
            napMinutes,
            workoutMinutes
        ].contains { value in
            guard let value else { return false }
            return value != 0
        }
    }
}
