//  HealthAccess.swift
//  Apple Health on the phone, behind a protocol so the plan editor and the
//  run setup are tested with a fake:
//
//      authorisation  read heart rate, resting heart rate and date of birth;
//                     share workouts (the Watch saves the run's workout).
//      zones          resting and maximum heart rate to fill the plan's
//                     zones ("Fill from Health" in the plan editor).
//      the Watch      HKHealthStore.startWatchApp(with:) opens Dragon on the
//                     paired Watch and hands it a running workout to start.
//
//  HealthZoneEstimate turns what Health has into the plan's three numbers;
//  the system implementation (SystemHealthStore) only queries and hands on.

import Foundation
import HealthKit

/// What Health knows about the runner's heart, for the zones.
struct HealthHeartRates: Equatable {
    /// Latest resting heart rate (bpm), nil if Health has none.
    var resting: Double?
    /// Highest heart rate Health recorded over the look-back (bpm), nil if none.
    var recordedMax: Double?
    /// Age in whole years from the date of birth, nil if not shared.
    var age: Int?
}

protocol HealthStoreProviding: AnyObject {
    /// Health is on this device (not on some iPads).
    var isAvailable: Bool { get }
    /// Asks (once) to read heart rate, resting heart rate and date of birth,
    /// and to save workouts. `completion` (main queue): the request was shown
    /// or answered without error. Health never says whether reading was allowed.
    func requestAuthorization(completion: @escaping (Bool) -> Void)
    /// What Health has for the zones (main queue).
    func heartRates(lookBackDays: Int, completion: @escaping (HealthHeartRates) -> Void)
    /// Opens Dragon on the paired Watch with a running workout to start (main queue).
    func startWatchApp(completion: @escaping (Bool) -> Void)
}

/// Turns Health's numbers into the plan's resting, threshold and max.
struct HealthZoneEstimate: Equatable {
    struct Config: Equatable {
        /// Days of heart-rate history searched for the highest recorded.
        var lookBackDays = 365
        /// Threshold heart rate as a fraction of the way from resting to max.
        /// 0.88 gives the design's runner (rest 52, max 188) threshold 172.
        var thresholdFractionOfReserve = 0.88
        /// Age-predicted max (Tanaka): intercept − slope × age.
        var ageMaxIntercept = 208.0
        var ageMaxSlope = 0.7
    }

    var resting: Double
    var threshold: Double
    var max: Double
    /// Where max came from, in words for the screen.
    var maxSource: String

    /// Why there's no estimate.
    enum Failure: Error, Equatable {
        case noResting
        case noMax
        case outOfOrder
    }

    /// Max is the higher of the recorded peak and the age prediction (a
    /// recorded peak lower than the prediction usually means no all-out
    /// effort was worn, not a low max); either alone if only one is known.
    static func make(from rates: HealthHeartRates, config: Config = Config()) -> Result<HealthZoneEstimate, Failure> {
        guard let resting = rates.resting, resting > 0 else { return .failure(.noResting) }
        let predicted = rates.age.map { config.ageMaxIntercept - config.ageMaxSlope * Double($0) }
        let max: Double
        let source: String
        switch (rates.recordedMax, predicted) {
        case let (recorded?, predicted?):
            max = Swift.max(recorded, predicted)
            source = recorded >= predicted ? "highest recorded" : "predicted from age"
        case let (recorded?, nil):
            max = recorded
            source = "highest recorded"
        case let (nil, predicted?):
            max = predicted
            source = "predicted from age"
        case (nil, nil):
            return .failure(.noMax)
        }
        let r = resting.rounded()
        let m = max.rounded()
        guard m > r + 10 else { return .failure(.outOfOrder) }
        let t = (r + config.thresholdFractionOfReserve * (m - r)).rounded()
        return .success(HealthZoneEstimate(resting: r, threshold: t, max: m, maxSource: source))
    }
}

/// HealthKit itself. One store for the app: the Watch mirroring handler
/// (MirroredWorkoutTransport) is set on the same one at launch.
final class SystemHealthStore: HealthStoreProviding {
    static let shared = SystemHealthStore()

    let store = HKHealthStore()
    private let bpm = HKUnit.count().unitDivided(by: .minute())

    var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    static var readTypes: Set<HKObjectType> {
        [HKQuantityType(.heartRate), HKQuantityType(.restingHeartRate),
         HKCharacteristicType(.dateOfBirth), HKObjectType.workoutType()]
    }

    static var shareTypes: Set<HKSampleType> { [HKObjectType.workoutType()] }

    func requestAuthorization(completion: @escaping (Bool) -> Void) {
        guard isAvailable else { return completion(false) }
        store.requestAuthorization(toShare: Self.shareTypes, read: Self.readTypes) { ok, _ in
            DispatchQueue.main.async { completion(ok) }
        }
    }

    func heartRates(lookBackDays: Int, completion: @escaping (HealthHeartRates) -> Void) {
        guard isAvailable else { return completion(HealthHeartRates()) }
        var result = HealthHeartRates()
        if let birth = try? store.dateOfBirthComponents(), let date = Calendar.current.date(from: birth) {
            result.age = Calendar.current.dateComponents([.year], from: date, to: Date()).year
        }
        let group = DispatchGroup()
        let lock = NSLock()

        group.enter()
        let latestResting = HKSampleQuery(sampleType: HKQuantityType(.restingHeartRate), predicate: nil, limit: 1,
                                          sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)]) { [bpm] _, samples, _ in
            let value = (samples?.first as? HKQuantitySample)?.quantity.doubleValue(for: bpm)
            lock.lock(); result.resting = value; lock.unlock()
            group.leave()
        }
        store.execute(latestResting)

        group.enter()
        let start = Calendar.current.date(byAdding: .day, value: -lookBackDays, to: Date())
        let predicate = HKQuery.predicateForSamples(withStart: start, end: nil)
        let peak = HKStatisticsQuery(quantityType: HKQuantityType(.heartRate), quantitySamplePredicate: predicate,
                                     options: .discreteMax) { [bpm] _, stats, _ in
            let value = stats?.maximumQuantity()?.doubleValue(for: bpm)
            lock.lock(); result.recordedMax = value; lock.unlock()
            group.leave()
        }
        store.execute(peak)

        group.notify(queue: .main) { completion(result) }
    }

    func startWatchApp(completion: @escaping (Bool) -> Void) {
        let config = HKWorkoutConfiguration()
        config.activityType = .running
        config.locationType = .outdoor
        store.startWatchApp(with: config) { ok, error in
            if let error { NSLog("[WatchLink] startWatchApp failed: %@", error.localizedDescription) }
            DispatchQueue.main.async { completion(ok) }
        }
    }
}
