//  WatchTransport.swift
//  How WatchMessages travel between the phone and the Watch app, behind
//  protocols so the phone's logic (WatchVitalsSource, the run setup) is
//  tested with fakes. Two real routes, both carrying the same encoded
//  WatchMessage bytes:
//
//      mirroring  the Watch's running workout mirrored to the phone (iOS 17):
//                 HKWorkoutSession.sendToRemoteWorkoutSession, which keeps
//                 flowing with the Watch screen off and the phone locked.
//                 MirroredWorkoutTransport.
//      connectivity  WatchConnectivity: sendMessageData while the other side
//                 is reachable, the fallback before (or without) mirroring.
//                 WatchConnectivityTransport.
//
//  WatchLink merges the two for the app. A message may arrive by both
//  routes; WatchMessageFilter drops the second copy by its sequence number.
//
//  Also here: starting and ending the Watch workout from the phone
//  (WatchWorkoutControlling), and the system implementation of it.

import Foundation
import DragonEngine

/// Which way a message came.
enum WatchRoute: String, Equatable {
    case mirroring
    case connectivity
}

/// One route to the Watch: bytes in, bytes out, on the main queue.
protocol WatchTransport: AnyObject {
    /// Each message's bytes as they arrive, with the route (main queue).
    var onReceive: ((Data, WatchRoute) -> Void)? { get set }
    /// The Watch can be sent to right now.
    var isReachable: Bool { get }
    /// Sends; returns false when it couldn't be sent (not reachable).
    @discardableResult
    func send(_ data: Data) -> Bool
}

/// Starts and ends the Watch's workout from the phone.
protocol WatchWorkoutControlling: AnyObject {
    /// Asks the Watch app to start its running workout (opening it if it
    /// isn't running). `completion` says whether the request went out.
    func startWorkout(completion: @escaping (Bool) -> Void)
    /// Asks the Watch to end its workout.
    func endWorkout()
}

/// The mirrored-workout route: up only while the Watch's workout is mirrored.
protocol MirroredTransport: WatchTransport {
    /// Reachability changed (a mirrored workout started or ended).
    var onChange: (() -> Void)? { get set }
    /// Installs the handler that accepts the Watch's mirrored workout.
    func activate()
}
