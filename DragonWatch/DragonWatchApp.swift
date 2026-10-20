//  DragonWatchApp.swift
//  The Dragon Apple Watch app: a running workout for heart rate, wrist
//  motion summarised to an effort score, both sent to the phone every
//  second (WorkoutManager). The phone starts it with
//  HKHealthStore.startWatchApp(with:), which lands in
//  handle(_ workoutConfiguration:) below; it can also be started here.
//
//  Debug launch arguments (simulator demos): -syntheticHR sends
//  SyntheticVitalsGenerator heart rate instead of HealthKit's, through the
//  same transport; -autostart starts the workout at launch.

import SwiftUI
import HealthKit
import WatchKit

final class WatchAppDelegate: NSObject, WKApplicationDelegate {
    func applicationDidFinishLaunching() {
        WorkoutManager.shared.activate()
    }

    /// The phone started a run: start the workout it handed over.
    func handle(_ workoutConfiguration: HKWorkoutConfiguration) {
        WorkoutManager.shared.start(configuration: workoutConfiguration)
    }
}

@main
struct DragonWatchApp: App {
    @WKApplicationDelegateAdaptor(WatchAppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup {
            WatchRunView(manager: .shared)
        }
    }
}
