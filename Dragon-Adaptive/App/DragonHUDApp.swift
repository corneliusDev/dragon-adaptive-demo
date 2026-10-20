//  DragonHUDApp.swift
//
//  DEBUG launch argument for the paired-simulator demo: -watchDemo opens the
//  Developer menu (its WATCH LINK section lists what arrives from the Watch)
//  and, over WatchConnectivity, asks the Watch app to start its workout
//  after 4 s and to end it after 20 s. Run the Watch app with -syntheticHR
//  so it has a heart rate to send in the simulator.
import SwiftUI

@main
struct DragonHUDApp: App {
    init() {
        // The Watch link has to be listening (and the mirrored-workout handler
        // installed) before the Watch starts a workout, so it starts at launch.
        WatchLink.shared.activate()
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-watchDemo") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                NSLog("[WatchLink] demo: start sent %@", WatchLink.shared.send(.startWorkout) ? "yes" : "no (not reachable)")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 20) {
                WatchLink.shared.endWorkout()
                NSLog("[WatchLink] demo: %@", WatchLink.shared.lastEvent ?? "")
            }
        }
        #endif
    }

    var body: some Scene {
        WindowGroup { RootView().preferredColorScheme(.dark) }
    }
}
