//
//  ActiveLookSDKBootstrap.swift
//  Dragon-Adaptive
//
//  Created by Annika LaVina on 6/14/26.
//


//
//  ActiveLookSDKBootstrap.swift
//  Initializes ActiveLookSDK exactly once.
//

import Foundation

#if canImport(ActiveLookSDK)
import ActiveLookSDK
#endif

enum ActiveLookSDKBootstrap {

    #if canImport(ActiveLookSDK)
    static let sdk: ActiveLookSDK = {
        do {
            return try ActiveLookSDK.shared(
                onUpdateStartCallback: { _ in
                    print("[ActiveLookSDKBootstrap] updater: start")
                },
                onUpdateAvailableCallback: { _, authorize in
                    // Do NOT auto-authorize firmware/config updates during demo connection.
                    print("[ActiveLookSDKBootstrap] updater: available — ignored")
                    _ = authorize
                },
                onUpdateProgressCallback: { update in
                    print("[ActiveLookSDKBootstrap] updater: progress \(String(format: "%.2f", update.getProgress()))")
                },
                onUpdateSuccessCallback: { _ in
                    print("[ActiveLookSDKBootstrap] updater: success")
                },
                onUpdateFailureCallback: { _ in
                    print("[ActiveLookSDKBootstrap] updater: failure — ignored")
                }
            )
        } catch {
            fatalError("[ActiveLookSDKBootstrap] init failed: \(error.localizedDescription)")
        }
    }()
    #endif
}
