//  ScreenGalleryTests.swift
//  The debug screen gallery: every sample renders a frame the glasses accept,
//  and the controller holds a gallery frame on the mirror in place of the
//  live HUD until told to resume.

import XCTest
import DragonEngine
@testable import Dragon_Adaptive

final class ScreenGalleryTests: XCTestCase {
    func testEveryGallerySampleFitsTheGlassesInBothUnitsAndForms() {
        for unit in DistanceUnit.allCases {
            let samples = ScreenGallery.samples(unit: unit)
            XCTAssertEqual(Set(samples.compactMap { $0.cue?.key.kind }), Set(CueKind.allCases))
            for sample in samples {
                for form in Renderer.Form.allCases {
                    let frame = sample.frame(form, unit: unit)
                    XCTAssertTrue(frame.ops.allSatisfy(\.isInsideSafeZone), "\(sample.name) \(form)")
                    for case .text(_, _, let font, _, _, let s) in frame.ops {
                        XCTAssertLessThanOrEqual(s.count, font.maxChars, "\(sample.name): \(s)")
                        XCTAssertEqual(font.onGlasses, font, "\(sample.name): \(s) asks for a font the glasses clamp")
                    }
                }
            }
        }
    }

    func testControllerHoldsTheGalleryFrameUntilResumed() {
        let hud = HUDController()
        let split = ScreenGallery.samples(unit: .miles).first { $0.name == "split" }!
        let frame = split.frame(.full, unit: .miles)

        hud.showOnGlasses(frame)
        XCTAssertEqual(hud.galleryFrame, frame)
        let shown = expectation(description: "mirror shows the gallery frame")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            XCTAssertEqual(hud.frame, frame)
            shown.fulfill()
        }
        wait(for: [shown], timeout: 2)

        hud.resumeLiveHUD()
        XCTAssertNil(hud.galleryFrame)
        let live = expectation(description: "mirror back on the live HUD")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            XCTAssertNotEqual(hud.frame, frame)
            live.fulfill()
        }
        wait(for: [live], timeout: 2)
    }
}
