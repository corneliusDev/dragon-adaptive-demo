//  SeguePreview.swift
//  PREVIEW (the plan editor's segue section and the developer SEGUES sheet): a sample cue (the mile split) appearing and
//  leaving with the chosen segue and heads-up, looping until STOP, on the
//  phone mirror and (through HUDController) on the glasses when connected.
//
//  SeguePreview is the loop as a value: given seconds since PREVIEW, the
//  frame to show. One loop: the quiet dot for `rest` seconds, the heads-up
//  (if any) for its lead, the cue up for `shown` seconds, then its exit and
//  the quiet gap. It plays through the engine's own Presentation, so it is
//  exactly what a race would show. SeguePreviewController runs it at 20 Hz.

import Foundation
import Combine
import DragonEngine

struct SeguePreview {
    let segue: Segue
    let headsUp: Set<HeadsUpKind>
    let config: SegueConfig
    /// The sample cue and its frame.
    let cue: Cue
    let cueFrame: HUDFrame
    let quietFrame: HUDFrame
    /// Seconds of quiet dot at the start of each loop.
    var rest: TimeInterval = 1
    /// Seconds the cue stays up (the split's 3 s).
    var shown: TimeInterval = 3
    private var presentation: Presentation

    init(segue: Segue, headsUp: Set<HeadsUpKind>, config: SegueConfig) {
        self.segue = segue
        self.headsUp = headsUp
        self.config = config
        let sample = ScreenGallery.race(unit: .miles).first { $0.name == "split" }!
        cue = sample.cue!
        cueFrame = sample.frame(.full, unit: .miles)
        quietFrame = Renderer.frame(for: nil, form: .full, effort: sample.effort, unit: .miles)
        presentation = Presentation(segue: segue, headsUp: headsUp, config: config)
    }

    /// Seconds into a loop the heads-up starts (nil: heads-up off).
    var headsUpAt: TimeInterval? { headsUp.isEmpty ? nil : rest }
    /// Seconds into a loop the cue appears.
    var appearsAt: TimeInterval { rest + (headsUp.isEmpty ? 0 : config.headsUpLead) }
    /// Seconds into a loop the cue leaves.
    var leavesAt: TimeInterval { appearsAt + shown }
    /// One loop: the cue's exit and the quiet gap after it (the rest counts towards the gap).
    var period: TimeInterval { leavesAt + max(config.fadeOut, config.glowOut, config.quietGap - rest, 0) }

    /// The frame `elapsed` seconds after PREVIEW. Call with non-decreasing times.
    mutating func frame(at elapsed: TimeInterval) -> HUDFrame {
        let loop = Double(Int(elapsed / period))
        let t = elapsed - loop * period
        let up = t >= appearsAt && t < leavesAt
        // A new cue each loop, so each loop plays its entrance.
        var c = cue
        c.createdAt = loop * period + appearsAt
        let since = headsUpAt.flatMap { h in t >= h && t < appearsAt ? loop * period + h : nil }
        return presentation.frame(target: up ? cueFrame : quietFrame, cue: up ? c : nil,
                                  headsUpSince: since, at: elapsed)
    }

    /// Whether a heads-up starts between `a` and `b` (seconds after PREVIEW), for the Watch tap.
    func headsUpStarts(after a: TimeInterval, through b: TimeInterval) -> Bool {
        guard let h = headsUpAt, b > a else { return false }
        return floor((b - h) / period) > floor((a - h) / period)
    }
}

/// Plays a SeguePreview at 20 Hz on the mirror and the glasses until stopped.
/// The SEGUES debug sheet and the plan editor's PREVIEW both use it.
final class SeguePreviewController: ObservableObject, SeguePreviewPlaying {
    @Published private(set) var isPlaying = false
    /// The frame on the mirror while playing.
    @Published private(set) var frame = HUDFrame()
    /// What is playing ("FADE · DOT PULSE").
    @Published private(set) var label = ""

    private weak var hud: HUDController?
    private let haptics: HeadsUpHaptics
    private var preview: SeguePreview?
    private var timer: Timer?
    private var started = Date()
    private var lastElapsed: TimeInterval = 0

    init(hud: HUDController?, haptics: HeadsUpHaptics = NoHeadsUpHaptics()) {
        self.hud = hud
        self.haptics = haptics
    }

    deinit { timer?.invalidate() }

    /// Starts (or restarts) the loop with this style.
    func play(segue: Segue, headsUp: Set<HeadsUpKind>, config: SegueConfig) {
        preview = SeguePreview(segue: segue, headsUp: headsUp, config: config)
        label = ([segue.rawValue] + headsUp.map(\.rawValue).sorted()).joined(separator: " · ").uppercased()
        started = Date()
        lastElapsed = 0
        isPlaying = true
        timer?.invalidate()
        let t = Timer(timeInterval: 1.0 / 20.0, repeats: true) { [weak self] _ in
            self?.tick(at: Date().timeIntervalSince(self?.started ?? Date()))
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        tick(at: 0)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        preview = nil
        isPlaying = false
        hud?.resumeLiveHUD()
    }

    /// One frame of the loop, `elapsed` seconds after PLAY (the timer's; tests call it directly).
    func tick(at elapsed: TimeInterval) {
        guard var p = preview else { return }
        let f = p.frame(at: elapsed)
        if p.headsUp.contains(.watchTap), p.headsUpStarts(after: lastElapsed, through: elapsed) {
            haptics.headsUp(RunEngine.HeadsUpSignal(key: p.cue.key, since: elapsed, dueAt: elapsed + p.config.headsUpLead))
        }
        lastElapsed = elapsed
        preview = p
        frame = f
        hud?.present(f)
    }
}
